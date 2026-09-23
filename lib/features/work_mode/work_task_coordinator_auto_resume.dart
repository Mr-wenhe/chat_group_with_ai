part of 'work_task_coordinator.dart';

/// Automatic resume for failures the app can recover from on its own.
///
/// A retryable failure means the transport or the provider failed, not the
/// work: the task already holds a valid checkpoint, so making the user click
/// retry after every link hiccup turns an app-side problem into a stopped task.
/// The attempt count lives in the checkpoint, which both bounds how often one
/// task may resume itself and survives the very restarts that would otherwise
/// restart the count.
extension _WorkTaskCoordinatorAutoResume on WorkTaskCoordinator {
  static const String _autoResumeCountKey = 'autoResumeCount';

  /// Schedules the next automatic resume for a failed task, if it is retryable
  /// and still has an attempt left on the delay ladder.
  void _scheduleAutoResume(AgentTask task) {
    if (_disposed) return;
    final failure = task.workFailure;
    if (task.status != AgentTaskStatus.failed ||
        failure == null ||
        !failure.retryable) {
      return;
    }
    final attempt = _autoResumeCount(task);
    if (attempt >= autoResumeDelays.length) return;
    final delay = autoResumeDelays[attempt];
    Timer(delay, () {
      unawaited(_runAutoResume(task.id));
    });
    unawaited(
      _record(
        task,
        WorkTaskEventKind.queued,
        '链路暂时失败，将自动重试',
        detail: '第 ${attempt + 1} 次重试将在 ${delay.inSeconds} 秒后自动开始。',
      ),
    );
  }

  Future<void> _runAutoResume(String taskId) async {
    if (_disposed) return;
    await _serialize(() async {
      if (_disposed) return;
      final task = _taskBox.get(taskId);
      final failure = task?.workFailure;
      // The task may have been resumed, stopped, completed or removed while the
      // delay ran. An automatic wake-up must never re-dispatch a task that has
      // already moved on.
      if (task == null ||
          task.status != AgentTaskStatus.failed ||
          failure == null ||
          !failure.retryable) {
        return;
      }
      final attempt = _autoResumeCount(task);
      if (attempt >= autoResumeDelays.length) return;
      if (!_persistAutoResumeCount(task, attempt + 1)) return;
      await _save(task);
      await _requeueFailedTask(
        task,
        failure,
        title: '链路恢复，已自动继续',
        nextStep: '自动重试：${failure.suggestedAction}',
      );
    });
  }

  int _autoResumeCount(AgentTask task) {
    final decoded = _decodeAutoResumeMetadata(task);
    final value = decoded?[_autoResumeCountKey];
    return value is int && value > 0 ? value : 0;
  }

  /// Records one consumed attempt. Returns false when the checkpoint cannot be
  /// decoded, because a damaged checkpoint is not ours to rewrite and an
  /// uncounted resume would be unbounded.
  bool _persistAutoResumeCount(AgentTask task, int count) {
    final decoded = _decodeAutoResumeMetadata(task);
    if (decoded == null) return false;
    decoded[_autoResumeCountKey] = count;
    task.executionStateJson = jsonEncode(decoded);
    return true;
  }

  Map<String, dynamic>? _decodeAutoResumeMetadata(AgentTask task) {
    if (task.executionStateJson.trim().isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(task.executionStateJson);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } on Object {
      return null;
    }
  }
}

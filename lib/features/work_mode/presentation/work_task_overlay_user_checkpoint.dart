part of 'work_task_overlay_host.dart';

extension _WorkTaskOverlayUserCheckpoint on _WorkTaskOverlayHostState {
  void _scheduleCompletionPrompt(List<AgentTask> tasks) {
    if (_coordinator == null || _completionDialogOpen) return;
    final candidate = tasks
        .where((task) =>
            task.status == AgentTaskStatus.paused &&
            !_coordinator!.isTaskInFlight(task.id) &&
            WorkTaskCompletionChoice.pending(task) &&
            !WorkTaskCompletionChoice.paused(task) &&
            !_shownCompletionChoices
                .contains(WorkTaskCompletionChoice.identity(task)))
        .firstOrNull;
    if (candidate == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (mounted) await _showCompletionChoice(candidate.id);
    });
  }

  Future<void> _showCompletionChoice(String taskId) async {
    if (_completionDialogOpen) return;
    final coordinator = _coordinator;
    final task = coordinator?.taskById(taskId);
    if (task == null ||
        coordinator!.isTaskInFlight(taskId) ||
        !WorkTaskCompletionChoice.pending(task)) {
      return;
    }
    final identity = WorkTaskCompletionChoice.identity(task)!;
    _shownCompletionChoices.add(identity);
    _completionDialogOpen = true;
    final visible = _isVisible;
    if (mounted) _updateUserCheckpointUi(() => _isVisible = false);
    String? result;
    try {
      result = await showDialog<String>(
        context: widget.navigatorKey?.currentContext ?? context,
        builder: (context) => AlertDialog(
          key: const Key('work-task-completion-dialog'),
          title: const Text('本轮成果已冻结，是否可完成？'),
          content: const Text(
              '成果附件已发到对话中，可先查看。\n\n可完成：按你的确认直接交付并完结，不声称测试通过。\n继续测试：进入测试／独立审查，发现问题后返工复测，成员认可后正式交付。\n补充需求：保持暂停，支持文字、文件和图片。'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, 'supplement'),
                child: const Text('补充需求')),
            OutlinedButton(
                onPressed: () => Navigator.pop(context, 'test'),
                child: const Text('继续测试')),
            FilledButton(
                onPressed: () => Navigator.pop(context, 'deliver'),
                child: const Text('可完成')),
          ],
        ),
      );
      if (result == 'supplement') {
        await _supplementTask(taskId);
      } else if (result != null) {
        await coordinator.chooseCandidateCompletion(taskId, identity,
            test: result == 'test');
      }
    } on Object catch (error) {
      _shownCompletionChoices.remove(identity);
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            SnackBar(content: Text(sanitizeWorkTaskError(error))));
      }
    } finally {
      _completionDialogOpen = false;
      if (mounted && visible) _updateUserCheckpointUi(() => _isVisible = true);
    }
  }

  Future<void> _supplementTask(String taskId) async {
    final coordinator = _coordinator!;
    await coordinator.pauseForSupplement(taskId);
    final task = coordinator.taskById(taskId)!;
    final database = ref.read(databaseServiceProvider);
    final visible = _isVisible;
    if (mounted) _updateUserCheckpointUi(() => _isVisible = false);
    try {
      if (!mounted) return;
      await showDialog<void>(
        context: widget.navigatorKey?.currentContext ?? context,
        barrierDismissible: false,
        builder: (context) => WorkTaskSupplementDialog(
            database: database,
            onSubmit: (text, attachments) async {
              final message = Message(
                  groupId: task.groupId,
                  senderId: 'user',
                  senderType: Message.senderTypeUser,
                  content: text,
                  media: attachments,
                  isWorkMode: true);
              await database.persistMessage(message);
              await coordinator.enqueueFollowUp(taskId, text,
                  sourceMessageId: message.id, attachmentMessageId: message.id);
            }),
      );
    } finally {
      if (mounted && visible) _updateUserCheckpointUi(() => _isVisible = true);
    }
  }
}

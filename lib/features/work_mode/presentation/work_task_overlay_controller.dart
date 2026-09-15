import 'package:flutter_riverpod/flutter_riverpod.dart';

typedef WorkTaskOverlayOpenTask = void Function(String taskId);

/// App-scoped bridge from chat messages to the already-mounted task overlay.
/// It carries only a task id; lifecycle and action execution stay in the
/// overlay/coordinator pair.
class WorkTaskOverlayController {
  static final WorkTaskOverlayController shared = WorkTaskOverlayController();
  WorkTaskOverlayOpenTask? _openTask;

  void attach(WorkTaskOverlayOpenTask callback) {
    _openTask = callback;
  }

  void detach(WorkTaskOverlayOpenTask callback) {
    if (identical(_openTask, callback)) _openTask = null;
  }

  void openTask(String taskId) {
    final normalized = taskId.trim();
    if (normalized.isEmpty) return;
    _openTask?.call(normalized);
  }
}

final workTaskOverlayControllerProvider =
    Provider<WorkTaskOverlayController>((ref) {
  return WorkTaskOverlayController.shared;
});

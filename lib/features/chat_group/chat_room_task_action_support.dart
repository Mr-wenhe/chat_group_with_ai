part of 'chat_room_page.dart';

extension _ChatRoomTaskActionSupport on _ChatRoomPageState {
  /// Handles a durable task action embedded in a group message. The message
  /// carries its own task/version; this method never falls back to the newest
  /// task in the conversation.
  Future<void> _handleWorkTaskAction(WorkTaskUserAction action) async {
    if (_isDirectChat) return;
    final coordinator = ref.read(workTaskCoordinatorProvider);
    final task = coordinator.taskById(action.taskId);
    if (task == null || task.groupId != widget.groupId) {
      if (mounted) {
        AppToast.show(context, '该任务已不存在，请打开任务面板查看当前任务。');
      }
      return;
    }
    if (!coordinator.isUserActionCurrent(
      taskId: action.taskId,
      blockerId: action.blockerId,
      version: action.version,
    )) {
      if (mounted) {
        AppToast.show(context, '该提醒已失效，任务状态已经更新。');
      }
      return;
    }

    final overlay = ref.read(workTaskOverlayControllerProvider);
    // The app-scoped task panel is painted above the route Navigator.  Open it
    // after the member form returns; otherwise the panel can cover the very
    // fields the user needs to repair the role blocker.
    if (action.kind != WorkTaskUserActionKind.addMember) {
      overlay.openTask(action.taskId);
      return;
    }
    final group = _group;
    if (group == null || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatGroupFormPage(group: group),
      ),
    );
    if (!mounted) return;
    overlay.openTask(action.taskId);
    try {
      await coordinator.refreshDiscussionAfterMemberChange(
        action.taskId,
        blockerId: action.blockerId,
        version: action.version,
      );
    } on Object catch (error) {
      if (mounted) {
        AppToast.show(context, '群成员资格未能重新验证：$error');
      }
    }
  }
}

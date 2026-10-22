part of 'chat_room_page.dart';

extension _ChatRoomTaskActionSupport on _ChatRoomPageState {
  Future<void> _publishRequirementsConfirmed(int revision) => _appendMessage(
        Message(
          groupId: widget.groupId,
          senderId: 'system',
          senderType: 'system',
          content: '✅【需求已确认】当前需求版本 $revision 已接受，群讨论开始收敛方案。',
          isMention: true,
        ),
      );

  /// Handles a durable task action embedded in a chat message. The message
  /// carries its own task/version; this method never falls back to the newest
  /// task in the conversation.
  ///
  /// 私聊同样会收到任务提醒（见 `WorkTaskActionMessageService`），所以这里不能
  /// 再按私聊整体拒绝。私聊中"补成员"没有意义，其余动作都只是打开全局面板的
  /// 指定任务，不会替任何角色发言，因此对私聊是安全的。
  Future<void> _handleWorkTaskAction(WorkTaskUserAction action) async {
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
        if (_isDirectChat) {
          AppToast.show(context, '该提醒已失效，任务状态已经更新。');
        } else {
          ref.read(workTaskOverlayControllerProvider).openTask(action.taskId);
          AppToast.show(context, '该提醒已更新，已打开当前任务状态。');
        }
      }
      return;
    }

    if (!_isDirectChat &&
        action.kind == WorkTaskUserActionKind.confirmRequirements) {
      final revision = WorkDiscussionState.fromExecutionState(
            task.executionStateJson,
          )?.requestRevision ??
          1;
      try {
        await coordinator.confirmRequirements(
          action.taskId,
          version: action.version,
        );
      } on Object catch (error) {
        if (mounted) {
          AppToast.show(
            context,
            ref.read(entityLabelsProvider).humanize(
                  sanitizeWorkTaskError(error),
                ),
            icon: Icons.error_outline_rounded,
          );
        }
        return;
      }
      await _publishRequirementsConfirmed(revision);
      if (mounted) {
        ref.read(workTaskOverlayControllerProvider).openTask(action.taskId);
      }
      return;
    }

    final overlay = ref.read(workTaskOverlayControllerProvider);
    // The app-scoped task panel is painted above the route Navigator.  Open it
    // after the member form returns; otherwise the panel can cover the very
    // fields the user needs to repair the role blocker.
    final group = _group;
    if (action.kind != WorkTaskUserActionKind.addMember ||
        _isDirectChat ||
        group == null) {
      overlay.openTask(action.taskId);
      return;
    }
    if (!mounted) return;
    await _openGroupSettings(group);
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

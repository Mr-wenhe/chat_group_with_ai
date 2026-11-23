part of 'chat_room_page.dart';

extension _ChatRoomPendingReplySupport on _ChatRoomPageState {
  PendingChatReplyStore get _pendingReplyStore =>
      PendingChatReplyStore(_db.appSettingsBox, widget.groupId);

  PendingUserMessage? _nextPendingUserReply() {
    // Work-mode ownership must never turn a recovered social message into a task.
    if (_workModeEnabled || _isRealtimeGuest) {
      return null;
    }
    for (final id in _pendingReplyStore.messageIds) {
      final message = _db.messageBox.get(id);
      if (message == null ||
          message.groupId != widget.groupId ||
          message.senderType != 'user' ||
          message.isWorkMode) {
        unawaited(_pendingReplyStore.remove(id));
        continue;
      }
      return PendingUserMessage(
          message.content, _parseMentions(message.content),
          message: message);
    }
    return null;
  }

  Future<void> _finishPendingUserReply(Message? message, int generation) async {
    if (message == null) return;
    // A lifecycle cancellation keeps the original input for the next visit.
    // 判据用"会话还在"而不是"App 在前台"：窗口被遮挡时回复照样跑完了，这里必须
    // 把待回复标记清掉，否则回来时会把它再发一遍（重复请求）。
    if (!_disposed && _roomSessionVisible && generation == _roomRoundGeneration) {
      await _pendingReplyStore.remove(message.id);
    }
  }
}

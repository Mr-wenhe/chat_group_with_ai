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
    if (!_disposed && _roomWorkAllowed && generation == _roomRoundGeneration) {
      await _pendingReplyStore.remove(message.id);
    }
  }
}

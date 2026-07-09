class ConversationPresenceService {
  ConversationPresenceService._();

  static final ConversationPresenceService instance =
      ConversationPresenceService._();

  String? _activeConversationId;

  String? get activeConversationId => _activeConversationId;

  bool isActive(String conversationId) =>
      _activeConversationId == conversationId;

  void enter(String conversationId) {
    _activeConversationId = conversationId;
  }

  void leave(String conversationId) {
    if (_activeConversationId == conversationId) {
      _activeConversationId = null;
    }
  }
}

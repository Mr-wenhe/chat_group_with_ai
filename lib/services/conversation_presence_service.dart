import 'dart:async';

class ConversationPresenceService {
  ConversationPresenceService._();

  static final ConversationPresenceService instance =
      ConversationPresenceService._();

  String? _activeConversationId;
  String? _recentlyLeftConversationId;
  DateTime? _recentlyLeftAt;
  final _leftController = StreamController<String>.broadcast();

  String? get activeConversationId => _activeConversationId;
  Stream<String> get leftConversationStream => _leftController.stream;

  bool isActive(String conversationId) =>
      _activeConversationId == conversationId;

  void enter(String conversationId) {
    _activeConversationId = conversationId;
  }

  void leave(String conversationId) {
    if (_activeConversationId == conversationId) {
      _activeConversationId = null;
      _recentlyLeftConversationId = conversationId;
      _recentlyLeftAt = DateTime.now();
      _leftController.add(conversationId);
    }
  }

  String? consumeRecentlyLeftConversationId({
    Duration maxAge = const Duration(minutes: 2),
  }) {
    final id = _recentlyLeftConversationId;
    final leftAt = _recentlyLeftAt;
    if (id == null || leftAt == null) return null;
    _recentlyLeftConversationId = null;
    _recentlyLeftAt = null;
    if (DateTime.now().difference(leftAt) > maxAge) return null;
    return id;
  }
}

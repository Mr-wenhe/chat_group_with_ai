import 'dart:async';

class ConversationPresenceService {
  ConversationPresenceService._();

  static final ConversationPresenceService instance =
      ConversationPresenceService._();

  String? _activeConversationId;
  String? _recentlyLeftConversationId;
  DateTime? _recentlyLeftAt;
  final _leftController = StreamController<String>.broadcast();
  final _activeController = StreamController<String?>.broadcast();

  String? get activeConversationId => _activeConversationId;
  Stream<String> get leftConversationStream => _leftController.stream;

  /// 当前会话的切换通知（离开时为 null）。
  ///
  /// [enter] 以前不发任何通知，于是"按当前会话筛选"的界面（任务面板的标签栏与
  /// 队列计数）在切到另一个会话后仍显示上一个会话的内容，要等下一次任务更新才
  /// 刷新——那可能永远不会发生。
  Stream<String?> get activeConversationStream => _activeController.stream;

  bool isActive(String conversationId) =>
      _activeConversationId == conversationId;

  void enter(String conversationId) {
    if (_activeConversationId == conversationId) return;
    _activeConversationId = conversationId;
    _activeController.add(conversationId);
  }

  void leave(String conversationId) {
    if (_activeConversationId == conversationId) {
      _activeConversationId = null;
      _recentlyLeftConversationId = conversationId;
      _recentlyLeftAt = DateTime.now();
      _leftController.add(conversationId);
      _activeController.add(null);
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

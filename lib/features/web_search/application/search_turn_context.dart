import 'package:chat_group/services/web_search_service.dart' as legacy;

import 'search_coordinator.dart';
import 'search_coordinator_support.dart';
import '../models/search_models.dart'
    show SearchCategory, SearchFreshness, searchDefaultMaxResults;

/// The immutable search decision shared by every AI reply in one user turn.
///
/// A context may intentionally have no snapshot: stable questions, disabled
/// policy, denied consent, and generated messages all remain ordinary chat
/// turns. Keeping that distinction here prevents each character from making
/// an independent policy decision.
class SearchTurnContext {
  final String conversationId;
  final String sourceMessageId;
  final String turnId;
  final String query;
  final SearchMessageOrigin origin;
  final legacy.WebSearchSnapshot? snapshot;
  final bool isSuppressed;
  final bool forceRefresh;

  const SearchTurnContext({
    required this.conversationId,
    required this.sourceMessageId,
    required this.turnId,
    required this.query,
    required this.origin,
    this.snapshot,
    this.isSuppressed = false,
    this.forceRefresh = false,
  });

  const SearchTurnContext.suppressed({
    required String conversationId,
    required String sourceMessageId,
    required String turnId,
    required String query,
    required SearchMessageOrigin origin,
  }) : this(
          conversationId: conversationId,
          sourceMessageId: sourceMessageId,
          turnId: turnId,
          query: query,
          origin: origin,
          isSuppressed: true,
        );

  bool get hasSnapshot => snapshot != null;

  bool get hasSources => snapshot?.hasResults == true;

  SearchTurnContext copyWith({
    legacy.WebSearchSnapshot? snapshot,
    bool clearSnapshot = false,
    bool? isSuppressed,
    bool? forceRefresh,
  }) {
    return SearchTurnContext(
      conversationId: conversationId,
      sourceMessageId: sourceMessageId,
      turnId: turnId,
      query: query,
      origin: origin,
      snapshot: clearSnapshot ? null : snapshot ?? this.snapshot,
      isSuppressed: isSuppressed ?? this.isSuppressed,
      forceRefresh: forceRefresh ?? this.forceRefresh,
    );
  }
}

/// Owns search preparation and reply-to-turn associations for one chat page.
///
/// The controller has no widget dependency and performs network work only from
/// explicit methods. ChatRoomPage can therefore prepare once before its reply
/// loop, while regeneration can reuse or explicitly refresh the same context.
class SearchTurnContextController {
  final SearchCoordinator coordinator;
  final Map<String, SearchTurnContext> _turns = {};
  final Map<String, SearchTurnContext> _replyContexts = {};

  SearchTurnContextController({required this.coordinator});

  Future<SearchTurnContext> prepareUserTurn({
    required String conversationId,
    required String sourceMessageId,
    required String turnId,
    required String userMessage,
    required SearchConsent requestConsent,
    SearchMessageOrigin origin = SearchMessageOrigin.user,
    SearchStatusListener? onStatus,
    SearchCategory category = SearchCategory.general,
    SearchFreshness freshness = SearchFreshness.any,
    String locale = 'zh-CN',
    String? country,
    int maxResults = searchDefaultMaxResults,
    bool safeSearch = true,
    bool forceRefresh = false,
    bool isSensitive = false,
    String minimalContext = '',
  }) async {
    final stableSourceMessageId = _stableSourceMessageId(
      conversationId: conversationId,
      sourceMessageId: sourceMessageId,
      turnId: turnId,
      query: userMessage,
    );
    final stableTurnId =
        turnId.trim().isEmpty ? stableSourceMessageId : turnId.trim();
    if (!_canSearch(origin: origin, forceRefresh: forceRefresh)) {
      return SearchTurnContext.suppressed(
        conversationId: conversationId,
        sourceMessageId: stableSourceMessageId,
        turnId: stableTurnId,
        query: userMessage.trim(),
        origin: origin,
      );
    }

    final snapshot = await coordinator.searchIfAllowed(
      text: userMessage,
      conversationId: conversationId,
      requestConsent: requestConsent,
      onStatus: onStatus,
      sourceMessageId: stableSourceMessageId,
      turnId: stableTurnId,
      category: category,
      freshness: freshness,
      locale: locale,
      country: country,
      maxResults: maxResults,
      safeSearch: safeSearch,
      forceRefresh: forceRefresh,
      isSensitive: isSensitive,
      origin: origin,
      minimalContext: minimalContext,
    );
    final context = SearchTurnContext(
      conversationId: conversationId,
      sourceMessageId: stableSourceMessageId,
      turnId: stableTurnId,
      query: userMessage.trim(),
      origin: origin,
      snapshot: snapshot,
      forceRefresh: forceRefresh,
    );
    _turns[_turnKey(conversationId, stableSourceMessageId)] = context;
    return context;
  }

  void bindReply(String replyMessageId, SearchTurnContext context) {
    final normalizedId = replyMessageId.trim();
    if (normalizedId.isEmpty || context.snapshot == null) return;
    _replyContexts[normalizedId] = context;
  }

  SearchTurnContext? contextForReply(String replyMessageId) {
    return _replyContexts[replyMessageId.trim()];
  }

  SearchTurnContext? contextForTurn({
    required String conversationId,
    required String sourceMessageId,
  }) {
    return _turns[_turnKey(conversationId, sourceMessageId)];
  }

  /// Returns the original snapshot synchronously; no refresh is implicit.
  SearchTurnContext? contextForRegeneration(String originalReplyId) {
    return contextForReply(originalReplyId);
  }

  /// Explicitly refreshes the snapshot associated with an AI reply.
  Future<SearchTurnContext?> refreshRegeneration({
    required String originalReplyId,
    required SearchConsent requestConsent,
    SearchStatusListener? onStatus,
    SearchCategory category = SearchCategory.general,
    SearchFreshness freshness = SearchFreshness.any,
    String locale = 'zh-CN',
    String? country,
    int maxResults = searchDefaultMaxResults,
    bool safeSearch = true,
    bool isSensitive = false,
    String minimalContext = '',
  }) async {
    final previous = contextForReply(originalReplyId);
    if (previous == null) return null;
    final refreshed = await prepareUserTurn(
      conversationId: previous.conversationId,
      sourceMessageId: previous.sourceMessageId,
      turnId: previous.turnId,
      userMessage: previous.query,
      requestConsent: requestConsent,
      origin: SearchMessageOrigin.regeneration,
      onStatus: onStatus,
      category: category,
      freshness: freshness,
      locale: locale,
      country: country,
      maxResults: maxResults,
      safeSearch: safeSearch,
      isSensitive: isSensitive,
      minimalContext: minimalContext,
      forceRefresh: true,
    );
    bindReply(originalReplyId, refreshed);
    return refreshed;
  }

  void clear() {
    _turns.clear();
    _replyContexts.clear();
  }

  static bool _canSearch({
    required SearchMessageOrigin origin,
    required bool forceRefresh,
  }) {
    return origin == SearchMessageOrigin.user ||
        (origin == SearchMessageOrigin.regeneration && forceRefresh);
  }

  static String _stableSourceMessageId({
    required String conversationId,
    required String sourceMessageId,
    required String turnId,
    required String query,
  }) {
    final source = sourceMessageId.trim();
    if (source.isNotEmpty) return source;
    final turn = turnId.trim();
    if (turn.isNotEmpty) return turn;
    return SearchCoordinatorSupport.hash('$conversationId|$query');
  }

  static String _turnKey(String conversationId, String sourceMessageId) =>
      '${conversationId.trim()}::${sourceMessageId.trim()}';
}

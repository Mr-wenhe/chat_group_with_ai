import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/ai_governance/ai_governance_store.dart';
import 'package:chat_group/services/web_search_service.dart';

enum SearchRunStatus {
  idle,
  disabled,
  awaitingConsent,
  denied,
  searching,
  completed,
  noResults,
  failed,
}

extension SearchRunStatusExt on SearchRunStatus {
  bool get isTerminal =>
      switch (this) {
        SearchRunStatus.completed ||
        SearchRunStatus.noResults ||
        SearchRunStatus.failed ||
        SearchRunStatus.disabled ||
        SearchRunStatus.denied =>
          true,
        _ => false,
      };
}

class SearchRunState {
  final SearchRunStatus status;
  final String query;
  final WebSearchSnapshot? snapshot;

  const SearchRunState(
    this.status, {
    this.query = '',
    this.snapshot,
  });
}

typedef SearchConsent = Future<bool> Function(String query);
typedef SearchStatusListener = void Function(SearchRunState state);

class SearchCoordinator {
  final GovernancePersistence store;
  final WebSearchService service;

  SearchCoordinator({
    required this.store,
    WebSearchService? service,
  }) : service = service ?? WebSearchService();

  WebSearchPolicy effectivePolicy(String conversationId) =>
      store.conversationSearchPolicy(conversationId) ??
      store.globalSearchPolicy;

  Future<WebSearchSnapshot?> searchIfAllowed({
    required String? text,
    required String conversationId,
    required SearchConsent requestConsent,
    SearchStatusListener? onStatus,
  }) async {
    final query = text?.trim() ?? '';
    if (query.isEmpty || !service.shouldSearch(query)) return null;
    final policy = effectivePolicy(conversationId);
    if (policy == WebSearchPolicy.off) {
      onStatus?.call(SearchRunState(SearchRunStatus.disabled, query: query));
      await _audit(conversationId, query, 'disabled');
      return null;
    }
    if (policy == WebSearchPolicy.ask) {
      onStatus
          ?.call(SearchRunState(SearchRunStatus.awaitingConsent, query: query));
      if (!await requestConsent(query)) {
        onStatus?.call(SearchRunState(SearchRunStatus.denied, query: query));
        await _audit(conversationId, query, 'denied');
        return null;
      }
    }

    onStatus?.call(SearchRunState(SearchRunStatus.searching, query: query));
    final snapshot = await service.search(query);
    final status = snapshot.error != null
        ? SearchRunStatus.failed
        : snapshot.hasResults
            ? SearchRunStatus.completed
            : SearchRunStatus.noResults;
    onStatus?.call(SearchRunState(status, query: query, snapshot: snapshot));
    await store.addSearchAudit(SearchAuditEntry(
      conversationId: conversationId,
      query: query,
      searchedAt: snapshot.searchedAt,
      status: status.name,
      sources: snapshot.results
          .map((result) => result.url)
          .where((url) => url.trim().isNotEmpty)
          .toList(growable: false),
    ));
    return snapshot;
  }

  Future<void> _audit(
    String conversationId,
    String query,
    String status,
  ) {
    return store.addSearchAudit(SearchAuditEntry(
      conversationId: conversationId,
      query: query,
      searchedAt: DateTime.now(),
      status: status,
      sources: const [],
    ));
  }
}

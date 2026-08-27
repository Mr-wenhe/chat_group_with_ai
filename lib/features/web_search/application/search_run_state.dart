import '../models/search_models.dart' as domain;

enum SearchRunStatus {
  idle,
  suggested,
  awaitingConsent,
  planning,
  searching,
  retrying,
  evaluating,
  completed,
  noResults,
  failed,
  denied,
  disabled,
  cancelled,
}

extension SearchRunStatusExt on SearchRunStatus {
  bool get isTerminal => switch (this) {
        SearchRunStatus.completed ||
        SearchRunStatus.noResults ||
        SearchRunStatus.failed ||
        SearchRunStatus.denied ||
        SearchRunStatus.disabled ||
        SearchRunStatus.cancelled =>
          true,
        _ => false,
      };
}

class SearchRunState {
  final SearchRunStatus status;
  final String requestId;
  final String rootRequestId;
  final String query;
  final String provider;
  final int retryNumber;
  final Duration? retryDelay;
  final domain.WebSearchSnapshot? snapshot;

  const SearchRunState(
    this.status, {
    this.requestId = '',
    this.rootRequestId = '',
    this.query = '',
    this.provider = '',
    this.retryNumber = 0,
    this.retryDelay,
    this.snapshot,
  });

  bool get fromCache => snapshot?.fromCache ?? false;
}

typedef SearchConsent = Future<bool> Function(String query);
typedef SearchStatusListener = void Function(SearchRunState state);

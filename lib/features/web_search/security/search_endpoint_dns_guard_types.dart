typedef SearchDnsLookup = Future<List<String>> Function(String host);

const Duration searchDnsLookupTimeout = Duration(seconds: 3);

enum SearchEndpointDnsFailureKind { blocked, lookupFailed, timedOut }

class SearchEndpointDnsException implements Exception {
  final String message;
  final SearchEndpointDnsFailureKind kind;

  const SearchEndpointDnsException(
    this.message, {
    this.kind = SearchEndpointDnsFailureKind.blocked,
  });

  @override
  String toString() => message;
}

import 'search_endpoint_dns_guard_types.dart';

Future<void> requirePublicSearchEndpointDns(
  Uri endpoint, {
  required bool isRelease,
  SearchDnsLookup? lookup,
  Duration lookupTimeout = searchDnsLookupTimeout,
}) async {
  // The browser adapter cannot provide DNS pinning. Keep this boundary
  // unconditional so a future provider cannot accidentally re-enable Web
  // traffic by omitting its higher-level kIsWeb guard.
  throw const SearchEndpointDnsException(
    'Web search is not supported without native endpoint pinning',
  );
}

Future<void> prepareSearchEndpointConnection(
  Object dio,
  Uri endpoint, {
  required bool isRelease,
  SearchDnsLookup? lookup,
  Duration lookupTimeout = searchDnsLookupTimeout,
}) async {
  // See requirePublicSearchEndpointDns above: this is a fail-closed Web
  // transport boundary, independent of build mode.
  throw const SearchEndpointDnsException(
    'Web search is not supported without native endpoint pinning',
  );
}

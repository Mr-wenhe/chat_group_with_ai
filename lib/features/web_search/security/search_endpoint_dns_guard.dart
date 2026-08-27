import 'search_endpoint_dns_guard_types.dart';
import 'search_endpoint_dns_guard_stub.dart'
    if (dart.library.io) 'search_endpoint_dns_guard_io.dart' as platform;

export 'search_endpoint_dns_guard_types.dart';

/// Re-validates a configured hostname immediately before a native request.
///
/// Literal hosts are already checked at configuration time. Native clients
/// additionally resolve DNS here so a public-looking hostname cannot point to
/// loopback, link-local, or private infrastructure at dispatch time.
Future<void> requirePublicSearchEndpointDns(
  Uri endpoint, {
  required bool isRelease,
  SearchDnsLookup? lookup,
  Duration lookupTimeout = searchDnsLookupTimeout,
}) =>
    platform.requirePublicSearchEndpointDns(
      endpoint,
      isRelease: isRelease,
      lookup: lookup,
      lookupTimeout: lookupTimeout,
    );

/// Resolves and pins the endpoint address used by the native HTTP socket.
Future<void> prepareSearchEndpointConnection(
  Object dio,
  Uri endpoint, {
  required bool isRelease,
  SearchDnsLookup? lookup,
  Duration lookupTimeout = searchDnsLookupTimeout,
}) =>
    platform.prepareSearchEndpointConnection(
      dio,
      endpoint,
      isRelease: isRelease,
      lookup: lookup,
      lookupTimeout: lookupTimeout,
    );

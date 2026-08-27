import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import 'search_endpoint_validator.dart';
import 'search_endpoint_dns_guard_types.dart';

final _pinStates = Expando<_PinnedEndpointState>();

Future<void> requirePublicSearchEndpointDns(
  Uri endpoint, {
  required bool isRelease,
  SearchDnsLookup? lookup,
  Duration lookupTimeout = searchDnsLookupTimeout,
}) async {
  if (!isRelease) return;
  await _resolvePublicAddress(
    endpoint,
    lookup: lookup,
    lookupTimeout: lookupTimeout,
  );
}

Future<void> prepareSearchEndpointConnection(
  Object dio,
  Uri endpoint, {
  required bool isRelease,
  SearchDnsLookup? lookup,
  Duration lookupTimeout = searchDnsLookupTimeout,
}) async {
  if (!isRelease) return;
  final address = await _resolvePublicAddress(
    endpoint,
    lookup: lookup,
    lookupTimeout: lookupTimeout,
  );
  if (dio is! Dio || dio.httpClientAdapter is! IOHttpClientAdapter) {
    throw const SearchEndpointDnsException(
      'Native search requires the standard pinned HTTP adapter',
    );
  }
  final adapter = dio.httpClientAdapter as IOHttpClientAdapter;
  final origin = _endpointOrigin(endpoint);
  final existing = _pinStates[dio];
  if (existing != null && existing.origin != origin) {
    throw const SearchEndpointDnsException(
      'A Dio instance cannot be shared across search endpoint origins',
    );
  }
  final state = existing ?? _PinnedEndpointState(origin);
  _pinStates[dio] = state;
  state.address = address;
  if (state.installed) return;
  adapter.createHttpClient = () {
    final client = HttpClient();
    // A system proxy would move the connection target outside the pinned
    // socket path. Production search uses the validated endpoint directly.
    client.findProxy = (_) => 'DIRECT';
    client.connectionFactory = (uri, proxyHost, proxyPort) {
      if (proxyHost != null) {
        return Socket.startConnect(proxyHost, proxyPort ?? uri.port);
      }
      final port = uri.port == 0
          ? (uri.scheme.toLowerCase() == 'https' ? 443 : 80)
          : uri.port;
      return Socket.startConnect(state.address, port);
    };
    return client;
  };
  state.installed = true;
}

Future<String> _resolvePublicAddress(
  Uri endpoint, {
  SearchDnsLookup? lookup,
  required Duration lookupTimeout,
}) async {
  late final List<String> addresses;
  try {
    addresses = await (lookup ?? _lookup)(endpoint.host).timeout(
      lookupTimeout,
      onTimeout: () => throw const SearchEndpointDnsException(
        'Search endpoint DNS lookup timed out',
        kind: SearchEndpointDnsFailureKind.timedOut,
      ),
    );
  } on SearchEndpointDnsException {
    rethrow;
  } on Object {
    throw const SearchEndpointDnsException(
      'Search endpoint DNS lookup failed',
      kind: SearchEndpointDnsFailureKind.lookupFailed,
    );
  }
  if (addresses.isEmpty ||
      !SearchEndpointValidator.areResolvedAddressesPublic(addresses)) {
    throw const SearchEndpointDnsException(
      'Search endpoint resolved to a private address',
    );
  }
  return addresses.first;
}

Future<List<String>> _lookup(String host) async =>
    (await InternetAddress.lookup(host))
        .map((address) => address.address)
        .toList();

class _PinnedEndpointState {
  final String origin;
  String address = '';
  bool installed = false;

  _PinnedEndpointState(this.origin);
}

String _endpointOrigin(Uri endpoint) {
  final scheme = endpoint.scheme.toLowerCase();
  final host = endpoint.host.toLowerCase();
  final port = endpoint.hasPort
      ? endpoint.port
      : scheme == 'https'
          ? 443
          : 80;
  return '$scheme://$host:$port';
}

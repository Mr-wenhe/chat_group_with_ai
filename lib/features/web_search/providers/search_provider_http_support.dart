import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../models/search_failure.dart';
import '../models/search_models.dart';
import '../security/search_endpoint_dns_guard_types.dart';
import '../security/search_endpoint_validator.dart';
import '../security/search_secret_scanner.dart';

export '../models/search_failure_factory.dart';

SearchFailureType searchFailureTypeFromEndpointDnsException(
  SearchEndpointDnsException error,
) =>
    switch (error.kind) {
      SearchEndpointDnsFailureKind.timedOut =>
        SearchFailureType.connectionTimeout,
      SearchEndpointDnsFailureKind.lookupFailed => SearchFailureType.dns,
      SearchEndpointDnsFailureKind.blocked =>
        SearchFailureType.invalidConfiguration,
    };

const Duration searchProviderConnectTimeout = Duration(seconds: 8);
const Duration searchProviderReceiveTimeout = Duration(seconds: 12);
const int searchProviderMaxResponseBytes = 512 * 1024;
const int searchProviderMaxJsonDepth = 32;
const int searchProviderMaxJsonStringLength = 16 * 1024;
const int searchProviderMaxJsonArrayItems = 500;
const int searchProviderDefaultMaxResults = searchDefaultMaxResults;
const int searchProviderMaxResults = searchMaxResultsLimit;
const int searchProviderMaxResultCandidates = searchProviderMaxResults * 5;
const int searchProviderProbeMaxResults = 1;

/// Thrown before a provider response can be fully buffered or decoded.
class SearchResponseTooLargeException implements Exception {
  const SearchResponseTooLargeException();
}

/// Thrown when a bounded response still has an unsafe JSON shape to decode.
class SearchResponseStructureException implements Exception {
  const SearchResponseStructureException();
}

/// Bounded JSON transformer shared by every search transport.
///
/// Dio's standard JSON transformer buffers the complete body before decoding.
/// Search providers are external inputs, so enforce the byte boundary while
/// consuming their stream instead of relying on result-list truncation later.
class BoundedSearchJsonTransformer extends Transformer {
  @override
  Future<String> transformRequest(RequestOptions options) async =>
      Transformer.defaultTransformRequest(options, jsonEncode);

  @override
  Future<dynamic> transformResponse(
    RequestOptions options,
    ResponseBody responseBody,
  ) async {
    if (options.responseType == ResponseType.stream) return responseBody;
    final advertisedLength = int.tryParse(
      responseBody.headers[Headers.contentLengthHeader]?.first ?? '',
    );
    if (advertisedLength != null &&
        advertisedLength > searchProviderMaxResponseBytes) {
      throw const SearchResponseTooLargeException();
    }

    var byteCount = 0;
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in responseBody.stream) {
      byteCount += chunk.length;
      if (byteCount > searchProviderMaxResponseBytes) {
        throw const SearchResponseTooLargeException();
      }
      bytes.add(chunk);
    }
    final responseBytes = bytes.takeBytes();
    if (options.responseType == ResponseType.bytes) return responseBytes;
    final text = utf8.decode(responseBytes, allowMalformed: true);
    if (options.responseType == ResponseType.json && text.isNotEmpty) {
      // ResponseType.json is a caller contract, not a hint controlled by an
      // untrusted server header. A text/plain response can still contain a
      // JSON bomb, so validate every JSON response before decoding it.
      return decodeBoundedSearchProviderJson(text);
    }
    return text;
  }
}

void _validateJsonStructure(String text) {
  var inString = false;
  var escaped = false;
  var stringLength = 0;
  final containers = <bool>[];
  final arrayItemCounts = <int>[];

  for (var index = 0; index < text.length; index++) {
    final codeUnit = text.codeUnitAt(index);
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (codeUnit == 0x5c) {
        escaped = true;
      } else if (codeUnit == 0x22) {
        inString = false;
      } else if (++stringLength > searchProviderMaxJsonStringLength) {
        throw const SearchResponseStructureException();
      }
      continue;
    }

    if (codeUnit == 0x22) {
      inString = true;
      stringLength = 0;
    } else if (codeUnit == 0x7b || codeUnit == 0x5b) {
      containers.add(codeUnit == 0x5b);
      arrayItemCounts.add(0);
      if (containers.length > searchProviderMaxJsonDepth) {
        throw const SearchResponseStructureException();
      }
    } else if (codeUnit == 0x7d || codeUnit == 0x5d) {
      if (containers.isEmpty) continue;
      containers.removeLast();
      arrayItemCounts.removeLast();
    } else if (codeUnit == 0x2c && containers.isNotEmpty && containers.last) {
      final count = arrayItemCounts.last + 1;
      arrayItemCounts[arrayItemCounts.length - 1] = count;
      if (count >= searchProviderMaxJsonArrayItems) {
        throw const SearchResponseStructureException();
      }
    }
  }
}

/// Decodes JSON that has already crossed the transport boundary.
///
/// This helper is also used by adapters (such as DuckDuckGo) that may receive
/// a string from a test adapter or a custom Dio transformer instead of the
/// shared [BoundedSearchJsonTransformer]. Keeping the size and shape checks in
/// one function prevents an alternate decode path from becoming unbounded.
dynamic decodeBoundedSearchProviderJson(String text) {
  if (text.length > searchProviderMaxResponseBytes) {
    throw const SearchResponseTooLargeException();
  }
  if (utf8.encode(text).length > searchProviderMaxResponseBytes) {
    throw const SearchResponseTooLargeException();
  }
  _validateJsonStructure(text);
  return jsonDecode(text);
}

Dio configureSearchProviderDio(Dio dio) {
  dio.transformer = BoundedSearchJsonTransformer();
  return dio;
}

int boundedSearchProviderMaxResults(int requested) {
  if (requested < 1) return 1;
  if (requested > searchProviderMaxResults) return searchProviderMaxResults;
  return requested;
}

Uri resolveSearchProviderEndpoint(
  String baseUrl,
  String path, {
  bool? isRelease,
  bool allowLocalDevelopmentGateway = false,
}) {
  // Keep the same validation boundary for both the settings flow and direct
  // Provider construction. Stage 05 must not be able to turn persisted
  // configuration into an unchecked outbound request.
  final parsed = SearchEndpointValidator.requireValid(
    baseUrl,
    isRelease: isRelease,
    allowLocalDevelopmentGateway: allowLocalDevelopmentGateway,
  );

  final normalizedBasePath = parsed.path.endsWith('/')
      ? parsed.path.substring(0, parsed.path.length - 1)
      : parsed.path;
  final normalizedPath = path.startsWith('/') ? path : '/$path';
  final resolvedPath = normalizedBasePath.isNotEmpty &&
          (normalizedPath == normalizedBasePath ||
              normalizedPath.startsWith('$normalizedBasePath/'))
      ? normalizedPath
      : '$normalizedBasePath$normalizedPath';
  return parsed.replace(
    path: resolvedPath,
    query: '',
    fragment: '',
  );
}

Map<String, dynamic>? decodeSearchProviderMap(dynamic raw) {
  if (raw is String) {
    try {
      raw = decodeBoundedSearchProviderJson(raw);
    } on FormatException {
      return null;
    } on SearchResponseTooLargeException {
      return null;
    } on SearchResponseStructureException {
      return null;
    }
  }
  if (raw is! Map) return null;
  return raw.map<String, dynamic>(
    (key, value) => MapEntry(key.toString(), value),
  );
}

String? providerString(dynamic value) {
  if (value is! String) return null;
  final normalized = value.trim();
  return normalized.isEmpty ? null : normalized;
}

String cleanProviderText(dynamic value) => sanitizeSearchText(
      _removeMarkup(providerString(value) ?? ''),
      maxLength: searchSnippetMaxLength,
      redactSecrets: true,
      redactOpaqueTokens: true,
    );

String cleanProviderTitle(dynamic value) => sanitizeSearchText(
      _removeMarkup(providerString(value) ?? ''),
      maxLength: searchTitleMaxLength,
      fallback: '搜索结果',
      redactSecrets: true,
      redactOpaqueTokens: true,
    );

double? providerScore(dynamic value) {
  if (value is! num) return null;
  final score = value.toDouble();
  return score.isFinite ? score : null;
}

DateTime? providerPublishedAt(dynamic value) {
  final text = providerString(value);
  if (text == null) return null;
  return DateTime.tryParse(text);
}

Uri? providerUrl(dynamic value) {
  final rawUrl = providerString(value);
  if (rawUrl == null) return null;
  final parsed = Uri.tryParse(rawUrl);
  if (parsed == null) return null;
  try {
    return validateSearchUrl(parsed);
  } on ArgumentError {
    return null;
  }
}

String canonicalProviderUrl(Uri url) => url
    .replace(
      scheme: url.scheme.toLowerCase(),
      host: url.host.toLowerCase(),
      path: url.path == '/' ? '' : url.path,
      fragment: '',
    )
    .toString();

String? providerRequestId({
  Response<dynamic>? response,
  Map<String, dynamic>? body,
}) {
  final headers = response?.headers;
  for (final headerName in const [
    'x-request-id',
    'request-id',
    'x-brave-request-id',
    'x-correlation-id',
  ]) {
    final headerId = safeProviderRequestId(headers?.value(headerName));
    if (headerId != null) return headerId;
  }

  for (final key in const [
    'provider_request_id',
    'providerRequestId',
    'request_id',
    'requestId',
  ]) {
    final bodyId = safeProviderRequestId(body?[key]);
    if (bodyId != null) return bodyId;
  }
  return null;
}

String? safeProviderRequestId(dynamic raw) {
  final value = providerString(raw);
  if (value == null || value.length > 128) return null;
  if (const SearchSecretScanner().containsSensitiveData(value)) return null;
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$').hasMatch(value)) {
    return null;
  }
  return value;
}

String _removeMarkup(String value) => value
    .replaceAll(RegExp(r'<[^>]*>'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

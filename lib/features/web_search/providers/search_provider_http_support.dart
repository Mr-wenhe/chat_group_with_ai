import 'dart:convert';

import 'package:dio/dio.dart';

import '../models/search_models.dart';
import '../security/search_endpoint_validator.dart';

export '../models/search_failure_factory.dart';

const Duration searchProviderConnectTimeout = Duration(seconds: 8);
const Duration searchProviderReceiveTimeout = Duration(seconds: 12);
const int searchProviderDefaultMaxResults = searchDefaultMaxResults;
const int searchProviderMaxResults = searchMaxResultsLimit;
const int searchProviderProbeMaxResults = 1;

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
  return parsed.replace(
    path: '$normalizedBasePath$normalizedPath',
    query: '',
    fragment: '',
  );
}

Map<String, dynamic>? decodeSearchProviderMap(dynamic raw) {
  if (raw is String) {
    try {
      raw = jsonDecode(raw);
    } on FormatException {
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
    );

String cleanProviderTitle(dynamic value) => sanitizeSearchText(
      _removeMarkup(providerString(value) ?? ''),
      maxLength: searchTitleMaxLength,
      fallback: '搜索结果',
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

  for (final key in const ['request_id', 'requestId']) {
    final bodyId = safeProviderRequestId(body?[key]);
    if (bodyId != null) return bodyId;
  }
  return null;
}

String? safeProviderRequestId(dynamic raw) {
  final value = providerString(raw);
  if (value == null || value.length > 128) return null;
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$').hasMatch(value)) {
    return null;
  }
  return value;
}

String _removeMarkup(String value) => value
    .replaceAll(RegExp(r'<[^>]*>'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

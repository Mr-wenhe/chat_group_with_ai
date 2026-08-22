import 'dart:convert';

import 'package:crypto/crypto.dart';

export 'package:chat_group/core/search/search_failure_type.dart';

class SearchAuditEntry {
  static const legacyProvider = 'duckDuckGoInstantAnswer';

  final String requestId;
  final String conversationId;
  final String queryPreview;
  final String queryHash;
  final DateTime searchedAt;
  final String status;
  final String provider;
  final String? failureType;
  final int? statusCode;
  final int latencyMs;
  final int retryCount;
  final bool fromCache;

  /// Number of source URLs retained after validation and secret removal.
  final int sourceCount;
  final List<String> sources;

  /// Creates an audit entry while keeping only bounded, redacted values.
  ///
  /// [query] remains the source-compatible constructor argument. New records
  /// are serialized with both the legacy `query` key and the V2
  /// `queryPreview`/`queryHash` keys so older readers can continue to display
  /// them without receiving an unbounded user message.
  factory SearchAuditEntry({
    String requestId = '',
    required String conversationId,
    required String query,
    required DateTime searchedAt,
    required String status,
    String provider = legacyProvider,
    String? failureType,
    int? statusCode,
    int latencyMs = 0,
    int retryCount = 0,
    bool fromCache = false,
    int? sourceCount,
    String? queryHash,
    required Iterable<String> sources,
  }) {
    final normalizedQuery = _normalizeAuditQuery(query);
    final safeQuery = _truncateAuditQuery(normalizedQuery);
    final safeSources = _sanitizeAuditSources(sources);
    return SearchAuditEntry._(
      requestId: requestId,
      conversationId: conversationId,
      queryPreview: safeQuery,
      queryHash: _resolveAuditQueryHash(queryHash, normalizedQuery),
      searchedAt: searchedAt,
      status: status,
      provider: provider,
      failureType: failureType,
      statusCode: statusCode,
      latencyMs: latencyMs,
      retryCount: retryCount,
      fromCache: fromCache,
      sourceCount: _boundedAuditSourceCount(sourceCount, safeSources.length),
      sources: safeSources,
    );
  }

  SearchAuditEntry._({
    required this.requestId,
    required this.conversationId,
    required this.queryPreview,
    required this.queryHash,
    required this.searchedAt,
    required this.status,
    required this.provider,
    required this.failureType,
    required this.statusCode,
    required this.latencyMs,
    required this.retryCount,
    required this.fromCache,
    required this.sourceCount,
    required List<String> sources,
  }) : sources = List.unmodifiable(sources);

  /// Backward-compatible alias used by the pre-V2 settings UI and callers.
  String get query => queryPreview;

  factory SearchAuditEntry.fromMap(Map<dynamic, dynamic> map) {
    final rawSources = map['sources'];
    final sources = rawSources is Iterable
        ? rawSources.map((item) => item.toString()).toList(growable: false)
        : const <String>[];
    final hasQueryHash = map.containsKey('queryHash');
    return SearchAuditEntry(
      requestId: map['requestId']?.toString() ?? '',
      conversationId: map['conversationId']?.toString() ?? '',
      query: map['queryPreview']?.toString() ?? map['query']?.toString() ?? '',
      searchedAt: DateTime.tryParse(map['searchedAt']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      status: map['status']?.toString() ?? 'unknown',
      provider: map['provider']?.toString() ?? legacyProvider,
      failureType: map['failureType']?.toString(),
      statusCode: _auditInt(map['statusCode']),
      latencyMs: _auditInt(map['latencyMs']) ?? 0,
      retryCount: _auditInt(map['retryCount']) ?? 0,
      fromCache: map['fromCache'] == true,
      sourceCount: _auditInt(map['sourceCount']) ?? sources.length,
      queryHash: hasQueryHash ? map['queryHash']?.toString() ?? '' : '',
      sources: sources,
    );
  }

  Map<String, dynamic> toMap() => {
        'requestId': requestId,
        'conversationId': conversationId,
        // Keep `query` for old readers; both values are the same safe preview.
        'query': queryPreview,
        'queryPreview': queryPreview,
        'queryHash': queryHash,
        'searchedAt': searchedAt.toUtc().toIso8601String(),
        'status': status,
        'provider': provider,
        'failureType': failureType,
        'statusCode': statusCode,
        'latencyMs': latencyMs,
        'retryCount': retryCount,
        'fromCache': fromCache,
        'sourceCount': sourceCount,
        'sources': sources,
      };
}

int? _auditInt(Object? value) {
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}

int _boundedAuditSourceCount(int? requested, int safeSourceLength) {
  final count = requested ?? safeSourceLength;
  return count.clamp(0, safeSourceLength).toInt();
}

String _resolveAuditQueryHash(String? candidate, String normalizedQuery) {
  if (candidate == null) return _hashAuditQuery(normalizedQuery);
  final value = candidate.trim();
  // Keep an explicitly empty hash for legacy records, but never persist an
  // arbitrary caller-provided value that could itself contain a secret.
  if (value.isEmpty) return '';
  return RegExp(r'^[a-f0-9]{64}$', caseSensitive: false).hasMatch(value)
      ? value.toLowerCase()
      : _hashAuditQuery(normalizedQuery);
}

String _hashAuditQuery(String value) =>
    sha256.convert(utf8.encode(value.trim())).toString();

final _auditSecretPatterns = <({RegExp pattern, String replacement})>[
  (
    pattern: RegExp(
      r'-----BEGIN [^-]+-----[\s\S]*?-----END [^-]+-----',
      caseSensitive: false,
    ),
    replacement: '[REDACTED]',
  ),
  (
    pattern: RegExp(
      r'''(?:\b(?:authorization|proxy-authorization|api[-_ ]?key|access[-_ ]?token|client[-_ ]?secret|subscription[-_ ]?key|credential|password|secret|token|key)\b)\s*["']?\s*[:=]\s*["']?(?:bearer\s+)?[^\s,;}"]+''',
      caseSensitive: false,
    ),
    replacement: '[REDACTED]',
  ),
  (
    pattern: RegExp(
      r'''\bbearer\s+[^\s,;}"']+''',
      caseSensitive: false,
    ),
    replacement: '[REDACTED]',
  ),
  (
    pattern: RegExp(
      r'\b(?:sk|pk|tvly|pplx|gsk|xai|hf|r8)-[A-Za-z0-9][A-Za-z0-9_./-]{7,}',
      caseSensitive: false,
    ),
    replacement: '[REDACTED]',
  ),
  (
    pattern: RegExp(
      r'\bbce-v[23]/[A-Za-z0-9][A-Za-z0-9_./-]{7,}',
      caseSensitive: false,
    ),
    replacement: '[REDACTED]',
  ),
  (
    pattern: RegExp(r'\bAIza[A-Za-z0-9_-]{20,}', caseSensitive: false),
    replacement: '[REDACTED]',
  ),
  (
    pattern: RegExp(
      r'\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b',
    ),
    replacement: '[REDACTED]',
  ),
];

final _auditOpaqueTokenPattern = RegExp(
  r'\b[A-Za-z0-9][A-Za-z0-9_-]{23,}\b',
);

String _normalizeAuditQuery(String value) {
  var normalized = _redactAuditSecrets(value.trim());
  if (normalized.isEmpty) return '';
  return normalized.replaceAll(RegExp(r'\s+'), ' ').trim();
}

String _truncateAuditQuery(String normalized) {
  return normalized.length <= 120
      ? normalized
      : '${normalized.substring(0, 117)}...';
}

String _redactAuditSecrets(String value) {
  var sanitized = value;
  for (final item in _auditSecretPatterns) {
    sanitized = sanitized.replaceAll(item.pattern, item.replacement);
  }
  sanitized = sanitized.replaceAllMapped(_auditOpaqueTokenPattern, (match) {
    final token = match.group(0)!;
    return _looksLikeOpaqueAuditSecret(token) ? '[REDACTED]' : token;
  });
  return sanitized;
}

bool _looksLikeOpaqueAuditSecret(String token) {
  var characterClasses = 0;
  if (RegExp(r'[a-z]').hasMatch(token)) characterClasses++;
  if (RegExp(r'[A-Z]').hasMatch(token)) characterClasses++;
  if (RegExp(r'[0-9]').hasMatch(token)) characterClasses++;
  if (RegExp(r'[_-]').hasMatch(token)) characterClasses++;
  return token.length >= 24 && characterClasses >= 3;
}

List<String> _sanitizeAuditSources(Iterable<String> values) {
  final safeSources = <String>[];
  for (final value in values) {
    final source = value.trim();
    if (source.isEmpty) continue;
    final uri = Uri.tryParse(source);
    if (uri == null || uri.host.isEmpty) {
      if (!_containsAuditSecret(source)) {
        safeSources.add(
            source.length <= 2048 ? source : '${source.substring(0, 2045)}...');
      }
      continue;
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') continue;
    // Secrets can also be embedded in a provider path. Dropping that source
    // is safer than trying to reconstruct a URL with a partially redacted
    // path.
    if (_containsAuditSecret(uri.host) || _containsAuditSecret(uri.path)) {
      continue;
    }
    final safeParameters = <String, String>{};
    for (final parameter in uri.queryParameters.entries) {
      if (_isSensitiveAuditParameter(parameter.key) ||
          _containsAuditSecret(parameter.value)) {
        continue;
      }
      safeParameters[parameter.key] = parameter.value;
    }
    var serialized = uri
        .replace(
          userInfo: '',
          queryParameters: safeParameters,
        )
        .toString();
    if (serialized.endsWith('?')) {
      serialized = serialized.substring(0, serialized.length - 1);
    }
    final fragmentStart = serialized.indexOf('#');
    if (_containsAuditSecret(serialized)) continue;
    safeSources.add(
      fragmentStart < 0 ? serialized : serialized.substring(0, fragmentStart),
    );
  }
  return safeSources.toList(growable: false);
}

bool _isSensitiveAuditParameter(String value) => RegExp(
      r'(api[-_ ]?key|access[-_ ]?token|authorization|token|secret|credential|password|client[-_ ]?secret|subscription[-_ ]?key|^key$)',
      caseSensitive: false,
    ).hasMatch(value);

bool _containsAuditSecret(String value) => _redactAuditSecrets(value) != value;

part of 'ai_governance_store.dart';

bool _sameSearchAuditRaw(Object? current, List<dynamic> snapshot) {
  if (current is! List || current.length != snapshot.length) return false;
  for (var index = 0; index < snapshot.length; index++) {
    if (!_sameSearchAuditEntry(current[index], snapshot[index])) return false;
  }
  return true;
}

bool _sameSearchAuditEntry(Object? left, Object? right) {
  final leftFingerprint = _searchAuditFingerprint(left);
  final rightFingerprint = _searchAuditFingerprint(right);
  return leftFingerprint != null &&
      rightFingerprint != null &&
      leftFingerprint == rightFingerprint;
}

/// Returns a bounded fingerprint for the known audit schema. Unknown or
/// oversized values deliberately return null: pruning then becomes a no-op
/// instead of synchronously encoding an attacker-controlled object tree.
int? _searchAuditFingerprint(Object? value) {
  if (value is! Map) return null;
  const keys = [
    'requestId',
    'rootRequestId',
    'conversationId',
    'query',
    'queryPreview',
    'queryHash',
    'searchedAt',
    'status',
    'provider',
    'failureType',
    'statusCode',
    'latencyMs',
    'retryCount',
    'fromCache',
    'sourceCount',
    'sources',
  ];
  if (value.keys.any((key) => key is! String || !keys.contains(key))) {
    return null;
  }
  final fingerprintParts = <Object?>[];
  for (final key in keys) {
    fingerprintParts.add(value.containsKey(key));
    final item = value[key];
    if (key == 'sources') {
      if (item is! List || item.length > SearchAuditEntry.maxSources) {
        return null;
      }
      final sources = <String>[];
      for (final source in item) {
        if (source is! String || source.length > 512) return null;
        sources.add(source);
      }
      fingerprintParts.add(Object.hashAll(sources));
    } else if (item == null || item is num || item is bool) {
      fingerprintParts.add(item);
    } else if (item is String && item.length <= 512) {
      fingerprintParts.add(item);
    } else {
      return null;
    }
  }
  return Object.hashAll(fingerprintParts);
}

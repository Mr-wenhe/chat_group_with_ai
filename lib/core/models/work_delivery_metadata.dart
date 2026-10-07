/// Whitelisted portable delivery references. Files use the existing attachment
/// channel; imported records are historical and cannot resume a task.
class WorkDeliveryMetadata {
  static const maxFiles = 512;
  static Map<String, dynamic>? portable(Object? raw,
      {List<Map<String, dynamic>>? files}) {
    if (raw is! Map) return null;
    final result = <String, dynamic>{};
    for (final key in const [
      'taskId',
      'conversationId',
      'iterationId',
      'artifactDigest',
      'producerId',
      'senderId',
      'kind',
      'evidenceRef'
    ]) {
      final value = raw[key];
      if (value is! String ||
          value.length > 128 ||
          value.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
        return null;
      }
      result[key] = value;
    }
    if (!RegExp(r'^r[0-9]{3,}$').hasMatch(result['iterationId'] as String) ||
        !RegExp(r'^[0-9a-f]{64}$')
            .hasMatch(result['artifactDigest'] as String) ||
        !{'candidate', 'review', 'final'}.contains(result['kind'])) {
      return null;
    }
    for (final key in const ['requestRevision', 'teamRevision']) {
      final value = raw[key];
      if (value is! int || value < 1) return null;
      result[key] = value;
    }
    if (files == null &&
        (raw['files'] is! List ||
            (raw['files'] as List).any((e) => e is! Map))) {
      return null;
    }
    final entries = files ??
        (raw['files'] is List
            ? (raw['files'] as List)
                .whereType<Map>()
                .map((e) => Map<String, dynamic>.from(e))
                .toList()
            : <Map<String, dynamic>>[]);
    if (entries.length > maxFiles) return null;
    final safe = <Map<String, dynamic>>[];
    for (final entry in entries) {
      final relative = entry['relative'];
      final path = entry['path'];
      final size = entry['bytes'];
      final hash = entry['sha256'];
      if (relative is! String ||
          relative.length > 512 ||
          relative.contains(RegExp(r'[\\:\x00-\x1f\x7f]')) ||
          relative.split('/').any((s) => s.isEmpty || s == '.' || s == '..') ||
          path is! String ||
          !RegExp(r'^attachments/[0-9a-f]{64}(?:\.[a-z0-9]+)?$')
              .hasMatch(path) ||
          size is! int ||
          size < 0 ||
          hash is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
        return null;
      }
      safe.add(
          {'relative': relative, 'path': path, 'bytes': size, 'sha256': hash});
    }
    result['files'] = safe;
    result['verified'] = false;
    result['incomplete'] = raw['incomplete'] == true || safe.isEmpty;
    return result;
  }

  static Iterable<String> attachmentPaths(Object? raw) sync* {
    final safe = portable(raw);
    if (safe == null) return;
    for (final entry in safe['files'] as List) {
      yield (entry as Map)['path'] as String;
    }
  }
}

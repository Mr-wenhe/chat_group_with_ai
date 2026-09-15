part of 'work_discussion_state.dart';

String _cleanText(Object? value, {required int maximum}) {
  if (value is! String) return '';
  final cleaned =
      value.replaceAll(RegExp(r'[\u0000-\u001f\u007f]'), ' ').trim();
  if (cleaned.length <= maximum) return cleaned;
  return '${cleaned.substring(0, maximum - 1)}…';
}

String _cleanId(Object? value) => _cleanText(value, maximum: 128);

String? _nullableId(Object? value) {
  final cleaned = _cleanId(value);
  return cleaned.isEmpty ? null : cleaned;
}

int? _wholeInt(Object? value, {int? maximum}) {
  if (value is! num || !value.isFinite || value != value.truncate()) {
    return null;
  }
  final result = value.toInt();
  if (result < 0 || (maximum != null && result > maximum)) return null;
  return result;
}

List<String> _cleanIds(Iterable<String> values) => values
    .map((value) => _cleanId(value))
    .where((value) => value.isNotEmpty)
    .toSet()
    .take(64)
    .toList(growable: false);

List<String> _compactCandidateIds(
  Iterable<String> values, {
  required String? requiredId,
  required int maximum,
}) {
  final result = <String>[];
  for (final value in values) {
    final cleaned = _cleanId(value);
    if (cleaned.isEmpty || result.contains(cleaned)) continue;
    result.add(cleaned);
    if (result.length == maximum) break;
  }
  final required = _nullableId(requiredId);
  if (required != null && !result.contains(required)) {
    if (result.length == maximum) result.removeLast();
    result.add(required);
  }
  return result;
}

List<String>? _strictStrings(
  Object? value, {
  required int maximumItemLength,
}) {
  if (value is! List || value.length > 64) return null;
  final result = <String>[];
  for (final item in value) {
    final cleaned = _strictText(item, maximum: maximumItemLength);
    if (cleaned == null) return null;
    result.add(cleaned);
  }
  return result;
}

bool _boundedText(
  Object? value, {
  required int maximum,
  bool required = false,
}) {
  if (value is! String ||
      value.contains(RegExp(r'[\u0000-\u001f\u007f]')) ||
      value.trim().length > maximum) {
    return false;
  }
  return !required || value.trim().isNotEmpty;
}

bool _boundedNullableId(String? value) =>
    value == null || _boundedText(value, maximum: 128, required: true);

bool _boundedIds(Iterable<String> values) => values.every(
      (value) => _boundedText(value, maximum: 128, required: true),
    );

bool _boundedParticipants(Iterable<WorkDiscussionParticipant> values) =>
    values.every(
      (participant) =>
          _boundedText(participant.characterId, maximum: 128, required: true) &&
          _boundedText(participant.status, maximum: 64, required: true) &&
          participant.contributionCount >= 0 &&
          participant.contributionCount <= 100000 &&
          _boundedText(participant.lastContribution, maximum: 512),
    );

bool _boundedStrings(Iterable<String> values, {required int maximum}) =>
    values.every((value) => _boundedText(value, maximum: maximum));

String? _strictText(
  Object? value, {
  required int maximum,
  bool required = false,
}) {
  if (value is! String) return null;
  // Persisted gate fields are authenticated state, not user-facing prose.
  // Reject control characters instead of normalising them, otherwise a
  // malformed marker could change identity/path text and still become ready.
  if (value.contains(RegExp(r'[\u0000-\u001f\u007f]'))) return null;
  final cleaned = value.trim();
  if (cleaned.length > maximum || (required && cleaned.isEmpty)) return null;
  return cleaned;
}

Map<String, dynamic>? _strictContract(Object? value) {
  if (value == null) return null;
  if (value is! Map || value.keys.any((key) => key is! String)) return null;
  final raw = <String, dynamic>{
    for (final entry in value.entries) entry.key as String: entry.value,
  };
  for (final key in const [
    'deliverableType',
    'format',
    'location',
    'revisionTarget',
    'explicitExecutorId',
  ]) {
    final item = raw[key];
    if (key == 'explicitExecutorId') {
      if (item != null &&
          (_strictText(item, maximum: 128, required: true) == null)) {
        return null;
      }
      continue;
    }
    if (_strictText(item, maximum: 256, required: key != 'revisionTarget') ==
        null) {
      return null;
    }
  }
  if (_strictText(raw['contentScope'], maximum: 4096) == null) return null;
  final requestRevision =
      _wholeInt(raw['requestRevision'], maximum: 2147483647);
  if (requestRevision == null || requestRevision < 1) {
    return null;
  }
  return _safeContract(raw);
}

List<String> _cleanList(Iterable<String> values, {required int maximum}) =>
    values
        .map((value) => _cleanText(value, maximum: maximum))
        .where((value) => value.isNotEmpty)
        .toSet()
        .take(32)
        .toList(growable: false);

Map<String, dynamic>? _safeContract(Object? value) {
  if (value == null) return null;
  try {
    if (value is! Map || value.keys.any((key) => key is! String)) return null;
    final raw = <String, dynamic>{
      for (final entry in value.entries) entry.key as String: entry.value,
    };
    final output = <String, dynamic>{};
    for (final key in const [
      'deliverableType',
      'format',
      'location',
      'contentScope',
      'explicitExecutorId',
      'revisionTarget',
      'requestRevision',
    ]) {
      final item = raw[key];
      if (key == 'requestRevision') {
        final revision = _wholeInt(item, maximum: 2147483647);
        if (revision == null) return null;
        output[key] = revision;
        continue;
      }
      if (key == 'explicitExecutorId') {
        final id = _nullableId(item);
        if (item != null && id == null) return null;
        output[key] = id;
        continue;
      }
      if (item is! String) return null;
      final cleaned =
          _cleanText(item, maximum: key == 'contentScope' ? 4096 : 256);
      if (cleaned.isEmpty && key != 'contentScope' && key != 'revisionTarget') {
        return null;
      }
      output[key] = cleaned;
    }
    return output;
  } on Object {
    return null;
  }
}

Map<String, dynamic>? _compactContractForContext(
  Map<String, dynamic>? contract, {
  int maximumContentScope = 512,
}) {
  final safe = _safeContract(contract);
  if (safe == null) return null;
  final compact = Map<String, dynamic>.from(safe);
  compact['contentScope'] = _cleanText(
    compact['contentScope'],
    maximum: maximumContentScope,
  );
  compact['revisionTarget'] = _cleanText(
    compact['revisionTarget'],
    maximum: 256,
  );
  return compact;
}

bool _hasValidContractForExecution(
  Map<String, dynamic>? contract,
  int requestRevision,
  String? executorId,
) {
  final safe = _safeContract(contract);
  if (safe == null) return false;
  final deliverableType = safe['deliverableType'];
  final format = safe['format'];
  final location = safe['location'];
  final contentScope = safe['contentScope'];
  if (deliverableType is! String ||
      deliverableType.trim().isEmpty ||
      format is! String ||
      format.trim().isEmpty ||
      format == 'unspecified' ||
      location is! String ||
      location.trim().isEmpty ||
      location == 'unspecified' ||
      contentScope is! String ||
      contentScope.trim().isEmpty) {
    return false;
  }
  final revision = safe['requestRevision'];
  if (revision != requestRevision) return false;
  final explicitExecutor = _nullableId(safe['explicitExecutorId']);
  final executor = _nullableId(executorId);
  // A non-null value records a user-pinned executor. A null value is the
  // durable form of a group election, where [executorId] is still authoritative
  // after the discussion runner records its vote-based choice.
  return executor != null &&
      (explicitExecutor == null || explicitExecutor == executor);
}

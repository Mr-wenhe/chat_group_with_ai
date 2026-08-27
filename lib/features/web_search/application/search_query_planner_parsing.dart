part of 'search_query_planner.dart';

extension _SearchQueryPlannerParsing on SearchQueryPlanner {
  _ParsedPlan? _parse(String? responseText) {
    final text = responseText?.trim() ?? '';
    if (text.isEmpty) return null;
    if (utf8.encode(text).length > SearchQueryPlanner.maxPlannerResponseBytes) {
      return null;
    }
    dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final raw = <String, dynamic>{};
    for (final entry in decoded.entries) {
      if (entry.key is! String) return null;
      raw[entry.key as String] = entry.value;
    }
    if (!raw.keys.toSet().containsAll(SearchQueryPlanner._requiredKeys) ||
        raw.keys
            .toSet()
            .difference(SearchQueryPlanner._requiredKeys)
            .isNotEmpty) {
      return null;
    }
    if (raw['blocked'] is! bool ||
        raw['block_reason'] is! String ||
        raw['primary_query'] is! String ||
        raw['fallback_query'] is! String ||
        raw['category'] is! String ||
        raw['freshness'] is! String ||
        raw['country'] is! String ||
        raw['language'] is! String ||
        raw['reason'] is! String ||
        !_isStringList(raw['required_terms']) ||
        !_isStringList(raw['excluded_terms'])) {
      return null;
    }

    final category = _category(raw['category'] as String);
    final freshness = _freshness(raw['freshness'] as String);
    if (category == null || freshness == null) return null;

    final primary = sanitizer.sanitize(raw['primary_query'] as String);
    final fallback = sanitizer.sanitize(raw['fallback_query'] as String);
    final blocked = raw['blocked'] as bool;
    if (primary.containsSensitiveData || fallback.containsSensitiveData) {
      return null;
    }
    if (!blocked && primary.text.isEmpty) return null;
    if (!blocked && fallback.text == primary.text) return null;

    return _ParsedPlan(
      blocked: blocked,
      blockReason: _safeHint(raw['block_reason'] as String, maxCharacters: 160),
      primaryQuery: primary.text,
      fallbackQuery: fallback.text,
      category: category,
      freshness: freshness,
      country: _safeHint(raw['country'] as String, maxCharacters: 40),
      language: _safeHint(raw['language'] as String, maxCharacters: 20),
      requiredTerms: _safeList(raw['required_terms']),
      excludedTerms: _safeList(raw['excluded_terms']),
      reason: _safeHint(raw['reason'] as String, maxCharacters: 240),
    );
  }

  SearchQueryPlan _toPlan(
    _ParsedPlan parsed,
    SearchQueryPlan local, {
    required bool repairedJson,
  }) {
    // A valid blocked response is a safety decision, not a planner failure.
    // Only malformed/transport failures may fall back to the local plan.
    if (parsed.blocked) {
      return SearchQueryPlan(
        primaryQuery: '',
        fallbackQuery: null,
        category: local.category,
        freshness: local.freshness,
        country: '',
        language: local.language,
        requiredTerms: const [],
        excludedTerms: const [],
        reason: parsed.reason.isEmpty ? local.reason : parsed.reason,
        blocked: true,
        blockReason:
            parsed.blockReason.isEmpty ? 'planner_blocked' : parsed.blockReason,
        usedPlanner: true,
        repairedJson: repairedJson,
      );
    }
    if (parsed.primaryQuery.isEmpty) {
      return local;
    }
    final plannerFallback = parsed.fallbackQuery.trim();
    final fallback =
        plannerFallback.isEmpty || plannerFallback == parsed.primaryQuery
            ? local.fallbackQuery
            : plannerFallback;
    return SearchQueryPlan(
      primaryQuery: parsed.primaryQuery,
      fallbackQuery: fallback,
      category: parsed.category,
      freshness: parsed.freshness,
      country: parsed.country,
      language: parsed.language.isEmpty ? local.language : parsed.language,
      requiredTerms: parsed.requiredTerms,
      excludedTerms: parsed.excludedTerms,
      reason: parsed.reason.isEmpty ? local.reason : parsed.reason,
      blocked: false,
      blockReason: '',
      usedPlanner: true,
      repairedJson: repairedJson,
    );
  }

  String _responseText(Map<String, dynamic> response) {
    final standardContent = response['content']?.toString().trim() ?? '';
    if (standardContent.isNotEmpty) return standardContent;
    final normalizedMessage = response['message']?.toString().trim() ?? '';
    if (normalizedMessage.isNotEmpty) return normalizedMessage;
    // Compatibility with providers that put reasoning in the alternate field;
    // this is only read after the standard content fields are empty.
    return response['reasoning_content']?.toString().trim() ?? '';
  }

  String _safeHint(String value, {required int maxCharacters}) {
    final normalized = value
        .replaceAll(RegExp(r'[\u0000-\u001F\u007F]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (normalized.length <= maxCharacters) return normalized;
    return normalized.substring(0, maxCharacters).trimRight();
  }

  List<String> _safeList(Object? value) {
    if (value is! List) return const [];
    return value
        .whereType<String>()
        .map((item) => _safeHint(item, maxCharacters: 80))
        .where((item) => item.isNotEmpty)
        .take(10)
        .toList(growable: false);
  }

  bool _isStringList(Object? value) =>
      value is List && value.every((item) => item is String);

  SearchCategory? _category(String value) {
    for (final item in SearchCategory.values) {
      if (item.name == value) return item;
    }
    return null;
  }

  SearchFreshness? _freshness(String value) {
    for (final item in SearchFreshness.values) {
      if (item.name == value) return item;
    }
    return null;
  }
}

class _ParsedPlan {
  final bool blocked;
  final String blockReason;
  final String primaryQuery;
  final String fallbackQuery;
  final SearchCategory category;
  final SearchFreshness freshness;
  final String country;
  final String language;
  final List<String> requiredTerms;
  final List<String> excludedTerms;
  final String reason;

  const _ParsedPlan({
    required this.blocked,
    required this.blockReason,
    required this.primaryQuery,
    required this.fallbackQuery,
    required this.category,
    required this.freshness,
    required this.country,
    required this.language,
    required this.requiredTerms,
    required this.excludedTerms,
    required this.reason,
  });
}

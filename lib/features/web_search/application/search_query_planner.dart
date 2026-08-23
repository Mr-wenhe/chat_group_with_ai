import 'dart:convert';

import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/ai_governance/ai_request_gateway.dart';

import '../models/search_models.dart';
import '../security/search_query_sanitizer.dart';
import 'search_intent_detector.dart';
import 'search_prompts.dart';

class SearchPlannerConfig {
  final String apiKey;
  final ApiProvider provider;
  final String model;
  final String? customBaseUrl;
  final String conversationId;
  final String characterId;

  const SearchPlannerConfig({
    required this.apiKey,
    required this.provider,
    required this.model,
    this.customBaseUrl,
    required this.conversationId,
    this.characterId = 'search-planner',
  });
}

class SearchQueryPlan {
  final String primaryQuery;
  final String? fallbackQuery;
  final SearchCategory category;
  final SearchFreshness freshness;
  final String country;
  final String language;
  final List<String> requiredTerms;
  final List<String> excludedTerms;
  final String reason;
  final bool blocked;
  final String blockReason;
  final bool usedPlanner;
  final bool repairedJson;

  const SearchQueryPlan({
    required this.primaryQuery,
    required this.fallbackQuery,
    required this.category,
    required this.freshness,
    required this.country,
    required this.language,
    required this.requiredTerms,
    required this.excludedTerms,
    required this.reason,
    required this.blocked,
    required this.blockReason,
    required this.usedPlanner,
    required this.repairedJson,
  });

  bool get hasFallback =>
      fallbackQuery != null && fallbackQuery!.trim().isNotEmpty;
}

/// Optional LLM query planning behind [AiRequestGateway].
///
/// The planner only receives a sanitized current question and a bounded
/// disambiguation hint. It cannot request tools, choose a Provider, or bypass
/// the governance policy.
class SearchQueryPlanner {
  static const int _maxMinimalContextCharacters = 600;
  static const int _maxRepairInputCharacters = 3000;
  static const int _maxPlannerOutputTokens = 512;

  final AiRequestGateway gateway;
  final SearchPlannerConfig config;
  final SearchQuerySanitizer sanitizer;
  final DateTime Function() clock;

  const SearchQueryPlanner({
    required this.gateway,
    required this.config,
    this.sanitizer = const SearchQuerySanitizer(),
    this.clock = DateTime.now,
  });

  Future<SearchQueryPlan> plan({
    required String userMessage,
    required SearchIntentDecision decision,
    String userRegion = '',
    String minimalContext = '',
    bool userInitiated = true,
  }) async {
    final local = localPlan(decision);
    if (!decision.shouldSearch || decision.origin != SearchMessageOrigin.user) {
      return local;
    }
    // A secret finding is already enough information to keep the optional
    // LLM out of the path. The sanitized query may still be used by an
    // explicitly consented search, but it is not worth sending to a Planner.
    if (decision.mayContainSensitiveData) return local;

    final safeQuestion = sanitizer.sanitize(userMessage);
    if (safeQuestion.blocked || safeQuestion.text.isEmpty) return local;

    final safeRegion =
        sanitizer.sanitize(_safeHint(userRegion, maxCharacters: 80)).text;
    final safeContext = sanitizer
        .sanitize(
          _safeHint(
            minimalContext,
            maxCharacters: _maxMinimalContextCharacters,
          ),
        )
        .text;
    final userPrompt = SearchPrompts.buildPlannerUserPrompt(
      currentDate: clock(),
      userRegion: safeRegion,
      currentUserMessage: safeQuestion.text,
      minimalContext: safeContext,
    );

    final firstResponse = await _complete(
      systemPrompt: SearchPrompts.promptA,
      userPrompt: userPrompt,
      userInitiated: userInitiated,
    );
    final firstPlan = _parse(firstResponse);
    if (firstPlan != null) {
      return _toPlan(firstPlan, local, repairedJson: false);
    }

    // Exactly one format-only repair is allowed. The invalid response is
    // bounded and redacted before it is sent back to any model.
    final repairInput = sanitizer
        .sanitize(
          _safeHint(
            firstResponse ?? '',
            maxCharacters: _maxRepairInputCharacters,
          ),
        )
        .text;
    if (repairInput.isEmpty) return local;
    final repairResponse = await _complete(
      systemPrompt: SearchPrompts.promptA,
      userPrompt: SearchPrompts.buildJsonRepairPrompt(
        schema: SearchPrompts.promptJsonSchema,
        invalidOutput: repairInput,
      ),
      userInitiated: userInitiated,
    );
    final repaired = _parse(repairResponse);
    if (repaired == null) return local;
    return _toPlan(repaired, local, repairedJson: true);
  }

  SearchQueryPlan localPlan(SearchIntentDecision decision) {
    final candidates = decision.localQueryCandidates
        .map((candidate) => sanitizer.sanitize(candidate).text)
        .where((candidate) => candidate.isNotEmpty)
        .toSet()
        .toList(growable: false);
    final primary = candidates.isEmpty ? '' : candidates.first;
    final fallback = candidates.length > 1 ? candidates[1] : null;
    return SearchQueryPlan(
      primaryQuery: primary,
      fallbackQuery: fallback,
      category: decision.category,
      freshness: decision.freshness,
      country: '',
      language: 'zh',
      requiredTerms: const [],
      excludedTerms: const [],
      reason: decision.reasonCode,
      blocked: decision.mayContainSensitiveData && primary.isEmpty,
      blockReason: decision.mayContainSensitiveData && primary.isEmpty
          ? 'sanitized_query_empty'
          : '',
      usedPlanner: false,
      repairedJson: false,
    );
  }

  Future<String?> _complete({
    required String systemPrompt,
    required String userPrompt,
    required bool userInitiated,
  }) async {
    try {
      final response = await gateway.sendChatMessage(
        apiKey: config.apiKey,
        provider: config.provider,
        customBaseUrl: config.customBaseUrl,
        model: config.model,
        messages: [
          {'role': 'system', 'content': systemPrompt},
          {'role': 'user', 'content': userPrompt},
        ],
        purpose: AiRequestPurpose.searchPlanning,
        conversationId: config.conversationId,
        characterId: config.characterId,
        temperature: 0,
        maxTokens: _maxPlannerOutputTokens,
        maxRetries: 0,
        // Planner is a text-only request. It never receives tool permission
        // from model output or from the query plan.
        requiresTools: false,
        userInitiated: userInitiated,
      );
      if (response['success'] != true) return null;
      return _responseText(response);
    } catch (_) {
      return null;
    }
  }

  _ParsedPlan? _parse(String? responseText) {
    final text = responseText?.trim() ?? '';
    if (text.isEmpty) return null;
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
    if (!raw.keys.toSet().containsAll(_requiredKeys) ||
        raw.keys.toSet().difference(_requiredKeys).isNotEmpty) {
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

  static String _responseText(Map<String, dynamic> response) {
    final standardContent = response['content']?.toString().trim() ?? '';
    if (standardContent.isNotEmpty) return standardContent;
    final normalizedMessage = response['message']?.toString().trim() ?? '';
    if (normalizedMessage.isNotEmpty) return normalizedMessage;
    // Compatibility with providers that put reasoning in the alternate field;
    // this is only read after the standard content fields are empty.
    return response['reasoning_content']?.toString().trim() ?? '';
  }

  static String _safeHint(String value, {required int maxCharacters}) {
    final normalized = value
        .replaceAll(RegExp(r'[\u0000-\u001F\u007F]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (normalized.length <= maxCharacters) return normalized;
    return normalized.substring(0, maxCharacters).trimRight();
  }

  static List<String> _safeList(Object? value) {
    if (value is! List) return const [];
    return value
        .whereType<String>()
        .map((item) => _safeHint(item, maxCharacters: 80))
        .where((item) => item.isNotEmpty)
        .take(10)
        .toList(growable: false);
  }

  static bool _isStringList(Object? value) =>
      value is List && value.every((item) => item is String);

  static SearchCategory? _category(String value) {
    for (final item in SearchCategory.values) {
      if (item.name == value) return item;
    }
    return null;
  }

  static SearchFreshness? _freshness(String value) {
    for (final item in SearchFreshness.values) {
      if (item.name == value) return item;
    }
    return null;
  }

  static const _requiredKeys = {
    'blocked',
    'block_reason',
    'primary_query',
    'fallback_query',
    'category',
    'freshness',
    'country',
    'language',
    'required_terms',
    'excluded_terms',
    'reason',
  };
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

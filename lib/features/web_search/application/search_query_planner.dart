import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/models/api_protocol.dart';
import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/ai_governance/ai_request_gateway.dart';

import '../models/search_models.dart';
import '../security/search_query_sanitizer.dart';
import 'search_intent_detector.dart';
import 'search_prompts.dart';

part 'search_query_planner_parsing.dart';

class SearchPlannerConfig {
  final String apiKey;
  final Future<String?> Function()? resolveApiKey;
  final ApiProvider provider;
  final ApiProtocol apiProtocol;
  final String model;
  final String? customBaseUrl;
  final String conversationId;
  final String characterId;

  const SearchPlannerConfig({
    this.apiKey = '',
    this.resolveApiKey,
    required this.provider,
    this.apiProtocol = ApiProtocol.defaultValue,
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

  /// Planner JSON is intentionally tiny; reject a hostile body before parsing
  /// or sending it into the one permitted repair request.
  static const int maxPlannerResponseBytes = 64 * 1024;

  /// Bounds each optional planner or one-time JSON-repair request.
  static const Duration defaultRequestTimeout = Duration(seconds: 8);

  /// The first plan and its one permitted format repair share one wall-clock
  /// budget. This prevents two sequential request timeouts from exceeding the
  /// latency target before Provider search even starts.
  static const Duration defaultPlanningBudget = Duration(seconds: 8);

  final AiRequestGateway gateway;
  final SearchPlannerConfig config;
  final SearchQuerySanitizer sanitizer;
  final DateTime Function() clock;

  /// Override for deterministic tests and deployments with a stricter budget.
  final Duration requestTimeout;
  final Duration planningBudget;

  const SearchQueryPlanner({
    required this.gateway,
    required this.config,
    this.sanitizer = const SearchQuerySanitizer(),
    this.clock = DateTime.now,
    this.requestTimeout = defaultRequestTimeout,
    this.planningBudget = defaultPlanningBudget,
  });

  /// Recipient label shown before ask-mode planning sends sanitized text.
  String get disclosureName => 'AI Query Planner（${config.provider.name}）';

  Future<SearchQueryPlan> plan({
    required String userMessage,
    required SearchIntentDecision decision,
    String userRegion = '',
    String minimalContext = '',
    bool userInitiated = true,
    CancelToken? cancelToken,
    DateTime? deadline,
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
    final plannerDeadline = _earliestDeadline(
      clock().add(planningBudget),
      deadline,
    );
    final firstTimeout = _remaining(plannerDeadline);
    if (firstTimeout <= Duration.zero) return local;

    final firstResponse = await _complete(
      systemPrompt: SearchPrompts.promptA,
      userPrompt: userPrompt,
      userInitiated: userInitiated,
      cancelToken: cancelToken,
      timeout: firstTimeout,
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
    final repairTimeout = _remaining(plannerDeadline);
    if (repairTimeout <= Duration.zero) return local;
    final repairResponse = await _complete(
      systemPrompt: SearchPrompts.promptA,
      userPrompt: SearchPrompts.buildJsonRepairPrompt(
        schema: SearchPrompts.promptJsonSchema,
        invalidOutput: repairInput,
      ),
      userInitiated: userInitiated,
      cancelToken: cancelToken,
      timeout: repairTimeout,
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
    CancelToken? cancelToken,
    required Duration timeout,
  }) async {
    final effectiveTimeout =
        timeout < requestTimeout ? timeout : requestTimeout;
    if (effectiveTimeout <= Duration.zero) return null;
    final requestCancelToken = _childCancelToken(cancelToken);
    try {
      final apiKey =
          ((await resolvePlannerApiKey().timeout(effectiveTimeout)) ?? '')
              .trim();
      if (apiKey.isEmpty) return null;
      final response = await gateway
          .sendChatMessageWithResponseLimit(
            apiKey: apiKey,
            provider: config.provider,
            apiProtocol: config.apiProtocol,
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
            receiveTimeout: effectiveTimeout,
            cancelToken: requestCancelToken,
            // Planner is a text-only request. It never receives tool permission
            // from model output or from the query plan.
            requiresTools: false,
            userInitiated: userInitiated,
            maxResponseBytes: maxPlannerResponseBytes,
          )
          .timeout(effectiveTimeout);
      if (response['success'] != true) return null;
      return _responseText(response);
    } on TimeoutException {
      // Dio receives the same timeout, but the Future timeout also protects
      // custom/test clients that ignore Options.receiveTimeout. Cancel only
      // this planner attempt; the caller's search token remains reusable for
      // Provider search and the one permitted JSON-repair attempt.
      if (!requestCancelToken.isCancelled) {
        requestCancelToken.cancel('搜索查询规划超时');
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Duration _remaining(DateTime deadline) {
    final remaining = deadline.difference(clock());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  DateTime _earliestDeadline(DateTime local, DateTime? external) {
    if (external == null || external.isBefore(local)) return external ?? local;
    return local;
  }

  CancelToken _childCancelToken(CancelToken? parent) {
    final child = CancelToken();
    if (parent == null) return child;
    if (parent.isCancelled) {
      child.cancel();
      return child;
    }
    unawaited(
      parent.whenCancel.then<void>((reason) {
        if (!child.isCancelled) child.cancel(reason);
      }),
    );
    return child;
  }

  Future<String?> resolvePlannerApiKey() async => config.resolveApiKey == null
      ? config.apiKey
      : await config.resolveApiKey!.call();

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

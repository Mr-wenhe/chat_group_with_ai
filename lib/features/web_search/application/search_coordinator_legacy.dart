part of 'search_coordinator.dart';

/// Compatibility entry point for message-origin search orchestration.
///
/// It preserves the former call shape while returning the normalized V2
/// snapshot, so callers never need the retired pre-V2 result model.
extension SearchCoordinatorMessageSearchFacade on SearchCoordinator {
  Future<domain.WebSearchSnapshot?> searchIfAllowed({
    required String? text,
    required String conversationId,
    required SearchConsent requestConsent,
    SearchStatusListener? onStatus,
    String? sourceMessageId,
    String? turnId,
    domain.SearchCategory category = domain.SearchCategory.general,
    domain.SearchFreshness freshness = domain.SearchFreshness.any,
    String locale = 'zh-CN',
    String? country,
    int maxResults = domain.searchDefaultMaxResults,
    bool safeSearch = true,
    bool forceRefresh = false,
    bool isSensitive = false,
    SearchMessageOrigin origin = SearchMessageOrigin.user,
    String minimalContext = '',
    CancelToken? cancelToken,
  }) async {
    final rawQuery = text?.trim() ?? '';
    // A normal regeneration reuses its stored snapshot. An explicit refresh
    // is a user action, so it is the one regeneration path allowed to re-enter
    // the user-origin intent gate and force a new Provider request.
    final decisionOrigin =
        origin == SearchMessageOrigin.regeneration && forceRefresh
            ? SearchMessageOrigin.user
            : origin;
    final decision = intentDetector.detect(rawQuery, origin: decisionOrigin);
    if (!decision.shouldSearch) return null;

    final sanitized = sanitizer.sanitize(rawQuery);
    final effective = SearchCoordinator._constrainedPolicy(
      configured: effectivePolicy(conversationId),
      requested: null,
    );
    final localRequest = _requestFor(
      query: sanitized.text,
      conversationId: conversationId,
      sourceMessageId: sourceMessageId,
      turnId: turnId,
      category: _inferredCategory(category, decision),
      freshness: _inferredFreshness(freshness, decision),
      locale: locale,
      country: country,
      maxResults: maxResults,
      safeSearch: safeSearch,
      forceRefresh: forceRefresh,
      isSensitive: isSensitive || sanitized.isSensitive,
    );

    // off is the only policy path that must return before the optional
    // Planner. It still records the disabled audit even if no Provider is
    // configured.
    if (effective == WebSearchPolicy.off &&
        !await _passPolicyGate(
          request: localRequest,
          policy: effective,
          requestConsent: requestConsent,
          conversationId: conversationId,
          onStatus: onStatus,
        )) {
      return null;
    }

    if (sanitized.blocked) {
      // The sanitizer removed the entire query. Do not send an empty request
      // through the normal search path, especially in ask mode where an empty
      // preview could otherwise be treated as consent to continue.
      final blockedSnapshot = await _unsafeSnapshot(
        request: localRequest,
        conversationId: conversationId,
        onStatus: onStatus,
      );
      return blockedSnapshot;
    }
    if (localRequest.isSensitive && effective == WebSearchPolicy.auto) {
      return _runSensitiveSearch(
        request: localRequest,
        conversationId: conversationId,
        requestConsent: requestConsent,
        onStatus: onStatus,
        cancelToken: cancelToken,
        deadline: _clock().add(endToEndBudget),
      );
    }
    if (sanitized.text.isEmpty) return null;
    // Keep an unsupported runtime explicit. Returning null here used to make
    // a Web search look like an ordinary non-search turn, so the user
    // received no failure state or audit entry even though search was asked
    // for. The core coordinator records the invalid configuration without
    // invoking the optional planner or a Provider.
    if (_routes.isEmpty) {
      return search(
        request: localRequest,
        conversationId: conversationId,
        requestConsent: requestConsent,
        onStatus: onStatus,
        cancelToken: cancelToken,
        // No route can perform an outbound request, so an ask-mode consent
        // dialog would only mislabel a configuration failure as user denial.
        consentAlreadyGranted: true,
      );
    }

    final localPlan = _localPlan(decision);
    // The optional Planner is itself an outbound recipient. Ask mode first
    // authorizes that bounded, sanitized request. The final Provider query is
    // confirmed separately after planning so the displayed text always equals
    // the text that will actually leave the app.
    final plannerWillRun =
        queryPlanner != null && !decision.mayContainSensitiveData;
    if (effective == WebSearchPolicy.ask &&
        plannerWillRun &&
        !await _passPolicyGate(
          request: localRequest,
          policy: effective,
          requestConsent: requestConsent,
          conversationId: conversationId,
          onStatus: onStatus,
          providerOverride: queryPlanner!.disclosureName,
        )) {
      return null;
    }

    // Planner and Provider share one wall-clock deadline. Start it after the
    // optional Planner consent dialog so waiting for an explicit user decision
    // does not consume the network latency budget.
    var deadline = _clock().add(endToEndBudget);

    final plan = queryPlanner == null
        ? localPlan
        : await queryPlanner!.plan(
            userMessage: sanitized.text,
            decision: decision,
            minimalContext: minimalContext,
            cancelToken: cancelToken,
            deadline: deadline,
          );
    if (plan.blocked) {
      final blockedRequest = localRequest.copyWith(isSensitive: true);
      final blockedSnapshot = await _unsafeSnapshot(
        request: blockedRequest,
        conversationId: conversationId,
        onStatus: onStatus,
      );
      return blockedSnapshot;
    }
    final primaryRequest = _plannedRequest(
      localRequest: localRequest,
      plan: plan,
      conversationId: conversationId,
      fallbackLocale: locale,
    );
    if (primaryRequest == null) return null;
    final providerConsentStartedAt = _clock();
    if (!await _passPolicyGate(
      request: primaryRequest,
      policy: effective,
      requestConsent: requestConsent,
      conversationId: conversationId,
      onStatus: onStatus,
    )) {
      return null;
    }
    if (effective == WebSearchPolicy.ask) {
      // The final Provider query is a separate disclosure boundary. Keep the
      // user decision outside the shared Planner/Provider wall-clock budget.
      deadline = deadline.add(_positiveElapsed(providerConsentStartedAt));
    }
    final primary = await search(
      request: primaryRequest,
      conversationId: conversationId,
      requestConsent: requestConsent,
      onStatus: onStatus,
      cancelToken: cancelToken,
      consentAlreadyGranted: effective == WebSearchPolicy.ask,
      deadline: deadline,
    );
    if (primary == null) return null;

    final fallback = _fallbackQuery(
      plan: plan,
      primaryQuery: primaryRequest.query,
      sensitive: primaryRequest.isSensitive,
    );
    if (!primary.hasFailure && primary.hasNoResults && fallback != null) {
      final retry = await _runFallbackSearch(
        request: primaryRequest,
        fallback: fallback,
        executedQueries: primary.executedQueries,
        conversationId: conversationId,
        requestConsent: requestConsent,
        onStatus: onStatus,
        cancelToken: cancelToken,
        // In ask mode the fallback query is a new outbound value. Re-run the
        // consent gate so the user can approve the exact second request.
        consentAlreadyGranted: effective != WebSearchPolicy.ask,
        deadline: deadline,
      );
      if (retry != null) return retry;
    }

    return primary;
  }

  Future<domain.WebSearchSnapshot?> _runSensitiveSearch({
    required domain.SearchRequest request,
    required String conversationId,
    required SearchConsent requestConsent,
    required SearchStatusListener? onStatus,
    required CancelToken? cancelToken,
    required DateTime deadline,
  }) async {
    final snapshot = await search(
      request: request,
      conversationId: conversationId,
      requestConsent: requestConsent,
      onStatus: onStatus,
      cancelToken: cancelToken,
      consentAlreadyGranted: true,
      deadline: deadline,
    );
    return snapshot;
  }

  Future<domain.WebSearchSnapshot?> _runFallbackSearch({
    required domain.SearchRequest request,
    required String fallback,
    required Iterable<String> executedQueries,
    required String conversationId,
    required SearchConsent requestConsent,
    required SearchStatusListener? onStatus,
    required CancelToken? cancelToken,
    required bool consentAlreadyGranted,
    required DateTime deadline,
  }) async {
    final fallbackRequest = _requestFor(
      query: fallback,
      conversationId: conversationId,
      sourceMessageId: request.sourceMessageId,
      turnId: request.turnId,
      category: request.category,
      freshness: request.freshness,
      locale: request.locale,
      country: request.country,
      maxResults: request.maxResults,
      safeSearch: request.safeSearch,
      forceRefresh: true,
      isSensitive: request.isSensitive,
    );
    final retry = await search(
      request: fallbackRequest,
      conversationId: conversationId,
      requestConsent: requestConsent,
      onStatus: onStatus,
      cancelToken: cancelToken,
      consentAlreadyGranted: consentAlreadyGranted,
      deadline: deadline,
    );
    if (retry == null) return null;
    final combinedQueries = <String>{
      ...executedQueries,
      ...retry.executedQueries,
    }.toList(growable: false);
    return retry.copyWith(executedQueries: combinedQueries);
  }

  domain.SearchRequest? _plannedRequest({
    required domain.SearchRequest localRequest,
    required SearchQueryPlan plan,
    required String conversationId,
    required String fallbackLocale,
  }) {
    if (plan.blocked) return null;
    final primaryQuery = plan.primaryQuery.trim().isEmpty
        ? localRequest.query
        : sanitizer.sanitize(plan.primaryQuery).text;
    if (primaryQuery.isEmpty) return null;
    return _requestFor(
      query: primaryQuery,
      conversationId: conversationId,
      sourceMessageId: localRequest.sourceMessageId,
      turnId: localRequest.turnId,
      category: _routes.isEmpty ? localRequest.category : plan.category,
      freshness: _routes.isEmpty ? localRequest.freshness : plan.freshness,
      locale: plan.language.isEmpty
          ? fallbackLocale
          : _localeFor(plan.language, fallbackLocale),
      country: plan.country.isEmpty ? localRequest.country : plan.country,
      maxResults: localRequest.maxResults,
      safeSearch: localRequest.safeSearch,
      forceRefresh: localRequest.forceRefresh,
      isSensitive: localRequest.isSensitive,
    );
  }

  domain.SearchRequest _requestFor({
    required String query,
    required String conversationId,
    required String? sourceMessageId,
    required String? turnId,
    required domain.SearchCategory category,
    required domain.SearchFreshness freshness,
    required String locale,
    required String? country,
    required int maxResults,
    required bool safeSearch,
    required bool forceRefresh,
    required bool isSensitive,
  }) {
    final stableTurnId = turnId ?? conversationId;
    return _support.prepareRequest(
      domain.SearchRequest(
        requestId: _uuid.v4(),
        rootRequestId: stableTurnId,
        sourceMessageId:
            sourceMessageId ?? SearchCoordinatorSupport.hash(query),
        turnId: stableTurnId,
        query: query,
        category: category,
        freshness: freshness,
        locale: locale,
        country: country,
        maxResults: maxResults,
        safeSearch: safeSearch,
        forceRefresh: forceRefresh,
        isSensitive: isSensitive,
      ),
      conversationId,
    );
  }

  domain.SearchCategory _inferredCategory(
    domain.SearchCategory requested,
    SearchIntentDecision decision,
  ) {
    if (requested != domain.SearchCategory.general) {
      return requested;
    }
    return decision.category;
  }

  domain.SearchFreshness _inferredFreshness(
    domain.SearchFreshness requested,
    SearchIntentDecision decision,
  ) {
    if (requested != domain.SearchFreshness.any) {
      return requested;
    }
    return decision.freshness;
  }

  SearchQueryPlan _localPlan(SearchIntentDecision decision) {
    final candidates = decision.localQueryCandidates
        .map((candidate) => sanitizer.sanitize(candidate).text)
        .where((candidate) => candidate.isNotEmpty)
        .toSet()
        .toList(growable: false);
    return SearchQueryPlan(
      primaryQuery: candidates.isEmpty ? '' : candidates.first,
      fallbackQuery: candidates.length > 1 ? candidates[1] : null,
      category: decision.category,
      freshness: decision.freshness,
      country: '',
      language: 'zh',
      requiredTerms: const [],
      excludedTerms: const [],
      reason: decision.reasonCode,
      blocked: false,
      blockReason: '',
      usedPlanner: false,
      repairedJson: false,
    );
  }

  String? _fallbackQuery({
    required SearchQueryPlan plan,
    required String primaryQuery,
    required bool sensitive,
  }) {
    if (sensitive) return null;
    final candidate = plan.fallbackQuery?.trim() ?? '';
    if (candidate.isEmpty || candidate == primaryQuery) return null;
    final safe = sanitizer.sanitize(candidate);
    if (safe.isSensitive || safe.text.isEmpty || safe.text == primaryQuery) {
      return null;
    }
    return safe.text;
  }

  String _localeFor(String language, String fallback) {
    final normalized = language.trim().toLowerCase();
    if (normalized.isEmpty) return fallback;
    if (normalized == 'zh' || normalized.startsWith('zh-')) return 'zh-CN';
    if (normalized == 'en' || normalized.startsWith('en-')) return 'en-US';
    return fallback;
  }
}

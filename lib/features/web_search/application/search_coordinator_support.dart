import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/ai_governance/ai_governance_store.dart';
import 'package:chat_group/services/web_search_service.dart' as legacy;

import '../models/search_failure.dart';
import '../models/search_failure_factory.dart';
import '../models/search_models.dart' as domain;
import 'search_run_state.dart';

/// Keeps serialization, audit, and compatibility details out of the
/// orchestration state machine.
class SearchCoordinatorSupport {
  final GovernancePersistence store;
  final DateTime Function() clock;
  final Uuid uuid;

  const SearchCoordinatorSupport({
    required this.store,
    required this.clock,
    required this.uuid,
  });

  domain.SearchRequest prepareRequest(
    domain.SearchRequest request,
    String conversationId,
  ) {
    final requestId =
        request.requestId.trim().isEmpty ? uuid.v4() : request.requestId.trim();
    final turnId = request.turnId.trim().isEmpty
        ? (request.rootRequestId.trim().isEmpty
            ? conversationId
            : request.rootRequestId.trim())
        : request.turnId.trim();
    final sourceMessageId = request.sourceMessageId.trim().isEmpty
        ? hash(request.query)
        : request.sourceMessageId.trim();
    final rootRequestId = request.rootRequestId.trim().isEmpty
        ? turnId
        : request.rootRequestId.trim();
    return request.copyWith(
      requestId: requestId,
      rootRequestId: rootRequestId,
      sourceMessageId: sourceMessageId,
      turnId: turnId,
      originalTextHash: request.originalTextHash ?? hash(request.query),
    );
  }

  domain.WebSearchSnapshot failureSnapshot({
    required domain.SearchRequest request,
    required String provider,
    required SearchFailure failure,
    int retryCount = 0,
    bool degraded = false,
    int latencyMs = 0,
  }) =>
      domain.WebSearchSnapshot(
        requestId: request.requestId,
        rootRequestId: request.rootRequestId,
        originalTextHash: request.originalTextHash ?? hash(request.query),
        executedQueries: [request.query],
        searchedAt: clock().toUtc(),
        provider: provider,
        results: const [],
        failure: failure,
        statusCode: failure.statusCode,
        retryCount: retryCount,
        degraded: degraded,
        latencyMs: latencyMs,
      );

  domain.WebSearchSnapshot cancelledSnapshot({
    required domain.SearchRequest request,
    required String provider,
  }) =>
      failureSnapshot(
        request: request,
        provider: provider,
        failure: buildSearchFailure(type: SearchFailureType.cancelled),
      );

  domain.WebSearchSnapshot domainFromLegacy(
    domain.SearchRequest request,
    legacy.WebSearchSnapshot snapshot,
  ) {
    final results = <domain.WebSearchResult>[];
    for (var index = 0; index < snapshot.results.length; index++) {
      final result = snapshot.results[index];
      final uri = Uri.tryParse(result.url);
      if (uri == null || uri.host.isEmpty) continue;
      results.add(
        domain.WebSearchResult(
          sourceId: result.sourceId.isEmpty ? 'S${index + 1}' : result.sourceId,
          title: result.title,
          snippet: result.snippet,
          url: uri,
          publishedAt: result.publishedAt,
          providerScore: result.providerScore,
          provider:
              result.provider.isEmpty ? snapshot.provider : result.provider,
        ),
      );
    }
    final failure = snapshot.failureType == null
        ? null
        : SearchFailure(
            type: snapshot.failureType!,
            safeMessage: snapshot.safeMessage ?? snapshot.error ?? '',
            statusCode: snapshot.statusCode,
            retryable: false,
          );
    return domain.WebSearchSnapshot(
      requestId: snapshot.requestId,
      rootRequestId: snapshot.rootRequestId.isEmpty
          ? request.rootRequestId
          : snapshot.rootRequestId,
      originalTextHash: snapshot.originalTextHash.isEmpty
          ? request.originalTextHash ?? hash(request.query)
          : snapshot.originalTextHash,
      executedQueries: snapshot.executedQueries.isEmpty
          ? [request.query]
          : snapshot.executedQueries,
      searchedAt: snapshot.searchedAt,
      provider: snapshot.provider,
      results: results,
      failure: failure,
      statusCode: snapshot.statusCode,
      fromCache: snapshot.fromCache,
      degraded: snapshot.degraded,
      latencyMs: snapshot.latencyMs,
      retryCount: snapshot.retryCount,
    );
  }

  legacy.WebSearchSnapshot toLegacySnapshot(
    String query,
    domain.WebSearchSnapshot snapshot,
  ) {
    final failure = snapshot.failure;
    final noResults = failure?.type == SearchFailureType.noResults;
    return legacy.WebSearchSnapshot(
      requestId: snapshot.requestId,
      rootRequestId: snapshot.rootRequestId,
      originalTextHash: snapshot.originalTextHash,
      executedQueries: snapshot.executedQueries,
      query: query,
      searchedAt: snapshot.searchedAt,
      provider: snapshot.provider,
      results: snapshot.results
          .map(
            (result) => legacy.WebSearchResult(
              sourceId: result.sourceId,
              title: result.title,
              snippet: result.snippet,
              url: result.url.toString(),
              provider: result.provider,
              publishedAt: result.publishedAt,
              providerScore: result.providerScore,
            ),
          )
          .toList(growable: false),
      error: noResults ? null : failure?.safeMessage,
      failureType: failure?.type,
      safeMessage: noResults ? null : failure?.safeMessage,
      statusCode: snapshot.statusCode,
      latencyMs: snapshot.latencyMs,
      retryCount: snapshot.retryCount,
      fromCache: snapshot.fromCache,
      degraded: snapshot.degraded,
    );
  }

  SearchRunStatus domainStatus(domain.WebSearchSnapshot snapshot) {
    if (snapshot.failure?.type == SearchFailureType.cancelled) {
      return SearchRunStatus.cancelled;
    }
    if (snapshot.hasFailure) return SearchRunStatus.failed;
    return snapshot.hasResults
        ? SearchRunStatus.completed
        : SearchRunStatus.noResults;
  }

  SearchRunStatus legacyStatus(legacy.WebSearchSnapshot snapshot) {
    if (snapshot.failureType == SearchFailureType.cancelled) {
      return SearchRunStatus.cancelled;
    }
    if (snapshot.hasFailure) return SearchRunStatus.failed;
    return snapshot.hasResults
        ? SearchRunStatus.completed
        : SearchRunStatus.noResults;
  }

  Future<void> auditDomain({
    required String conversationId,
    required domain.SearchRequest request,
    required domain.WebSearchSnapshot snapshot,
    required SearchRunStatus status,
  }) =>
      store.addSearchAudit(
        SearchAuditEntry(
          requestId: snapshot.requestId,
          conversationId: conversationId,
          query: request.query,
          searchedAt: snapshot.searchedAt,
          status: status.name,
          provider: snapshot.provider,
          failureType: snapshot.failure?.type.name,
          statusCode: snapshot.statusCode,
          latencyMs: snapshot.latencyMs,
          retryCount: snapshot.retryCount,
          fromCache: snapshot.fromCache,
          sources: snapshot.results
              .map((result) => result.url.toString())
              .toList(growable: false),
        ),
      );

  Future<void> auditLegacy({
    required String conversationId,
    required domain.SearchRequest request,
    required legacy.WebSearchSnapshot snapshot,
    required SearchRunStatus status,
  }) =>
      store.addSearchAudit(
        SearchAuditEntry(
          requestId: snapshot.requestId,
          conversationId: conversationId,
          query: request.query,
          searchedAt: snapshot.searchedAt,
          status: status.name,
          provider: snapshot.provider,
          failureType: snapshot.failureType?.name,
          statusCode: snapshot.statusCode,
          latencyMs: snapshot.latencyMs,
          retryCount: snapshot.retryCount,
          fromCache: snapshot.fromCache,
          sources: snapshot.results.map((result) => result.url),
        ),
      );

  Future<void> auditSimple({
    required String conversationId,
    required String query,
    required SearchRunStatus status,
  }) =>
      store.addSearchAudit(
        SearchAuditEntry(
          conversationId: conversationId,
          query: query,
          searchedAt: clock(),
          status: status.name,
          sources: const [],
        ),
      );

  static Duration ttlFor(domain.SearchCategory category) => switch (category) {
        domain.SearchCategory.news ||
        domain.SearchCategory.weather =>
          const Duration(minutes: 2),
        domain.SearchCategory.finance => const Duration(minutes: 1),
        domain.SearchCategory.software ||
        domain.SearchCategory.policy =>
          const Duration(minutes: 30),
        domain.SearchCategory.academic => const Duration(hours: 24),
        domain.SearchCategory.general ||
        domain.SearchCategory.local =>
          const Duration(hours: 6),
      };

  static String hash(String value) =>
      value.trim().isEmpty ? '' : _sha256(value.trim());
}

String _sha256(String value) {
  // Avoid pulling hashing details into the coordinator's state machine.
  return sha256.convert(utf8.encode(value)).toString();
}

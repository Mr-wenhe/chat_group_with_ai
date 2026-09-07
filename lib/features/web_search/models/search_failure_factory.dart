import 'package:chat_group/features/ai_governance/search_failure_classifier.dart';

import 'search_failure.dart';
import 'search_models.dart';

/// Builds the redacted failure contract shared by Providers and orchestration.
SearchFailure buildSearchFailure({
  required SearchFailureType type,
  int? statusCode,
  String? providerRequestId,
}) {
  final normalizedRequestId = normalizeSearchCorrelationId(providerRequestId);
  return SearchFailure(
    type: type,
    safeMessage: safeMessageForSearchFailure(type),
    statusCode: statusCode,
    retryable: isRetryableSearchFailure(type),
    providerRequestId: normalizedRequestId.isEmpty ? null : normalizedRequestId,
  );
}

/// Rebuilds an untrusted failure supplied by an extension Provider.
///
/// The failure type is the only presentation-safe diagnostic supplied by a
/// Provider. Custom safe text and request IDs are discarded or normalized so
/// response bodies cannot reach prompts, audits, logs, or UI error cards.
SearchFailure sanitizeSearchFailure(SearchFailure failure) =>
    buildSearchFailure(
      type: failure.type,
      statusCode: failure.statusCode,
      providerRequestId: failure.providerRequestId,
    );

bool isRetryableSearchFailure(SearchFailureType type) =>
    searchFailureIsRetryable(type);

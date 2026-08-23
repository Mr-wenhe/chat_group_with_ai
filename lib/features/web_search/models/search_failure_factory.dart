import 'package:chat_group/features/ai_governance/search_failure_classifier.dart';

import 'search_failure.dart';

/// Builds the redacted failure contract shared by Providers and orchestration.
SearchFailure buildSearchFailure({
  required SearchFailureType type,
  int? statusCode,
  String? providerRequestId,
}) {
  return SearchFailure(
    type: type,
    safeMessage: safeMessageForSearchFailure(type),
    statusCode: statusCode,
    retryable: isRetryableSearchFailure(type),
    providerRequestId: providerRequestId,
  );
}

bool isRetryableSearchFailure(SearchFailureType type) => switch (type) {
      SearchFailureType.offline ||
      SearchFailureType.connection ||
      SearchFailureType.dns ||
      SearchFailureType.connectionTimeout ||
      SearchFailureType.receiveTimeout ||
      SearchFailureType.providerUnavailable ||
      SearchFailureType.rateLimited =>
        true,
      _ => false,
    };

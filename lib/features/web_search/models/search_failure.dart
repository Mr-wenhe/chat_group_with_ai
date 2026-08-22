import 'package:chat_group/core/search/search_failure_type.dart';

export 'package:chat_group/core/search/search_failure_type.dart';

/// A provider failure reduced to safe, presentation-independent diagnostics.
///
/// Provider adapters must never place response bodies, credentials, or the
/// complete user query in this object. The existing [SearchFailureType]
/// classification remains shared with Stage 01 audit records.
class SearchFailure {
  final SearchFailureType type;
  final String safeMessage;
  final int? statusCode;
  final bool retryable;
  final String? providerRequestId;

  const SearchFailure({
    required this.type,
    required this.safeMessage,
    this.statusCode,
    required this.retryable,
    this.providerRequestId,
  });

  bool get isNoResults => type == SearchFailureType.noResults;
}

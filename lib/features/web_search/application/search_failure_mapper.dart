import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';

import 'package:chat_group/features/ai_governance/search_failure_classifier.dart';

import '../models/search_failure.dart';
import '../models/search_failure_factory.dart';
import 'search_retry_policy.dart';

/// Converts transport exceptions to the same safe failure contract used by
/// normalized Provider responses. Exception text and response bodies never
/// cross this boundary.
SearchFailure mapSearchFailure(Object error) {
  if (error is SearchFailure) return sanitizeSearchFailure(error);
  if (error is SearchRetryBudgetExceeded) {
    return buildSearchFailure(type: SearchFailureType.connectionTimeout);
  }
  if (error is SearchCancelledException) {
    return buildSearchFailure(type: SearchFailureType.cancelled);
  }
  if (error is TimeoutException) {
    return buildSearchFailure(type: SearchFailureType.receiveTimeout);
  }
  if (error is SocketException) {
    return buildSearchFailure(type: SearchFailureType.connection);
  }
  if (error is DioException) {
    return buildSearchFailure(
      type: searchFailureTypeFromDioException(error),
      statusCode: error.response?.statusCode,
    );
  }
  return buildSearchFailure(type: SearchFailureType.unknown);
}

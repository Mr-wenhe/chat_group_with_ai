import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';

import 'package:chat_group/features/ai_governance/search_failure_classifier.dart';

import '../models/search_failure.dart';

const int searchMaxRetries = 2;
const Duration searchRetryDelay1 = Duration(milliseconds: 500);
const Duration searchRetryDelay2 = Duration(milliseconds: 1500);
const List<Duration> searchRetryDelays = [
  searchRetryDelay1,
  searchRetryDelay2,
];
const Duration searchRetryBudget = Duration(seconds: 20);

typedef SearchRetrySleep = Future<void> Function(Duration delay);
typedef SearchRetryOperation<T> = Future<T> Function(int attempt);

Future<void> searchRetrySleep(Duration delay) => Future<void>.delayed(delay);

/// The result of a bounded attempt sequence. Errors are returned rather than
/// thrown so the coordinator can record the retry count and try a backup.
class SearchRetryResult<T> {
  final T? value;
  final Object? error;
  final StackTrace? stackTrace;
  final int retryCount;
  final bool budgetExhausted;

  const SearchRetryResult.success(
    this.value, {
    required this.retryCount,
  })  : error = null,
        stackTrace = null,
        budgetExhausted = false;

  const SearchRetryResult.failure({
    required this.error,
    this.stackTrace,
    required this.retryCount,
    this.budgetExhausted = false,
  }) : value = null;

  bool get hasError => error != null;

  T get requireValue => value as T;
}

/// Retry policy for search Providers.
///
/// This is intentionally separate from the LLM [RetryHandler]: search has a
/// smaller retry count and a hard per-turn wall-clock budget.
class SearchRetryPolicy {
  final int _configuredMaxRetries;
  final Duration _configuredTotalBudget;
  final SearchRetrySleep sleep;
  final DateTime Function() clock;

  const SearchRetryPolicy({
    int maxRetries = searchMaxRetries,
    Duration totalBudget = searchRetryBudget,
    this.sleep = searchRetrySleep,
    this.clock = _now,
  })  : _configuredMaxRetries = maxRetries,
        _configuredTotalBudget = totalBudget;

  int get maxRetries =>
      _configuredMaxRetries.clamp(0, searchMaxRetries).toInt();

  Duration get totalBudget {
    if (_configuredTotalBudget.isNegative) return Duration.zero;
    return _configuredTotalBudget > searchRetryBudget
        ? searchRetryBudget
        : _configuredTotalBudget;
  }

  Future<SearchRetryResult<T>> execute<T>({
    required SearchRetryOperation<T> operation,
    required bool Function(T value) shouldRetryResult,
    bool Function(Object error)? shouldRetryError,
    bool allowRetry = true,
    int? maxRetriesOverride,
    DateTime? deadline,
    bool Function()? isCancelled,
    void Function(int retryNumber, Duration delay)? onRetry,
  }) async {
    final actualDeadline = deadline ?? clock().add(totalBudget);
    final retryLimit =
        (maxRetriesOverride ?? maxRetries).clamp(0, searchMaxRetries).toInt();
    var retryCount = 0;

    while (true) {
      if (isCancelled?.call() == true) {
        return SearchRetryResult.failure(
          error: const SearchCancelledException(),
          retryCount: retryCount,
        );
      }

      final remaining = actualDeadline.difference(clock());
      if (remaining <= Duration.zero) {
        return SearchRetryResult.failure(
          error: const SearchRetryBudgetExceeded(),
          retryCount: retryCount,
          budgetExhausted: true,
        );
      }

      try {
        final value = await operation(retryCount).timeout(remaining);
        if (isCancelled?.call() == true) {
          return SearchRetryResult.failure(
            error: const SearchCancelledException(),
            retryCount: retryCount,
          );
        }
        if (!allowRetry ||
            !shouldRetryResult(value) ||
            retryCount >= retryLimit) {
          return SearchRetryResult.success(value, retryCount: retryCount);
        }

        if (!await _waitBeforeRetry(
          retryCount: retryCount,
          deadline: actualDeadline,
          isCancelled: isCancelled,
          onRetry: onRetry,
        )) {
          if (isCancelled?.call() == true) {
            return SearchRetryResult.failure(
              error: const SearchCancelledException(),
              retryCount: retryCount,
            );
          }
          return SearchRetryResult.success(value, retryCount: retryCount);
        }
        retryCount++;
      } catch (error, stackTrace) {
        if (isCancelled?.call() == true) {
          return SearchRetryResult.failure(
            error: const SearchCancelledException(),
            retryCount: retryCount,
          );
        }
        final canRetry = allowRetry &&
            retryCount < retryLimit &&
            (shouldRetryError?.call(error) ?? isRetryableError(error));
        if (!canRetry) {
          return SearchRetryResult.failure(
            error: error,
            stackTrace: stackTrace,
            retryCount: retryCount,
          );
        }

        if (!await _waitBeforeRetry(
          retryCount: retryCount,
          deadline: actualDeadline,
          isCancelled: isCancelled,
          onRetry: onRetry,
        )) {
          if (isCancelled?.call() == true) {
            return SearchRetryResult.failure(
              error: const SearchCancelledException(),
              retryCount: retryCount,
            );
          }
          return SearchRetryResult.failure(
            error: error,
            stackTrace: stackTrace,
            retryCount: retryCount,
            budgetExhausted: true,
          );
        }
        retryCount++;
      }
    }
  }

  /// Returns true only for the transport and HTTP classes allowed by Stage 05.
  static bool isRetryableFailure({
    required SearchFailure? failure,
    int? statusCode,
  }) {
    if (failure?.type == SearchFailureType.unsafeQuery ||
        failure?.type == SearchFailureType.cancelled ||
        failure?.type == SearchFailureType.invalidConfiguration ||
        failure?.type == SearchFailureType.unauthorized ||
        failure?.type == SearchFailureType.forbidden) {
      return false;
    }
    if (statusCode != null && _retryableStatusCodes.contains(statusCode)) {
      return true;
    }
    return switch (failure?.type) {
      SearchFailureType.connection ||
      SearchFailureType.connectionTimeout ||
      SearchFailureType.receiveTimeout ||
      SearchFailureType.rateLimited =>
        true,
      _ => false,
    };
  }

  static bool isRetryableError(Object error) {
    if (error is SearchFailure) {
      return isRetryableFailure(failure: error, statusCode: error.statusCode);
    }
    if (error is TimeoutException || error is SocketException) return true;
    if (error is DioException) {
      final statusCode = error.response?.statusCode;
      if (statusCode != null && _retryableStatusCodes.contains(statusCode)) {
        return true;
      }
      final type = searchFailureTypeFromDioException(error);
      return isRetryableFailure(
        failure: SearchFailure(
          type: type,
          safeMessage: '',
          statusCode: statusCode,
          retryable: false,
        ),
        statusCode: statusCode,
      );
    }
    return false;
  }

  Future<bool> _waitBeforeRetry({
    required int retryCount,
    required DateTime deadline,
    required bool Function()? isCancelled,
    required void Function(int retryNumber, Duration delay)? onRetry,
  }) async {
    if (isCancelled?.call() == true) return false;
    final delay = _delayFor(retryCount);
    if (clock().add(delay).isAfter(deadline)) return false;
    onRetry?.call(retryCount + 1, delay);
    await sleep(delay);
    return isCancelled?.call() != true;
  }

  Duration _delayFor(int retryCount) {
    if (retryCount < searchRetryDelays.length) {
      return searchRetryDelays[retryCount];
    }
    return searchRetryDelays.last;
  }

  static DateTime _now() => DateTime.now();

  static const Set<int> _retryableStatusCodes = {429, 502, 503, 504};
}

/// Naming-compatible alias for code that refers to the search component as a
/// handler rather than a policy.
typedef SearchRetryHandler = SearchRetryPolicy;

class SearchCancelledException implements Exception {
  const SearchCancelledException();
}

class SearchRetryBudgetExceeded implements Exception {
  const SearchRetryBudgetExceeded();
}

import 'dart:async';

import 'package:dio/dio.dart';

typedef RetryOperation<T> = Future<T> Function(RetryAttempt attempt);
typedef RetryResultPredicate<T> = bool Function(T result);
typedef RetrySleep = Future<void> Function(Duration delay);

/// 描述一次初始调用或重试调用所使用的降级参数。
class RetryAttempt {
  /// 0 表示初始调用，1-5 表示对应的重试次数。
  final int retryNumber;

  const RetryAttempt(this.retryNumber);

  bool get useStreaming => retryNumber < 5;

  double temperatureFor(double original) {
    if (retryNumber >= 5) return 0.4;
    if (retryNumber >= 4) return 0.6;
    return original;
  }
}

/// 所有 LLM 调用共享的瞬态失败重试策略。
class RetryHandler {
  static const int defaultMaxRetries = 5;
  static const List<Duration> retryDelays = [
    Duration.zero,
    Duration(milliseconds: 500),
    Duration(milliseconds: 1500),
    Duration(milliseconds: 3000),
    Duration(milliseconds: 5000),
    Duration(milliseconds: 8000),
  ];

  static Future<T> executeWithRetry<T>({
    required RetryOperation<T> operation,
    RetryResultPredicate<T>? shouldRetryResult,
    bool Function(Object error)? shouldRetryError,
    int maxRetries = defaultMaxRetries,
    RetrySleep sleep = _defaultSleep,
  }) async {
    Object? lastError;
    StackTrace? lastStackTrace;
    for (var retryNumber = 0; retryNumber <= maxRetries; retryNumber++) {
      if (retryNumber > 0) {
        await sleep(_delayFor(retryNumber));
      }
      try {
        final result = await operation(RetryAttempt(retryNumber));
        final retry = shouldRetryResult?.call(result) ?? false;
        if (!retry || retryNumber == maxRetries) return result;
      } catch (error, stackTrace) {
        final retry = shouldRetryError?.call(error) ?? isTransientError(error);
        if (!retry || retryNumber == maxRetries) rethrow;
        lastError = error;
        lastStackTrace = stackTrace;
      }
    }
    Error.throwWithStackTrace(lastError!, lastStackTrace!);
  }

  static bool isTransientResult(Map<String, dynamic> result) {
    if (result['success'] == true) return false;
    final statusCode = result['statusCode'];
    if (statusCode is int) return _retryableStatusCodes.contains(statusCode);
    final message = result['message']?.toString().toLowerCase() ?? '';
    return _transientMessage.hasMatch(message);
  }

  static bool isTransientError(Object error) {
    if (error is TimeoutException) return true;
    if (error is DioException) {
      final statusCode = error.response?.statusCode;
      if (statusCode != null) return _retryableStatusCodes.contains(statusCode);
      return error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.sendTimeout ||
          error.type == DioExceptionType.receiveTimeout ||
          error.type == DioExceptionType.connectionError;
    }
    final text = error.toString().toLowerCase();
    return _transientMessage.hasMatch(text) || text.contains('socketexception');
  }

  static Duration _delayFor(int retryNumber) {
    final index = retryNumber - 1;
    if (index < retryDelays.length) return retryDelays[index];
    return retryDelays.last;
  }

  static Future<void> _defaultSleep(Duration delay) => Future.delayed(delay);

  static const Set<int> _retryableStatusCodes = {429, 502, 503, 504};
  static final RegExp _transientMessage = RegExp(
    r'(连接超时|网络连接失败|connection\s*(?:reset|refused|error|timeout)|'
    r'timed?\s*out|http\s*(?:429|502|503|504)\b|'
    r'\b(?:429|502|503|504)\b.*(?:error|busy|unavailable|gateway))',
    caseSensitive: false,
  );
}

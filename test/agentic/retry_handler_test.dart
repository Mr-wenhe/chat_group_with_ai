import 'dart:async';

import 'package:chat_group/core/retry_handler.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('瞬态失败执行初始调用和五次递增退避重试', () async {
    final delays = <Duration>[];
    final attempts = <RetryAttempt>[];

    final result = await RetryHandler.executeWithRetry<Map<String, dynamic>>(
      operation: (attempt) async {
        attempts.add(attempt);
        return {'success': false, 'message': 'HTTP 503: busy'};
      },
      shouldRetryResult: RetryHandler.isTransientResult,
      sleep: (delay) async => delays.add(delay),
    );

    expect(result['success'], isFalse);
    expect(attempts.length, 6);
    expect(delays, const [
      Duration.zero,
      Duration(milliseconds: 500),
      Duration(milliseconds: 1500),
      Duration(milliseconds: 3000),
      Duration(milliseconds: 5000),
    ]);
    expect(attempts[4].temperatureFor(0.9), 0.6);
    expect(attempts[5].temperatureFor(0.9), 0.4);
    expect(attempts[4].useStreaming, isTrue);
    expect(attempts[5].useStreaming, isFalse);
  });

  test('成功后立即停止重试', () async {
    var calls = 0;
    final result = await RetryHandler.executeWithRetry<int>(
      operation: (_) async => ++calls,
      shouldRetryResult: (value) => value < 3,
      sleep: (_) async {},
    );

    expect(result, 3);
    expect(calls, 3);
  });

  test('400 客户端错误不重试而 429 会重试', () {
    expect(
      RetryHandler.isTransientResult(
        const {'success': false, 'message': 'HTTP 400: invalid request'},
      ),
      isFalse,
    );
    expect(
      RetryHandler.isTransientResult(
        const {'success': false, 'message': 'HTTP 429: rate limited'},
      ),
      isTrue,
    );
  });

  test('识别 Dio 超时、连接失败和指定服务端状态码', () {
    final options = RequestOptions(path: '/chat');
    expect(
      RetryHandler.isTransientError(
        DioException.connectionTimeout(
          timeout: const Duration(seconds: 1),
          requestOptions: options,
        ),
      ),
      isTrue,
    );
    expect(RetryHandler.isTransientError(TimeoutException('timeout')), isTrue);
    expect(
      RetryHandler.isTransientError(
        DioException.badResponse(
          statusCode: 404,
          requestOptions: options,
          response: Response(requestOptions: options, statusCode: 404),
        ),
      ),
      isFalse,
    );
  });
}

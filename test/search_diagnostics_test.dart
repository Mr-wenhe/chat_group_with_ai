import 'dart:convert';
import 'dart:io';

import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/ai_governance/search_failure_classifier.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SearchAuditEntry', () {
    test('reads legacy maps with safe V2 defaults', () {
      final entry = SearchAuditEntry.fromMap({
        'conversationId': 'group-1',
        'query': 'old query',
        'searchedAt': '2026-08-22T01:02:03Z',
        'status': 'completed',
        'sources': ['https://example.com/source'],
      });

      expect(entry.requestId, isEmpty);
      expect(entry.provider, 'duckDuckGoInstantAnswer');
      expect(entry.failureType, isNull);
      expect(entry.statusCode, isNull);
      expect(entry.latencyMs, 0);
      expect(entry.retryCount, 0);
      expect(entry.fromCache, isFalse);
      expect(entry.sourceCount, 1);
      expect(entry.query, 'old query');
      expect(entry.queryPreview, 'old query');
    });

    test('round trips the diagnostic fields', () {
      final entry = SearchAuditEntry(
        requestId: 'req-1',
        conversationId: 'group-1',
        query: 'Flutter latest stable',
        searchedAt: DateTime.utc(2026, 8, 22, 1, 2, 3),
        status: 'failed',
        provider: 'duckDuckGoInstantAnswer',
        sourceCount: 0,
        sources: const [],
        failureType: SearchFailureType.rateLimited.name,
        statusCode: 429,
        latencyMs: 812,
        retryCount: 2,
        fromCache: false,
      );

      final restored = SearchAuditEntry.fromMap(entry.toMap());

      expect(restored.requestId, 'req-1');
      expect(restored.provider, 'duckDuckGoInstantAnswer');
      expect(restored.failureType, 'rateLimited');
      expect(restored.statusCode, 429);
      expect(restored.latencyMs, 812);
      expect(restored.retryCount, 2);
      expect(restored.fromCache, isFalse);
      expect(restored.sourceCount, 0);
    });

    test('does not persist API keys, authorization, or response bodies', () {
      const secret = 'sk-live-stage01-secret';
      const tavilyKey = 'tvly-dev-abcdefghijklmnopqrstuvwxyz';
      const braveKey = 'bce-v3/abcdefghijklmnopqrstuvwxyz';
      const googleKey = 'AIzaSyAbCdefGhIJKlMnOpQrStUvWxYz123456';
      const opaqueKey = 'BraveKeyABC123xyz987uvw654';
      final entry = SearchAuditEntry(
        requestId: 'req-sensitive',
        conversationId: 'group-1',
        query: 'Authorization: Bearer $secret '
            'tv=$tavilyKey brave=$braveKey google=$googleKey '
            'key=$opaqueKey 搜索当前版本',
        searchedAt: DateTime.utc(2026, 8, 22),
        status: 'failed',
        sources: [
          'https://example.com/result?api_key=$secret',
          'https://example.com/path/$braveKey',
          'https://example.com/safe',
        ],
        failureType: SearchFailureType.unknown.name,
      );

      final serialized = jsonEncode(entry.toMap());

      expect(serialized, isNot(contains(secret)));
      expect(serialized, isNot(contains(tavilyKey)));
      expect(serialized, isNot(contains(braveKey)));
      expect(serialized, isNot(contains(googleKey)));
      expect(serialized, isNot(contains(opaqueKey)));
      expect(serialized.toLowerCase(), isNot(contains('authorization')));
      expect(serialized.toLowerCase(), isNot(contains('response body')));
      expect(serialized, contains('requestId'));
      expect(serialized, contains('sourceCount'));
    });

    test('counts only retained, sanitized sources', () {
      final entry = SearchAuditEntry(
        conversationId: 'group-1',
        query: 'safe query',
        searchedAt: DateTime.utc(2026, 8, 22),
        status: 'completed',
        sourceCount: 4,
        sources: const [
          'https://example.com/safe',
          'ftp://example.com/not-supported',
          'https://example.com/path/tvly-dev-secret-token',
          'https://example.com/another-safe',
        ],
      );

      expect(entry.sources, [
        'https://example.com/safe',
        'https://example.com/another-safe',
      ]);
      expect(entry.sourceCount, 2);
    });
  });

  group('searchFailureTypeFromDioException', () {
    final cases = <String, ({DioException error, SearchFailureType expected})>{
      'connection timeout': (
        error: _dioException(DioExceptionType.connectionTimeout),
        expected: SearchFailureType.connectionTimeout,
      ),
      'send timeout': (
        error: _dioException(DioExceptionType.sendTimeout),
        expected: SearchFailureType.connectionTimeout,
      ),
      'receive timeout': (
        error: _dioException(DioExceptionType.receiveTimeout),
        expected: SearchFailureType.receiveTimeout,
      ),
      'connection error': (
        error: _dioException(DioExceptionType.connectionError),
        expected: SearchFailureType.connection,
      ),
      '401 unauthorized': (
        error: _dioException(DioExceptionType.badResponse, statusCode: 401),
        expected: SearchFailureType.unauthorized,
      ),
      '403 forbidden': (
        error: _dioException(DioExceptionType.badResponse, statusCode: 403),
        expected: SearchFailureType.forbidden,
      ),
      '402 quota exceeded': (
        error: _dioException(DioExceptionType.badResponse, statusCode: 402),
        expected: SearchFailureType.quotaExceeded,
      ),
      '429 rate limited': (
        error: _dioException(DioExceptionType.badResponse, statusCode: 429),
        expected: SearchFailureType.rateLimited,
      ),
      '408 request timeout': (
        error: _dioException(DioExceptionType.badResponse, statusCode: 408),
        expected: SearchFailureType.connectionTimeout,
      ),
      '5xx provider unavailable': (
        error: _dioException(DioExceptionType.badResponse, statusCode: 503),
        expected: SearchFailureType.providerUnavailable,
      ),
      'other HTTP response is invalid response': (
        error: _dioException(DioExceptionType.badResponse, statusCode: 400),
        expected: SearchFailureType.invalidResponse,
      ),
      'bad certificate is TLS failure': (
        error: _dioException(DioExceptionType.badCertificate),
        expected: SearchFailureType.tls,
      ),
      'socket host lookup is DNS failure': (
        error: _dioException(
          DioExceptionType.connectionError,
          error: const SocketException('Failed host lookup: api.example.com'),
        ),
        expected: SearchFailureType.dns,
      ),
      'unreachable network is offline': (
        error: _dioException(
          DioExceptionType.connectionError,
          error: const SocketException('Network is unreachable'),
        ),
        expected: SearchFailureType.offline,
      ),
      'permission denied is permission failure': (
        error: _dioException(
          DioExceptionType.connectionError,
          error: const SocketException('Permission denied'),
        ),
        expected: SearchFailureType.permissionMissing,
      ),
      'invalid base URL is configuration failure': (
        error: _dioException(
          DioExceptionType.unknown,
          error: ArgumentError('invalid baseUrl'),
        ),
        expected: SearchFailureType.invalidConfiguration,
      ),
      'cancel is cancelled': (
        error: _dioException(DioExceptionType.cancel),
        expected: SearchFailureType.cancelled,
      ),
      'unknown remains unknown': (
        error: _dioException(DioExceptionType.unknown),
        expected: SearchFailureType.unknown,
      ),
    };

    for (final item in cases.entries) {
      test(item.key, () {
        expect(
          searchFailureTypeFromDioException(item.value.error),
          item.value.expected,
        );
      });
    }
  });
}

DioException _dioException(
  DioExceptionType type, {
  int? statusCode,
  Object? error,
}) {
  final requestOptions = RequestOptions(path: '/search');
  return DioException(
    requestOptions: requestOptions,
    type: type,
    error: error,
    message: 'response body contains Authorization: Bearer sk-secret',
    response: statusCode == null
        ? null
        : Response<dynamic>(
            requestOptions: requestOptions,
            statusCode: statusCode,
            data: const {'error': 'complete response body'},
          ),
  );
}

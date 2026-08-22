import 'package:flutter_test/flutter_test.dart';
import 'package:chat_group/services/web_search_service.dart';
import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:dio/dio.dart';

void main() {
  group('WebSearchService', () {
    test('detects current or explicit search questions', () {
      final service = WebSearchService();

      expect(service.shouldSearch('帮我联网搜索 Flutter 最新版本'), isTrue);
      expect(service.shouldSearch('今天上海天气怎么样'), isTrue);
      expect(service.shouldSearch('Who is the current CEO?'), isTrue);
      expect(service.shouldSearch('search the web for release notes'), isTrue);
    });

    test('does not search ordinary stable chat', () {
      final service = WebSearchService();

      expect(service.shouldSearch('帮我写一段开场白'), isFalse);
      expect(service.shouldSearch('你觉得这个角色应该怎么说话'), isFalse);
      expect(service.shouldSearch(''), isFalse);
      expect(service.shouldSearch(null), isFalse);
    });

    test('formats no-result prompt as anti-fabrication guidance', () {
      final snapshot = WebSearchSnapshot(
        query: '某个没有结果的问题',
        searchedAt: DateTime(2026, 7, 9, 12),
        results: const [],
      );

      final prompt = snapshot.toPromptContext();
      expect(prompt, contains('没有找到可用结果'));
      expect(prompt, contains('不要编造'));
    });

    test('treats a failure type without a legacy error string as failure', () {
      final snapshot = WebSearchSnapshot(
        query: '某个失败的问题',
        searchedAt: DateTime(2026, 7, 9, 12),
        results: const [],
        failureType: SearchFailureType.dns,
      );

      final prompt = snapshot.toPromptContext();
      expect(snapshot.hasFailure, isTrue);
      expect(prompt, contains('失败'));
      expect(prompt, contains('不要编造'));
    });

    test('returns safe failure diagnostics without the Dio payload', () async {
      const secret = 'sk-live-response-secret';
      final dio = Dio();
      dio.interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.reject(
            DioException(
              requestOptions: options,
              type: DioExceptionType.badResponse,
              message: 'Authorization: Bearer $secret; response body: $secret',
              response: Response<dynamic>(
                requestOptions: options,
                statusCode: 401,
                data: {'error': 'full response body $secret'},
              ),
            ),
          );
        },
      ));

      final snapshot =
          await WebSearchService(dio: dio).search('current Flutter');

      expect(snapshot.requestId, isNotEmpty);
      expect(snapshot.provider, SearchAuditEntry.legacyProvider);
      expect(snapshot.failureType, SearchFailureType.unauthorized);
      expect(snapshot.statusCode, 401);
      expect(snapshot.safeMessage, isNot(contains(secret)));
      expect(snapshot.safeMessage, contains('凭据'));
      expect(snapshot.error, snapshot.safeMessage);
      expect(snapshot.results, isEmpty);
    });
  });
}

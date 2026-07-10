import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/features/agentic/agent_runtime.dart';

/// 验证桥接调用错误的分类逻辑：连接级错误 vs HTTP 状态码错误。
///
/// 修复前 `_toolFailureMessage` 用字符串包含判断，把任意 DioException
/// （含 404/400/403 等 HTTP 状态码）都误报为「桥接未连接」，误导用户以为服务宕机。
void main() {
  group('AgentRuntime.classifyBridgeError', () {
    test('DioException 无响应体(connectionError) → 连接错误', () {
      final error = DioException(
        requestOptions: RequestOptions(path: '/workspace/apply-patch'),
        type: DioExceptionType.connectionError,
      );
      final kind = AgentRuntime.classifyBridgeError(error);
      expect(kind.isConnection, isTrue);
      expect(kind.statusCode, isNull);
    });

    test('DioException statusCode=404 → HTTP 404（非连接错误）', () {
      final error = DioException(
        requestOptions: RequestOptions(path: '/workspace/apply-patch'),
        response: Response(
          requestOptions: RequestOptions(path: '/workspace/apply-patch'),
          statusCode: 404,
        ),
      );
      final kind = AgentRuntime.classifyBridgeError(error);
      expect(kind.isConnection, isFalse);
      expect(kind.statusCode, 404);
    });

    test('DioException statusCode=400 → HTTP 400（非连接错误）', () {
      final error = DioException(
        requestOptions: RequestOptions(path: '/workspace/apply-patch'),
        response: Response(
          requestOptions: RequestOptions(path: '/workspace/apply-patch'),
          statusCode: 400,
        ),
      );
      final kind = AgentRuntime.classifyBridgeError(error);
      expect(kind.isConnection, isFalse);
      expect(kind.statusCode, 400);
    });

    test('普通异常含 Connection refused 文本 → 连接错误（兜底）', () {
      final error = Exception('SocketException: Connection refused');
      final kind = AgentRuntime.classifyBridgeError(error);
      expect(kind.isConnection, isTrue);
    });

    test('普通异常（无连接关键词） → other', () {
      final error = Exception('some unrelated error');
      final kind = AgentRuntime.classifyBridgeError(error);
      expect(kind.isConnection, isFalse);
      expect(kind.statusCode, isNull);
    });
  });

  group('AgentRuntime._toolFailureMessage 文案', () {
    // 最小 AICharacter 桩（仅需要 name 字段用于文案）。
    final character = AICharacter(
      name: '范晓萌',
      avatar: '',
      age: 18,
      role: '',
      personalityTags: const [],
      systemPrompt: '',
      apiKey: '',
      apiProvider: 'deepseek',
    );

    String messageFor(Object error) {
      final runtime = AgentRuntime(
        complete: (_) async => <String, dynamic>{},
      );
      return runtime.toolFailureMessage(character, error);
    }

    test('连接错误文案含「未连接」', () {
      final error = DioException(
        requestOptions: RequestOptions(path: '/x'),
        type: DioExceptionType.connectionError,
      );
      final msg = messageFor(error);
      expect(msg, contains('未连接'));
      expect(msg, contains('范晓萌'));
    });

    test('404 文案含「404」且不含「未连接」', () {
      final error = DioException(
        requestOptions: RequestOptions(path: '/x'),
        message:
            'This exception was thrown because RequestOptions.validateStatus rejected the response. '
            'Read more about status codes at developer.mozilla.org.',
        response: Response(
          requestOptions: RequestOptions(path: '/x'),
          statusCode: 404,
        ),
      );
      final msg = messageFor(error);
      expect(msg, contains('404'));
      expect(msg, isNot(contains('未连接')));
      expect(msg, isNot(contains('RequestOptions.validateStatus')));
      expect(msg, isNot(contains('Read more about status codes')));
      expect(msg.length, lessThan(260));
    });
  });
}

// AI 落子重试与错误暴露测试：验证瞬时故障后会重试而非直接代落。
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/models/api_protocol.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/features/game/gomoku/ai_gomoku_player.dart';
import 'package:chat_group/features/game/gomoku/gomoku_board.dart';
import 'package:chat_group/services/chat_api_service.dart';
import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter_test/flutter_test.dart';

/// 假的凭据解析器：恒返回一个 key。
class _FakeResolver implements ApiCredentialResolver {
  @override
  Future<String?> resolve(ApiConfig config) async => 'test-key';
}

/// 假的 API：按脚本依次返回结果；记录调用次数。
class _ScriptedApi extends ChatApiService {
  final List<Map<String, dynamic>> _script;
  int calls = 0;
  List<Map<String, dynamic>> lastMessages = const [];
  int? lastMaxRetries;
  Duration? lastReceiveTimeout;

  _ScriptedApi(this._script) : super();

  @override
  Future<Map<String, dynamic>> sendChatMessage({
    required String apiKey,
    required ApiProvider provider,
    ApiProtocol apiProtocol = ApiProtocol.defaultValue,
    String? customBaseUrl,
    String? userAgent,
    required String model,
    required List<Map<String, dynamic>> messages,
    double temperature = 0.85,
    int maxTokens = 1024,
    Duration? receiveTimeout,
    int maxRetries = 5,
    CancelToken? cancelToken,
    bool allowReasoningContentFallback = false,
    String? promptCacheKey,
  }) async {
    final index = calls < _script.length ? calls : _script.length - 1;
    calls++;
    lastMessages = messages;
    lastMaxRetries = maxRetries;
    lastReceiveTimeout = receiveTimeout;
    return _script[index];
  }
}

AICharacter _character() => AICharacter(
      name: '测试角色',
      avatar: '测',
      age: 20,
      role: '棋手',
      personalityTags: const [],
      systemPrompt: '下棋',
      apiKey: 'unused',
      apiProvider: 'custom',
    );

AiGomokuPlayer _player(ChatApiService api) => AiGomokuPlayer(
      character: _character(),
      config: ApiConfig(name: 't', provider: 'custom', hasCredential: true),
      api: api,
      credentials: _FakeResolver(),
    );

void main() {
  final board = GomokuBoard();

  test('首次 429 限流、第二次成功 → 返回真实落子', () async {
    final api = _ScriptedApi([
      {'success': false, 'message': '请求过于频繁', 'statusCode': 429, 'retryAfterMs': 1},
      {'success': true, 'message': '好的，我下这里\n{"row":7,"col":7}'},
    ]);
    final decision = await _player(api).decideMove(
      board: board,
      myStone: GomokuStone.black,
    );
    expect(decision.isSuccess, isTrue);
    expect(decision.position, const GomokuPosition(7, 7));
    expect(api.calls, 2, reason: '应重试一次');
  });

  test('请求持续失败耗尽重试 → 返回真实错误原因', () async {
    final api = _ScriptedApi([
      {'success': false, 'message': '请求过于频繁', 'statusCode': 429},
    ]);
    final decision = await _player(api).decideMove(
      board: board,
      myStone: GomokuStone.black,
    );
    expect(decision.isSuccess, isFalse);
    expect(decision.error, contains('请求过于频繁'));
    expect(api.calls, 2, reason: '首次 + 1 次兜底重试');
  });

  test('空 reasoning 的失败也会带出错误文本供观战区展示', () async {
    final api = _ScriptedApi([
      {'success': false, 'message': '连接超时'},
    ]);
    final decision = await _player(api).decideMove(
      board: board,
      myStone: GomokuStone.black,
    );
    expect(decision.reasoning, isEmpty);
    expect(decision.error, contains('连接超时'));
  });

  test('空响应会把上游诊断信号带进错误文本', () async {
    final api = _ScriptedApi([
      {
        'success': false,
        'message': '模型返回了空内容',
        'retryable': true,
        'emptyCompletionDetail': {
          'finishReason': 'length',
          'reasoningTokens': 2048,
        },
      },
    ]);
    final decision = await _player(api).decideMove(
      board: board,
      myStone: GomokuStone.black,
    );
    expect(decision.isSuccess, isFalse);
    expect(decision.error, contains('模型返回了空内容'));
    expect(decision.error, contains('finishReason=length'));
    expect(decision.error, contains('reasoningTokens=2048'));
  });

  test('首轮就传紧凑 JSON-first prompt，不给长思考留空间', () async {
    final api = _ScriptedApi([
      {'success': true, 'message': '{"row":7,"col":7}'},
    ]);
    await _player(api).decideMove(board: board, myStone: GomokuStone.black);
    final systemText = api.lastMessages.first['content'] as String;
    expect(systemText, contains('不要展开推理过程'), reason: '首轮就应抑制长思考');
    expect(systemText, contains('{"row":行号,"col":列号}'));
  });

  test('关闭底层隐藏重试且用短超时，杜绝 45s→65s 的耗时放大', () async {
    final api = _ScriptedApi([
      {'success': true, 'message': '{"row":7,"col":7}'},
    ]);
    await _player(api).decideMove(board: board, myStone: GomokuStone.black);
    expect(api.lastMaxRetries, 0, reason: '必须关掉底层默认 5 次重试');
    expect(api.lastReceiveTimeout, const Duration(seconds: 18));
  });

  test('成功决策带出耗时', () async {
    final api = _ScriptedApi([
      {'success': true, 'message': '{"row":7,"col":7}'},
    ]);
    final decision = await _player(api).decideMove(
      board: board,
      myStone: GomokuStone.black,
    );
    expect(decision.isSuccess, isTrue);
    expect(decision.elapsedMs, greaterThanOrEqualTo(0));
  });

  test('解析失败会重试，拿到坐标即成功', () async {
    final api = _ScriptedApi([
      {'success': true, 'message': '让我想想...没有坐标'},
      {'success': true, 'message': '{"row":3,"col":4}'},
    ]);
    final decision = await _player(api).decideMove(
      board: board,
      myStone: GomokuStone.black,
    );
    expect(decision.isSuccess, isTrue);
    expect(decision.position, const GomokuPosition(3, 4));
    expect(api.calls, 2);
  });

  test('角色未绑定模型配置时快速失败，由上层的棋力辅助接手', () async {
    final api = _ScriptedApi([]);
    final player = AiGomokuPlayer(
      character: _character(),
      config: null,
      api: api,
      credentials: _FakeResolver(),
    );
    final decision = await player.decideMove(
      board: board,
      myStone: GomokuStone.black,
    );
    expect(decision.isSuccess, isFalse);
    expect(decision.error, contains('未绑定模型配置'));
    expect(api.calls, 0);
  });
}

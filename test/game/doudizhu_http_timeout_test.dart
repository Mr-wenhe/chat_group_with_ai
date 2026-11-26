import 'dart:async';
import 'dart:io';

import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/features/game/doudizhu/doudizhu_ai_player.dart';
import 'package:chat_group/features/game/doudizhu/doudizhu_game_state.dart';
import 'package:chat_group/services/chat_api_service.dart';
import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter_test/flutter_test.dart';

class _Credentials implements ApiCredentialResolver {
  @override
  Future<String?> resolve(ApiConfig config) async => 'test-key';
}

class _HardSelector implements DoudizhuHardMoveSelector {
  int calls = 0;

  @override
  Future<DoudizhuHardDecision?> decide(
    DoudizhuAiTurnInput input, {
    CancelToken? cancelToken,
  }) async {
    calls++;
    return const DoudizhuHardDecision(
      action: DoudizhuBidAction(0),
      elapsedMilliseconds: 0,
      candidateCount: 1,
      handsBefore: 5,
      handsAfter: 5,
      score: 0,
    );
  }
}

DoudizhuAiTurnInput _input() => DoudizhuAiTurnInput(
      seat: 0,
      seatName: '白果',
      teamLabel: '叫分中',
      phase: DoudizhuPhase.bidding,
      ownHand: const [0, 4, 8],
      bids: const [null, null, null],
      handSizes: const [17, 17, 17],
      publicLog: const [],
      options: const [
        DoudizhuActionOption(
          actionId: 'b0',
          action: DoudizhuBidAction(0),
          typeLabel: '叫分',
          cardIds: [],
          bidScore: 0,
        ),
      ],
      highestBid: 0,
      landlord: -1,
      passCount: 0,
      multiplier: 1,
    );

void main() {
  test('慢速分块响应不拖住回合：总时限到点即回退到本地策略', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final filler = List<String>.filled(64 * 1024, 'x').join();
    final chunks = <String>[
      '{"choices":[{"message":{"content":"',
      '{"actionId":"b0"}',
      // 一条写不完的慢流：1000 块 × 20ms 约需 20 秒才能写完，因此
      // 「回合总时限是否生效」可以直接用调用方耗时判断，不必去数
      // 服务端还能写多少块。
      for (var index = 0; index < 1000; index++) filler,
      '"}}]}',
    ];
    unawaited(server.forEach((request) async {
      final response = request.response;
      response.bufferOutput = false;
      response.headers.contentType = ContentType.json;
      try {
        for (final chunk in chunks) {
          response.write(chunk);
          await response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      } on Object {
        // 对端关闭连接或写入被对端阻塞都属预期。
      } finally {
        try {
          await response.close();
        } on Object {
          // The client may already have closed the response socket.
        }
      }
    }));

    final hard = _HardSelector();
    final config = ApiConfig(
      name: '本地 HTTP 替身',
      provider: ApiProvider.custom.name,
      modelName: 'local-test',
      customBaseUrl: 'http://127.0.0.1:${server.port}/v1',
      hasCredential: true,
    );
    final player = DoudizhuCharacterPlayer(
      primary: AiDoudizhuPlayer(
        character: AICharacter(
          name: '白果',
          avatar: '白',
          age: 24,
          role: '牌手',
          personalityTags: const [],
          systemPrompt: '',
          apiKey: '',
          apiProvider: 'custom',
        ),
        config: config,
        api: ChatApiService(),
        credentials: _Credentials(),
        requestTimeout: const Duration(seconds: 2),
        turnTimeout: const Duration(milliseconds: 130),
      ),
      fallback: hard,
    );

    try {
      final startedAt = DateTime.now();
      final decision = await player.decide(_input());
      final elapsed = DateTime.now().difference(startedAt);
      expect(decision?.source, DoudizhuDecisionSource.masterFallback);
      expect(decision?.action, isA<DoudizhuBidAction>());
      expect(hard.calls, 0); // 叫分由原阈值策略兜底，无需出牌引擎。
      // 回合总时限 130ms，而这条流要写约 20 秒：调用方必须远早于整条流
      // 结束就返回，才算「受回合总时限截断」。
      //
      // 这里刻意不断言「取消后服务端停止发送」：dio 的 CancelToken 只保证
      // 调用方尽早返回，不保证拆掉已开始的传输 —— 请求尚未发出时取消，
      // abort 拿不到 request 对象；响应头已到达后取消，dart:io 的
      // HttpClientRequest.abort() 是空操作（_responseCompleter 已完成）。
      // 实测在 CI 负载下服务端会继续写完数十 MB，曾经按发送计数断言，
      // 结果随机器负载在 CI 上抖动失败（2026-11-26 Release run）。
      expect(elapsed, lessThan(const Duration(seconds: 8)),
          reason: '取消后应立即回退，而不是等整条流写完');
    } finally {
      await server.close(force: true);
    }
  }, timeout: const Timeout(Duration(seconds: 20)));
}

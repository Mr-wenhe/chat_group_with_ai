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
  test('持续分块 HTTP 响应受回合总时限截断并取消 socket', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var sent = 0;
    final filler = List<String>.filled(64 * 1024, 'x').join();
    final chunks = <String>[
      '{"choices":[{"message":{"content":"',
      '{"actionId":"b0"}',
      // 数据量必须远大于任何平台的内核发送/接收缓冲，否则取消后对端
      // 内核可能把整条流吸收完，无法从服务端侧判断取消是否生效。
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
          sent++;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      } on Object {
        // A cancelled client closes or stalls the server write stream.
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
      final decision = await player.decide(_input());
      expect(decision?.source, DoudizhuDecisionSource.masterFallback);
      expect(decision?.action, isA<DoudizhuBidAction>());
      expect(hard.calls, 0); // 叫分由原阈值策略兜底，无需出牌引擎。
      expect(sent, lessThan(chunks.length));
      expect(sent, greaterThan(0));
      // 取消后已排队的字节仍可能被对端内核吸收一段时间，各平台缓冲差异
      // 很大（Linux 可达数 MB，macOS 明显更小），按固定时间断言会随平台
      // 与机器负载抖动。数据量已远大于任何内核缓冲，发送计数最终必然停止
      // 增长：要么 socket 已关闭，要么发送缓冲已满、写入被阻塞。
      final drainDeadline = DateTime.now().add(const Duration(seconds: 12));
      var previousSent = -1;
      while (DateTime.now().isBefore(drainDeadline)) {
        previousSent = sent;
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (sent == previousSent) break;
      }
      expect(sent, previousSent, reason: '取消后服务端仍能无限发送');
      expect(sent, lessThan(chunks.length), reason: '取消后服务端仍把整条流发完');
    } finally {
      await server.close(force: true);
    }
  }, timeout: const Timeout(Duration(seconds: 20)));
}

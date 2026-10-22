import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/api_protocol.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/streaming/chat_stream_event.dart';
import 'package:chat_group/features/chat_group/widgets/chat_room_composer.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/chat_room_round_fixture.dart';
import 'helpers/lifecycle_hive.dart';

/// 模型返回空内容时的兜底台词必须是**一对一**的措辞。
///
/// 私聊的合成展示群 `theme` 是「一对一私聊」这样的内部标识，兜底句若照搬群聊那套
/// 就会写出「说到一对一私聊，我觉得可以先听听其他人的看法」——一对一里没有
/// "其他人"，话题词也不是给用户看的。
class EmptyReplyChatApi extends ScriptedChatApi {
  @override
  Future<Map<String, dynamic>> sendChatMessage({
    required String apiKey,
    required ApiProvider provider,
    ApiProtocol apiProtocol = ApiProtocol.defaultValue,
    String? customBaseUrl,
    required String model,
    required List<Map<String, dynamic>> messages,
    double? temperature,
    int? maxTokens,
    Duration? receiveTimeout,
    int? maxRetries,
    CancelToken? cancelToken,
    bool allowReasoningContentFallback = false,
    String? promptCacheKey,
  }) async {
    replyCalls.add(messages);
    return {'success': true, 'message': ''};
  }

  @override
  Stream<ChatStreamEvent> streamChatMessage({
    required String apiKey,
    required ApiProvider provider,
    ApiProtocol apiProtocol = ApiProtocol.defaultValue,
    String? customBaseUrl,
    required String model,
    required List<Map<String, dynamic>> messages,
    double temperature = 0.85,
    int maxTokens = 1024,
    Duration receiveTimeout = const Duration(seconds: 120),
    CancelToken? cancelToken,
    bool finishOnTerminalFrame = false,
    String? reasoningEffort,
    void Function()? onResponseActivity,
    String? promptCacheKey,
  }) async* {
    replyCalls.add(messages);
    yield ChatStreamEvent.done('');
  }
}

void main() {
  late Directory directory;
  late DatabaseService db;

  setUpAll(() async {
    installTtsChannelMock();
    directory = await openLifecycleHive();
    db = DatabaseService();
    await openGovernanceLedgerBox();
  });

  tearDownAll(() => tearDownRoundFixture(directory));

  testWidgets('私聊空回复兜底用一对一措辞，不带内部群标识', (tester) async {
    addTearDown(() => disposeRoundRoom(tester));
    await tester.runAsync(() async {
      await db.apiConfigBox.put('cfg-a', roundTestConfig('cfg-a'));
      await db.appSettingsBox.put(
        'ai_governance_budget_v1',
        const {'autoChatEnabled': false},
      );
      await db.aiCharacterBox.put(
        'va',
        testCharacter('va', apiConfigId: 'cfg-a')
          ..name = '产品经理'
          ..role = '产品经理'
          ..age = 26,
      );
    });
    final api = EmptyReplyChatApi();
    final hostKey = GlobalKey<RoundRoomHostState>();
    await pumpRoundRoom(
      tester,
      hostKey: hostKey,
      groupId: 'dm:va',
      api: api,
      db: db,
      directory: directory,
    );

    await tester.enterText(find.byType(TextField), '你说点有趣的事情呗');
    final composer =
        tester.widget<ChatRoomComposer>(find.byType(ChatRoomComposer));
    await tester.runAsync(() async {
      composer.onSend();
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await waitForReply(tester, api);
    var replyPersisted = false;
    for (var step = 0; step < 160 && !replyPersisted; step++) {
      replyPersisted = await tester.runAsync(() async {
            await Future<void>.delayed(const Duration(milliseconds: 20));
            return db.messageBox.values.any((message) =>
                message.groupId == 'dm:va' && message.senderType == 'ai');
          }) ??
          false;
      if (!replyPersisted) await tester.pump(const Duration(milliseconds: 50));
    }
    expect(api.replyCalls, isNotEmpty, reason: '私聊回合必须真的发出请求');

    final replies = db.messageBox.values
        .where((message) =>
            message.groupId == 'dm:va' && message.senderType == 'ai')
        .map((message) => message.content)
        .toList();
    expect(replies, isNotEmpty, reason: '空回复必须给出可见兜底');
    for (final reply in replies) {
      expect(reply, isNot(contains('一对一私聊')));
      expect(reply, isNot(contains('其他人')));
      expect(reply, isNot(contains('你们')));
      expect(reply.trim(), isNotEmpty);
    }

    await settleRoundTimers(tester);
  });
}

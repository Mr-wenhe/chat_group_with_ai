import 'dart:io';
import 'dart:convert';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/api_protocol.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/features/chat_group/chat_room_page.dart';
import 'package:chat_group/features/chat_group/chat_reply_prompt_guard.dart';
import 'package:chat_group/services/chat_api_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/chat_room_round_fixture.dart';
import 'helpers/lifecycle_hive.dart';

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

  testWidgets('私聊第二三条承接已发消息，新输入重新正常回答', (tester) async {
    addTearDown(() => disposeRoundRoom(tester));
    final character = testCharacter('va', apiConfigId: 'cfg-a');
    await tester.runAsync(() async {
      await db.apiConfigBox.put('cfg-a', roundTestConfig('cfg-a'));
      await db.aiCharacterBox.put('va', character);
      await db.appSettingsBox
          .put('ai_governance_budget_v1', const {'autoChatEnabled': false});
    });
    await pumpRoundRoom(tester,
        hostKey: GlobalKey<RoundRoomHostState>(),
        groupId: 'dm:va',
        api: ScriptedChatApi(),
        db: db,
        directory: directory);
    final dynamic state = tester.state(find.byType(ChatRoomPage));
    Message message(String role, String text) => Message(
        groupId: 'dm:va',
        senderId: role == 'ai' ? character.id : 'user',
        senderType: role,
        content: text);
    final user = message('user', '是无限恐怖！');
    final first = message('ai', '原来是《无限恐怖》啊！你最喜欢哪个人物？');
    final second = message('ai', '我自己更喜欢郑吒的成长。');
    for (final history in [
      <Message>[],
      [first],
      [user],
      [user, first],
      [user, first, second],
      [user, first, second, message('user', '我喜欢楚轩')]
    ]) {
      final List<Map<String, dynamic>> prompt = await state.buildPromptMessages(
          character: character, context: history, isAutoChat: true);
      final instructions = prompt
          .where((m) => m['role'] == 'system')
          .map((m) => m['content'])
          .join('\n');
      final continuing = history.isNotEmpty && history.last.senderType == 'ai';
      expect(instructions.contains('你已经发过消息，用户还没有新回复'), continuing);
      expect(instructions, isNot(contains('请自然回应对方当前消息')));
      if (continuing) {
        expect(instructions, contains('不要换一种说法重新回答'));
        expect(prompt.last['role'], 'user');
        expect(prompt.last['content'], contains('继续发送下一条私聊'));
        expect(prompt[prompt.length - 2]['role'], 'assistant');
        expect(prompt[prompt.length - 2]['content'], history.last.content);
        final List<Map<String, dynamic>> compressed =
            await state.buildPromptMessages(
                character: character,
                context: ChatReplyPromptGuard.currentExchange(history),
                transientContextSummary: '旧回合摘要',
                isAutoChat: true);
        expect(compressed.last['role'], 'user');
        expect(
            compressed[compressed.length - 2]['content'], history.last.content);
        expect(compressed.map((m) => m['content']).join('\n'),
            contains('不要换一种说法重新回答'));
        // 在实际序列化边界检查四种协议；模型替身不负责拼装请求。
        await tester.runAsync(() async {
          for (final protocol in ApiProtocol.values) {
            Map<String, dynamic>? sent;
            final dio = Dio();
            dio.interceptors
                .add(InterceptorsWrapper(onRequest: (options, handler) {
              sent = Map<String, dynamic>.from(options.data as Map);
              handler.resolve(Response<ResponseBody>(
                  requestOptions: options,
                  statusCode: 200,
                  data: ResponseBody.fromString('data: [DONE]\n\n', 200,
                      headers: {
                        Headers.contentTypeHeader: ['text/event-stream']
                      })));
            }));
            try {
              await ChatApiService(dio: dio)
                  .streamChatMessage(
                      apiKey: 'test-key',
                      provider: ApiProvider.custom,
                      apiProtocol: protocol,
                      customBaseUrl: 'https://example.test/v1',
                      model: 'test-model',
                      messages: compressed)
                  .toList();
              expect(sent, isNotNull);
              final turns = (sent!['messages'] ??
                  sent!['input'] ??
                  sent!['contents']) as List;
              expect((turns.last as Map)['role'], 'user',
                  reason: protocol.name);
              expect(jsonEncode(turns.last), contains('继续发送下一条私聊'));
              expect(jsonEncode(turns[turns.length - 2]),
                  contains(history.last.content));
            } finally {
              dio.close();
            }
          }
        });
      }
    }
    final List<Map<String, dynamic>> initial = await state.buildPromptMessages(
        character: character,
        context: [user],
        userMessage: user.content,
        currentUserMessage: user);
    expect(initial.map((m) => m['content']).join('\n'),
        contains('用户刚给你发了一条消息，请自然回应'));
    await settleRoundTimers(tester);
  }, timeout: const Timeout(Duration(seconds: 30)));
}

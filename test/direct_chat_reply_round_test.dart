import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/features/chat_group/group_shared_context.dart';
import 'package:chat_group/features/chat_group/widgets/chat_room_composer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/chat_room_round_fixture.dart';
import 'helpers/lifecycle_hive.dart';

/// 私聊没有"本群固定共同设定"这回事。
///
/// 私聊的群记录是渲染用的合成记录（`description` 是"职业 · 年龄"），而私聊的
/// 提示词从不注入共同设定区块。若仍把这份合成文本当成**必需内容**交给守卫核对，
/// 每一次私聊回复都会被判成"设定放不进模型窗口"而中止——与窗口大小、消息长短
/// 都无关，用户缩设定或换大窗口模型也无从解决。
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

  testWidgets('私聊回合照常发出请求，不报「共同设定放不进窗口」', (tester) async {
    addTearDown(() => disposeRoundRoom(tester));
    await tester.runAsync(() async {
      await db.apiConfigBox.put('cfg-a', roundTestConfig('cfg-a'));
      // 关掉空闲自动聊天（私聊界面不给这个开关），让这条用户输入成为唯一
      // 待处理的请求。
      await db.appSettingsBox.put(
        'ai_governance_budget_v1',
        const {'autoChatEnabled': false},
      );
      final character = testCharacter('va', apiConfigId: 'cfg-a')
        ..name = '产品经理'
        ..role = '产品经理'
        ..age = 26;
      await db.aiCharacterBox.put('va', character);
      // 刻意留一个真实的群记录：私聊不得借道它拿到任何共同设定。
      await db.chatGroupBox.put(
        'g-other',
        ChatGroup(
          id: 'g-other',
          name: '来源群',
          theme: '日常聊天',
          description: '来源群背景_不得外泄',
          announcement: '来源群约定_不得外泄',
          aiCharacterIds: const ['va'],
        ),
      );
    });
    final api = ScriptedChatApi();
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

    expect(api.replyCalls, isNotEmpty, reason: '私聊必须真的把这一轮请求发出去');
    final sent = api.replyCalls.last
        .map((message) => message['content']?.toString() ?? '')
        .join('\n');
    // 私聊既不注入共同设定，也就不能要求它幸存。
    expect(sent, isNot(contains(GroupSharedContext.marker)));
    expect(sent, isNot(contains('来源群背景_不得外泄')));

    final persisted = db.messageBox.values
        .where((message) => message.groupId == 'dm:va')
        .map((message) => message.content)
        .join('\n');
    expect(persisted, isNot(contains('放不进当前模型的输入窗口')));

    await settleRoundTimers(tester);
  });
}

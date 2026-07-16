import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/features/ai_character/ai_character_list_page.dart';
import 'package:chat_group/features/chat_group/chat_group_list_page.dart';
import 'package:chat_group/features/settings/settings_page.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/lifecycle_hive.dart';

class _WidgetTestDatabaseService extends DatabaseService {
  @override
  Future<String> effectiveAiProcessingDirPath() async => '/tmp/ai_files';
}

void main() {
  late Directory hiveDirectory;
  late DatabaseService db;

  setUp(() async {
    hiveDirectory = await openLifecycleHive();
    db = _WidgetTestDatabaseService();
  });

  tearDown(() => closeLifecycleHive(hiveDirectory));

  Widget app(Widget home) => ProviderScope(
        overrides: [databaseServiceProvider.overrideWithValue(db)],
        child: MaterialApp(home: home),
      );

  testWidgets('group confirmation describes the actual cascade',
      (tester) async {
    await tester.runAsync(() async {
      await db.chatGroupBox.put(
        'g1',
        ChatGroup(id: 'g1', name: '测试群', theme: '', aiCharacterIds: const []),
      );
      await db.messageBox.put(
        'm1',
        Message(
          id: 'm1',
          groupId: 'g1',
          senderId: 'user',
          senderType: 'user',
          content: 'hello',
        ),
      );
    });

    await tester.pumpWidget(app(const ChatGroupListPage()));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byTooltip('删除'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('删除「测试群」？'), findsOneWidget);
    expect(find.textContaining('1 条消息'), findsOneWidget);
    expect(find.textContaining('无其他引用的 APP 附件'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('character confirmation exposes both history policies',
      (tester) async {
    await tester.runAsync(() async {
      await db.aiCharacterBox.put('c1', testCharacter('c1'));
      await db.chatGroupBox.put(
        'g1',
        ChatGroup(id: 'g1', name: '群聊', theme: '', aiCharacterIds: ['c1']),
      );
    });

    await tester.pumpWidget(app(const AICharacterListPage()));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.scrollUntilVisible(
      find.byTooltip('删除'),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.byTooltip('删除'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('保留历史消息'), findsOneWidget);
    expect(find.text('同时删除私聊历史'), findsOneWidget);
    expect(find.textContaining('1 个群聊'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('API config confirmation offers replace or explicit unlink',
      (tester) async {
    await tester.runAsync(() async {
      await db.apiConfigBox.putAll({
        'a1': ApiConfig(id: 'a1', name: '旧配置', provider: 'deepseek'),
        'a2': ApiConfig(id: 'a2', name: '新配置', provider: 'custom'),
      });
      await db.aiCharacterBox.put('c1', testCharacter('c1', apiConfigId: 'a1'));
    });

    await tester.pumpWidget(app(const SettingsPage()));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byIcon(Icons.delete_outline_rounded).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('当前有 1 个角色使用该配置'), findsOneWidget);
    expect(find.text('解绑（角色将无法回复）'), findsOneWidget);
    expect(find.textContaining('不会回退使用旧 Key'), findsOneWidget);
    await tester.tap(find.text('解绑（角色将无法回复）'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('替换为 新配置'), findsOneWidget);
    await tester.tap(find.text('替换为 新配置'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('取消'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('settings distinguishes chat, user-content and factory reset',
      (tester) async {
    await tester.pumpWidget(app(const SettingsPage()));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.scrollUntilVisible(
      find.text('清除聊天内容'),
      500,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.drag(find.byType(ListView), const Offset(0, -180));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('清除聊天内容'), findsOneWidget);
    expect(find.text('清除全部用户内容'), findsOneWidget);
    expect(find.text('恢复出厂设置'), findsOneWidget);
    expect(find.text('媒体占用'), findsOneWidget);

    await tester.tap(find.text('清除聊天内容'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.textContaining('角色、群聊、API 配置、主题、TTS 和目录偏好会保留'),
      findsOneWidget,
    );
    await tester.tap(find.text('取消'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}

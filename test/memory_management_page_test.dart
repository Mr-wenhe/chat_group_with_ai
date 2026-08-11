import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/database/data_lifecycle_settings.dart';
import 'package:chat_group/core/models/character_memory.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/permanent_memory.dart';
import 'package:chat_group/features/chat_group/chat_room_page.dart';
import 'package:chat_group/features/memory/memory_controls.dart';
import 'package:chat_group/features/memory/memory_management_page.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'helpers/lifecycle_hive.dart';

void main() {
  late Directory directory;
  late DatabaseService db;

  setUpAll(() async {
    directory = await openLifecycleHive();
    db = DatabaseService();
  });

  tearDownAll(() async {
    db.dispose();
    await TestWidgetsFlutterBinding.ensureInitialized().runAsync(() async {
      await Hive.close();
      if (await directory.exists()) await directory.delete(recursive: true);
    });
  });

  setUp(() async {
    await db.permanentMemoryBox.clear();
    await db.aiCharacterBox.clear();
    await db.messageBox.clear();
  });

  Widget app(Widget home) => ProviderScope(
        overrides: [databaseServiceProvider.overrideWithValue(db)],
        child: MaterialApp(home: home),
      );

  Future<void> scrollTo(WidgetTester tester, Finder target) async {
    await tester.scrollUntilVisible(
      target,
      240,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
  }

  Future<void> settleHiveWrites(WidgetTester tester, {int turns = 2}) async {
    for (var i = 0; i < turns; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
  }

  group('Global memory rendering', () {
    testWidgets('shows a loading state before reading the audit snapshot',
        (tester) async {
      await tester.pumpWidget(app(const MemoryManagementPage()));

      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await tester.pump();
    });

    testWidgets(
        'page reads all permanent memories globally, not by conversation',
        (tester) async {
      await tester.runAsync(() async {
        final charA = testCharacter('char-a', apiConfigId: 'cfg');
        final charB = testCharacter('char-b', apiConfigId: 'cfg');
        await db.aiCharacterBox.putAll({charA.id: charA, charB.id: charB});
        await db.permanentMemoryBox.put(
            'pm-a',
            PermanentMemory(
              observerCharacterId: 'char-a',
              kind: MemoryKind.fact,
              content: 'A在上海',
              status: MemoryStatus.active,
              originType: MemoryOriginType.group,
              originNameSnapshot: '群A',
              originConversationId: 'group-a',
            ));
        await db.permanentMemoryBox.put(
            'pm-b',
            PermanentMemory(
              observerCharacterId: 'char-b',
              kind: MemoryKind.fact,
              content: 'B在北京',
              status: MemoryStatus.active,
              originType: MemoryOriginType.group,
              originNameSnapshot: '群B',
              originConversationId: 'group-b',
            ));
        await tester.pumpWidget(app(
          const MemoryManagementPage(),
        ));
      });
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('A在上海'), findsOneWidget);
      expect(find.text('B在北京'), findsOneWidget);
    });

    testWidgets('deleted observer character is rendered as a placeholder',
        (tester) async {
      await tester.runAsync(() async {
        await db.permanentMemoryBox.put(
            'pm-deleted',
            PermanentMemory(
              observerCharacterId: 'deleted-character',
              kind: MemoryKind.fact,
              content: '删除角色后仍可审计',
              status: MemoryStatus.active,
              originType: MemoryOriginType.group,
              originNameSnapshot: '群组',
            ));
        await tester.pumpWidget(app(const MemoryManagementPage()));
      });
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('已删除角色'), findsOneWidget);
      expect(find.text('删除角色后仍可审计'), findsOneWidget);
    });

    testWidgets('deleted observer and subject use identity snapshots',
        (tester) async {
      await tester.runAsync(() async {
        await db.appSettingsBox.put(
          DataLifecycleSettings.deletedCharacterSnapshotsKey,
          {
            'deleted-observer': {
              'name': '快照观察者',
              'avatar': '观',
              'age': 27,
              'role': '观察者',
            },
            'deleted-subject': {
              'name': '快照主体',
              'avatar': '主',
              'age': 28,
              'role': '主体',
            },
          },
        );
        await db.permanentMemoryBox.put(
          'pm-snapshot',
          PermanentMemory(
            observerCharacterId: 'deleted-observer',
            kind: MemoryKind.sharedExperience,
            content: '历史快照可审计',
            subjectIds: const ['deleted-subject'],
            status: MemoryStatus.active,
            originType: MemoryOriginType.group,
            originNameSnapshot: '快照群',
          ),
        );
        await tester.pumpWidget(app(const MemoryManagementPage()));
      });
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('快照观察者'), findsWidgets);
      expect(find.text('主体：快照主体'), findsOneWidget);
      expect(find.text('已删除角色'), findsNothing);
    });

    testWidgets('originConversationId sets initial filter only',
        (tester) async {
      await tester.runAsync(() async {
        final char = testCharacter('char-a', apiConfigId: 'cfg');
        await db.aiCharacterBox.put(char.id, char);
        await db.permanentMemoryBox.put(
            'pm-g1',
            PermanentMemory(
              observerCharacterId: 'char-a',
              kind: MemoryKind.fact,
              content: '群1记忆',
              status: MemoryStatus.active,
              originType: MemoryOriginType.group,
              originNameSnapshot: '群1',
              originConversationId: 'group-1',
            ));
        await db.permanentMemoryBox.put(
            'pm-g2',
            PermanentMemory(
              observerCharacterId: 'char-a',
              kind: MemoryKind.fact,
              content: '群2记忆',
              status: MemoryStatus.active,
              originType: MemoryOriginType.group,
              originNameSnapshot: '群2',
              originConversationId: 'group-2',
            ));
        await tester.pumpWidget(app(
          const MemoryManagementPage(conversationId: 'group-1'),
        ));
      });
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('群1记忆'), findsOneWidget);
      expect(find.text('群2记忆'), findsNothing);

      await tester.tap(find.text('清除筛选'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('群2记忆'), findsOneWidget);
    });
  });

  group('MemoryControls operations', () {
    testWidgets('editPermanent creates new manual record and supersedes old',
        (tester) async {
      await tester.runAsync(() async {
        final char = testCharacter('char-a', apiConfigId: 'cfg');
        await db.aiCharacterBox.put(char.id, char);
        final old = PermanentMemory(
          observerCharacterId: 'char-a',
          kind: MemoryKind.fact,
          content: '用户喜欢吃苹果',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: '群1',
          subjectIds: const ['user'],
        );
        await db.permanentMemoryBox.put(old.id, old);
        final controls = MemoryControls(db);
        await controls.editPermanent(
          old,
          correctedContent: '用户喜欢吃苹果和香蕉',
          subjectIds: const ['user'],
        );
        await tester.pumpWidget(app(
          const MemoryManagementPage(),
        ));
      });
      await tester.pump(const Duration(milliseconds: 300));

      await scrollTo(tester, find.text('用户喜欢吃苹果和香蕉'));
      expect(find.text('用户喜欢吃苹果和香蕉'), findsOneWidget);
      await scrollTo(tester, find.text('用户喜欢吃苹果'));
      expect(find.text('用户喜欢吃苹果'), findsOneWidget);
      expect(
          db.permanentMemoryBox.values
              .where((m) => m.content == '用户喜欢吃苹果')
              .single
              .status,
          MemoryStatus.superseded);
    });

    testWidgets('deletePermanent removes record', (tester) async {
      await tester.runAsync(() async {
        final char = testCharacter('char-a', apiConfigId: 'cfg');
        await db.aiCharacterBox.put(char.id, char);
        final memory = PermanentMemory(
          observerCharacterId: 'char-a',
          kind: MemoryKind.fact,
          content: '用户住在上海',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: '群1',
        );
        await db.permanentMemoryBox.put(memory.id, memory);
        final controls = MemoryControls(db);
        await controls.deletePermanent(memory);
        await tester.pumpWidget(app(
          const MemoryManagementPage(),
        ));
      });
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('用户住在上海'), findsNothing);
      expect(
          db.permanentMemoryBox.values
              .where((m) => m.content == '用户住在上海')
              .isEmpty,
          isTrue);
    });

    testWidgets('pinPermanent persists pin state', (tester) async {
      await tester.runAsync(() async {
        final char = testCharacter('char-a', apiConfigId: 'cfg');
        await db.aiCharacterBox.put(char.id, char);
        final memory = PermanentMemory(
          observerCharacterId: 'char-a',
          kind: MemoryKind.fact,
          content: '用户喜欢蓝色',
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: '群1',
          pinned: false,
        );
        await db.permanentMemoryBox.put(memory.id, memory);
        final controls = MemoryControls(db);
        await controls.pinPermanent(memory);
        await tester.pumpWidget(app(
          const MemoryManagementPage(),
        ));
      });
      await tester.pump(const Duration(milliseconds: 300));

      expect(
          db.permanentMemoryBox.values
              .where((m) => m.content == '用户喜欢蓝色')
              .single
              .pinned,
          isTrue);
    });
  });

  group('Migration diagnostic', () {
    testWidgets('shows diagnostic when legacy character data exists',
        (tester) async {
      await tester.runAsync(() async {
        final char = testCharacter('char-a', apiConfigId: 'cfg')
          ..memorySummary = '【事实】旧事实';
        await db.aiCharacterBox.put(char.id, char);
        await db.characterMemoryBox.put(
            'cm1',
            CharacterMemory(
              id: 'cm1',
              groupId: 'group-1',
              characterId: char.id,
              facts: ['旧事实'],
            ));
        await tester.pumpWidget(app(
          const MemoryManagementPage(conversationId: 'group-1'),
        ));
      });
      await tester.pump(const Duration(milliseconds: 500));
      await tester.scrollUntilVisible(
        find.text('迁移诊断'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('【事实】旧事实'), findsOneWidget);
      expect(find.text('旧事实'), findsOneWidget);
      expect(find.text('迁移诊断'), findsOneWidget);
    });

    testWidgets('migration diagnostic shows character memory content',
        (tester) async {
      await tester.runAsync(() async {
        final char = testCharacter('char-a', apiConfigId: 'cfg');
        char.memorySummary = '【事实】旧跨会话事实';
        await db.aiCharacterBox.put(char.id, char);
        final cm = CharacterMemory(
          id: 'cm1',
          groupId: 'group-1',
          characterId: char.id,
          facts: ['会话事实1'],
          personaGrowth: ['成长记录'],
        );
        await db.characterMemoryBox.put(cm.id, cm);

        await tester.pumpWidget(app(
          const MemoryManagementPage(conversationId: 'group-1'),
        ));
      });
      await tester.pump(const Duration(milliseconds: 500));
      await tester.scrollUntilVisible(
        find.text('迁移诊断'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('【事实】旧跨会话事实'), findsOneWidget);
      expect(find.text('会话事实1'), findsOneWidget);
      expect(find.text('成长记录'), findsOneWidget);
    });

    testWidgets('legacy permanent memory records show migration badge',
        (tester) async {
      await tester.runAsync(() async {
        final char = testCharacter('char-a', apiConfigId: 'cfg');
        await db.aiCharacterBox.put(char.id, char);
        await db.permanentMemoryBox.put(
            'legacy-1',
            PermanentMemory(
              observerCharacterId: 'char-a',
              kind: MemoryKind.fact,
              content: '旧版迁移',
              status: MemoryStatus.active,
              originType: MemoryOriginType.legacyMigration,
              originNameSnapshot: '旧数据',
              sourceMessageIds: const [],
            ));
        await tester.pumpWidget(app(
          const MemoryManagementPage(),
        ));
      });
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.text('旧版迁移记录，无原始消息证据'), findsOneWidget);
    });
  });

  group('Source traceability', () {
    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('flutter_tts'),
        (call) async {
          switch (call.method) {
            case 'awaitSpeakCompletion':
            case 'speak':
            case 'stop':
              return 1;
            case 'getLanguages':
              return <String>['zh-CN'];
            case 'setLanguage':
            case 'setPitch':
            case 'setSpeechRate':
            case 'setVolume':
              return 1;
            case 'isLanguageAvailable':
              return true;
            default:
              return null;
          }
        },
      );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('flutter_tts'),
        null,
      );
    });

    testWidgets('existing source messages show clickable "查看原消息" button',
        (tester) async {
      await tester.runAsync(() async {
        final char = testCharacter('char-a', apiConfigId: 'cfg');
        await db.aiCharacterBox.put(char.id, char);
        await db.chatGroupBox.put(
            'g1',
            ChatGroup(
              id: 'g1',
              name: '测试群',
              theme: '测试',
              aiCharacterIds: [char.id],
              createdAt: DateTime.now(),
            ));
        final msg = Message(
          id: 'msg-1',
          groupId: 'g-real',
          senderId: 'user',
          senderType: 'user',
          content: '原消息内容',
          timestamp: DateTime.now(),
        );
        await db.messageBox.put('msg-1', msg);
        await db.permanentMemoryBox.put(
            'pm-1',
            PermanentMemory(
              observerCharacterId: 'char-a',
              kind: MemoryKind.fact,
              content: '记忆内容',
              status: MemoryStatus.active,
              originType: MemoryOriginType.group,
              originNameSnapshot: '测试群',
              sourceMessageIds: const ['msg-1'],
              originConversationId: 'g-wrong',
            ));
        await tester.pumpWidget(app(const MemoryManagementPage()));
      });
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('查看原消息'), findsOneWidget);
    });

    testWidgets('missing source messages show a disabled trace action',
        (tester) async {
      await tester.runAsync(() async {
        await db.permanentMemoryBox.put(
            'pm-missing-source',
            PermanentMemory(
              observerCharacterId: 'char-a',
              kind: MemoryKind.fact,
              content: '没有来源消息',
              status: MemoryStatus.active,
              originType: MemoryOriginType.group,
              originNameSnapshot: '已删除群组',
              sourceMessageIds: const ['missing-message'],
            ));
        await tester.pumpWidget(app(const MemoryManagementPage()));
      });
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.textContaining('原消息已不可用'), findsOneWidget);
      expect(
        tester
            .widget<ButtonStyleButton>(
              find.ancestor(
                of: find.byIcon(Icons.link_off_rounded),
                matching: find.bySubtype<ButtonStyleButton>(),
              ),
            )
            .onPressed,
        isNull,
      );
    });

    testWidgets('clicking "查看原消息" uses sourceMessage.groupId to navigate',
        (tester) async {
      await tester.runAsync(() async {
        final char = testCharacter('char-a', apiConfigId: 'cfg');
        await db.aiCharacterBox.put(char.id, char);
        await db.chatGroupBox.put(
            'g-real',
            ChatGroup(
              id: 'g-real',
              name: '真实群',
              theme: '测试',
              aiCharacterIds: [char.id],
              createdAt: DateTime.now(),
            ));
        final msg = Message(
          id: 'msg-1',
          groupId: 'g-real',
          senderId: 'user',
          senderType: 'user',
          content: '原消息内容',
          timestamp: DateTime.now(),
        );
        await db.messageBox.put('msg-1', msg);
        await db.permanentMemoryBox.put(
            'pm-1',
            PermanentMemory(
              observerCharacterId: 'char-a',
              kind: MemoryKind.fact,
              content: '记忆内容',
              status: MemoryStatus.active,
              originType: MemoryOriginType.group,
              originNameSnapshot: '测试群',
              sourceMessageIds: const ['msg-1'],
              originConversationId: 'g-wrong',
            ));

        await tester.pumpWidget(
          ProviderScope(
            overrides: [databaseServiceProvider.overrideWithValue(db)],
            child: const MaterialApp(
              home: MemoryManagementPage(),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));

        await tester.tap(find.text('查看原消息'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        // Verify ChatRoomPage is pushed with the source message's groupId.
        final chatRoom =
            find.byType(ChatRoomPage).evaluate().first.widget as ChatRoomPage;
        expect(chatRoom.groupId, 'g-real');
        expect(chatRoom.initialMessageId, 'msg-1');

        // Verify the source message's groupId in DB — this is what
        // _SourceTraceButton reads to build ChatRoomPage(groupId: source.groupId).
        final sourceMessage = db.messageBox.get('msg-1')!;
        expect(sourceMessage.groupId, 'g-real');
        expect(sourceMessage.id, 'msg-1');

        // originConversationId is 'g-wrong' — proves the button uses
        // sourceMessage.groupId, NOT originConversationId.
        final pm = db.permanentMemoryBox.get('pm-1')!;
        expect(pm.originConversationId, 'g-wrong');

        // Pop the pushed ChatRoomPage to clean up.
        final ctx = tester.element(find.byType(MemoryManagementPage));
        if (Navigator.of(ctx).canPop()) {
          Navigator.of(ctx).pop();
        }
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pump(const Duration(milliseconds: 350));
        expect(find.byType(ChatRoomPage), findsNothing);

        await Future.delayed(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 300));
      });
    });

    testWidgets('legacy migration records can use the correction flow',
        (tester) async {
      await tester.runAsync(() async {
        final char = testCharacter('char-a', apiConfigId: 'cfg');
        await db.aiCharacterBox.put(char.id, char);
        await db.permanentMemoryBox.put(
            'pm-legacy-edit',
            PermanentMemory(
              observerCharacterId: char.id,
              kind: MemoryKind.fact,
              content: '遗留错误内容',
              status: MemoryStatus.active,
              originType: MemoryOriginType.legacyMigration,
              originNameSnapshot: '旧版迁移',
            ));
        await tester.pumpWidget(app(const MemoryManagementPage()));
      });
      await tester.pump(const Duration(milliseconds: 300));

      await scrollTo(tester, find.text('遗留错误内容'));
      await tester.longPress(find.text('遗留错误内容'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.widgetWithText(ListTile, '修正'));
      await tester.pump(const Duration(milliseconds: 300));
      final correctionDialog = find.byType(AlertDialog);
      await tester.enterText(
        find
            .descendant(
              of: correctionDialog,
              matching: find.byType(TextField),
            )
            .first,
        '修正后的内容',
      );
      await tester.tap(find.text('保存修正'));
      await tester.pump();
      await settleHiveWrites(tester);
      await tester.runAsync(() => db.permanentMemoryBox.flush());
      await tester.pump();

      expect(
        db.permanentMemoryBox.values.any(
          (memory) =>
              memory.content == '修正后的内容' &&
              memory.originType == MemoryOriginType.manual,
        ),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });

    testWidgets('pin and delete actions update the visible audit record',
        (tester) async {
      await tester.runAsync(() async {
        final char = testCharacter('char-a', apiConfigId: 'cfg');
        await db.aiCharacterBox.put(char.id, char);
        await db.permanentMemoryBox.put(
            'pm-actions',
            PermanentMemory(
              observerCharacterId: char.id,
              kind: MemoryKind.fact,
              content: '待处理记忆',
              status: MemoryStatus.active,
              originType: MemoryOriginType.manual,
              originNameSnapshot: '手动',
            ));
        await tester.pumpWidget(app(const MemoryManagementPage()));
      });
      await tester.pump(const Duration(milliseconds: 300));

      await scrollTo(tester, find.text('待处理记忆'));
      await tester.tap(find.byTooltip('固定'));
      await tester.pump();
      await settleHiveWrites(tester, turns: 1);
      await tester.runAsync(() async {
        await db.permanentMemoryBox.flush();
        await db.appSettingsBox.flush();
      });
      await tester.pump();
      expect(db.permanentMemoryBox.get('pm-actions')!.pinned, isTrue);

      await scrollTo(tester, find.text('待处理记忆'));
      await tester.longPress(find.text('待处理记忆'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.widgetWithText(ListTile, '删除'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pump();
      await settleHiveWrites(tester, turns: 1);
      await tester.runAsync(() => db.permanentMemoryBox.flush());
      await tester.pump();

      expect(db.permanentMemoryBox.get('pm-actions'), isNull);
    });

    testWidgets('shows an error state when the memory box cannot be read',
        (tester) async {
      await tester.runAsync(() => db.permanentMemoryBox.close());
      try {
        await tester.pumpWidget(app(const MemoryManagementPage()));
        await tester.pump();

        expect(find.text('永久记忆加载失败'), findsOneWidget);
      } finally {
        await tester.runAsync(
          () => Hive.openBox<PermanentMemory>('permanent_memories'),
        );
      }
    });
  });
}

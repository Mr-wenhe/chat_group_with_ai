import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/database/data_lifecycle_settings.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/character_memory.dart';
import 'package:chat_group/core/models/permanent_memory.dart';
import 'package:chat_group/features/memory/memory_audit_filter.dart';
import 'package:chat_group/features/memory/memory_controls.dart';
import 'package:chat_group/features/memory/memory_management_page.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:flutter/material.dart';
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
    await db.characterMemoryBox.clear();
    await db.chatGroupBox.clear();
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

  void useViewport(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> pumpLoaded(WidgetTester tester, Widget page) async {
    await tester.pumpWidget(app(page));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> putCharacter(AICharacter character) async {
    await TestWidgetsFlutterBinding.ensureInitialized().runAsync(
      () => db.aiCharacterBox.put(character.id, character),
    );
  }

  Future<void> putMemory(PermanentMemory memory) async {
    await TestWidgetsFlutterBinding.ensureInitialized().runAsync(
      () => db.permanentMemoryBox.put(memory.id, memory),
    );
  }

  group('Global memory rendering', () {
    testWidgets('shows a loading state before reading the audit snapshot',
        (tester) async {
      await tester.pumpWidget(app(const MemoryManagementPage(
        scope: MemoryConversationScope.settings(),
      )));

      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await tester.pump();
    });

    testWidgets('memory page always exposes a safe back affordance',
        (tester) async {
      await pumpLoaded(
          tester,
          const MemoryManagementPage(
            scope: MemoryConversationScope.settings(),
          ));

      expect(find.byType(BackButton), findsOneWidget);
    });

    testWidgets('memory page back button pops its independent route',
        (tester) async {
      await tester.pumpWidget(app(
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const MemoryManagementPage(
                    scope: MemoryConversationScope.settings(),
                  ),
                ),
              ),
              child: const Text('打开记忆页面'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('打开记忆页面'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.byType(BackButton));
      await tester.pump();

      expect(find.text('打开记忆页面'), findsOneWidget);
    });

    testWidgets(
        'page reads all permanent memories globally, not by conversation',
        (tester) async {
      useViewport(tester, const Size(1200, 800));
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
          const MemoryManagementPage(
            scope: MemoryConversationScope.settings(),
          ),
        ));
      });
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('A在上海'), findsOneWidget);
      expect(find.text('B在北京'), findsOneWidget);
    });

    testWidgets('deleted observer character is rendered as a placeholder',
        (tester) async {
      useViewport(tester, const Size(1200, 800));
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
        await tester.pumpWidget(app(const MemoryManagementPage(
          scope: MemoryConversationScope.settings(),
        )));
      });
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('已删除角色'), findsOneWidget);
      expect(find.text('删除角色后仍可审计'), findsOneWidget);
    });

    testWidgets('deleted observer and subject use identity snapshots',
        (tester) async {
      useViewport(tester, const Size(1200, 800));
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
        await tester.pumpWidget(app(const MemoryManagementPage(
          scope: MemoryConversationScope.settings(),
        )));
      });
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('快照观察者'), findsWidgets);
      expect(find.textContaining('快照主体', findRichText: true), findsWidgets);
      expect(find.text('已删除角色'), findsNothing);
      expect(
        find.byKey(const ValueKey('memory-observer-deleted-observer')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('memory-observer-deleted-subject')),
        findsNothing,
      );
    });

    testWidgets('originConversationId starts as a clearable filter',
        (tester) async {
      useViewport(tester, const Size(1200, 800));
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
          const MemoryManagementPage(
            conversationId: 'group-1',
            scope: MemoryConversationScope.settings(),
          ),
        ));
      });
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('群1记忆'), findsOneWidget);
      expect(find.text('群2记忆'), findsNothing);
      expect(find.byKey(const ValueKey('clear-memory-filter')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('clear-memory-filter')));
      await tester.pump();
      expect(find.text('群1记忆'), findsOneWidget);
      expect(find.text('群2记忆'), findsOneWidget);
    });

    testWidgets('memory search uses friendly observer name projection',
        (tester) async {
      useViewport(tester, const Size(1200, 800));
      await tester.runAsync(() async {
        final character = testCharacter('char-search', apiConfigId: 'cfg');
        character.name = 'Amy';
        await db.aiCharacterBox.put(character.id, character);
        await db.permanentMemoryBox.put(
          'pm-search',
          PermanentMemory(
            observerCharacterId: character.id,
            kind: MemoryKind.fact,
            content: '咖啡偏好',
            status: MemoryStatus.active,
            originType: MemoryOriginType.manual,
            originNameSnapshot: '手动记录',
          ),
        );
        await tester.pumpWidget(app(const MemoryManagementPage(
          scope: MemoryConversationScope.settings(),
        )));
      });
      await tester.pump(const Duration(milliseconds: 300));

      final search = find.byKey(const ValueKey('memory-audit-search'));
      await tester.enterText(search, 'Amy');
      await tester.pump();
      expect(find.text('咖啡偏好'), findsOneWidget);

      await tester.enterText(search, '不存在的内容');
      await tester.pump();
      expect(find.text('咖啡偏好'), findsNothing);
    });

    testWidgets('memory list uses friendly deleted-source projection',
        (tester) async {
      useViewport(tester, const Size(1200, 800));
      await tester.runAsync(() async {
        await db.permanentMemoryBox.put(
          'pm-deleted-source',
          PermanentMemory(
            observerCharacterId: 'deleted-character',
            kind: MemoryKind.fact,
            content: '删除场合后仍可读',
            status: MemoryStatus.active,
            originType: MemoryOriginType.group,
            originConversationId: 'deleted-group',
            originNameSnapshot: 'deleted-group',
          ),
        );
        await tester.pumpWidget(app(const MemoryManagementPage(
          scope: MemoryConversationScope.settings(),
        )));
      });
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        find.textContaining('已删除群聊', findRichText: true),
        findsOneWidget,
      );
      expect(find.text('deleted-group'), findsNothing);
    });
  });

  group('MemoryControls operations', () {
    testWidgets('editPermanent creates new manual record and supersedes old',
        (tester) async {
      useViewport(tester, const Size(1200, 800));
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
          const MemoryManagementPage(
            scope: MemoryConversationScope.settings(),
          ),
        ));
      });
      await tester.pump(const Duration(milliseconds: 300));

      await scrollTo(tester, find.text('用户喜欢吃苹果和香蕉'));
      expect(find.text('用户喜欢吃苹果和香蕉'), findsOneWidget);
      await tester.tap(find.text('历史记录（1）'));
      await tester.pump();
      expect(find.text('用户喜欢吃苹果'), findsOneWidget);
      expect(
          db.permanentMemoryBox.values
              .where((m) => m.content == '用户喜欢吃苹果')
              .single
              .status,
          MemoryStatus.superseded);
    });

    testWidgets('deletePermanent removes record', (tester) async {
      useViewport(tester, const Size(1200, 800));
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
          const MemoryManagementPage(
            scope: MemoryConversationScope.settings(),
          ),
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
      useViewport(tester, const Size(1200, 800));
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
          const MemoryManagementPage(
            scope: MemoryConversationScope.settings(),
          ),
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

  testWidgets('wide layout has a 280px observer sidebar and content surface',
      (tester) async {
    useViewport(tester, const Size(1200, 800));
    final alice = testCharacter(
      'alice',
      apiConfigId: 'cfg',
      gender: CharacterGender.female,
    )
      ..name = 'Alice'
      ..role = '数据科学家';
    await putCharacter(alice);
    await putMemory(
      PermanentMemory(
        id: 'active-memory',
        observerCharacterId: alice.id,
        kind: MemoryKind.preference,
        content: '喜欢手冲咖啡',
        subjectIds: const ['user'],
        status: MemoryStatus.active,
        originType: MemoryOriginType.manual,
        originNameSnapshot: '手动记录',
        importance: 99,
        confidence: .99,
        sourceMessageIds: const ['source-message-id'],
        participantIds: const ['participant-id'],
      ),
    );
    await putMemory(
      PermanentMemory(
        id: 'history-memory',
        observerCharacterId: alice.id,
        kind: MemoryKind.fact,
        content: '历史内容',
        status: MemoryStatus.superseded,
        originType: MemoryOriginType.group,
        originNameSnapshot: '测试群',
      ),
    );

    await pumpLoaded(
        tester,
        const MemoryManagementPage(
          scope: MemoryConversationScope.settings(),
        ));

    expect(
        find.byKey(const ValueKey('memory-observer-sidebar')), findsOneWidget);
    expect(
      tester
          .getSize(find.byKey(const ValueKey('memory-observer-sidebar')))
          .width,
      280,
    );
    expect(find.byKey(const ValueKey('memory-content')), findsOneWidget);
    expect(find.byKey(const ValueKey('memory-title-actions')), findsOneWidget);
    expect(find.text('筛选'), findsOneWidget);
    expect(find.byKey(const ValueKey('memory-observer-avatar-alice')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('memory-row-observer-avatar')),
        findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('memory-observer-alice')));
    await tester.pump();
    expect(
        find.byKey(const ValueKey('memory-row-observer-avatar')), findsNothing);
    expect(find.text('全部 AI'), findsOneWidget);
    expect(find.text('Alice'), findsWidgets);
    expect(find.textContaining('数据科学家'), findsWidgets);
    expect(find.text('喜欢手冲咖啡'), findsOneWidget);
    expect(find.text('历史记录（1）'), findsOneWidget);
    expect(find.text('历史内容'), findsNothing);
    expect(find.byType(Card), findsNothing);
    expect(find.textContaining('重要度'), findsNothing);
    expect(find.textContaining('置信'), findsNothing);
    expect(find.text('source-message-id'), findsNothing);
    expect(find.text('participant-id'), findsNothing);
    await tester.tap(find.text('历史记录（1）'));
    await tester.pump();
    expect(find.text('历史内容'), findsOneWidget);
  });

  testWidgets('narrow layout provides a searchable selector without overflow',
      (tester) async {
    useViewport(tester, const Size(360, 800));
    final alice = testCharacter(
      'alice',
      apiConfigId: 'cfg',
      gender: CharacterGender.female,
    )
      ..name = 'Alice'
      ..role = '数据科学家';
    await putCharacter(alice);

    await pumpLoaded(
        tester,
        const MemoryManagementPage(
          scope: MemoryConversationScope.settings(),
        ));

    expect(
        find.byKey(const ValueKey('memory-observer-selector')), findsOneWidget);
    expect(find.byKey(const ValueKey('memory-observer-sidebar')), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.enterText(
      find.byKey(const ValueKey('memory-observer-search')),
      '数据科学家',
    );
    await tester.pump();
    expect(find.text('Alice'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('observer navigation searches by name, gender, and occupation',
      (tester) async {
    useViewport(tester, const Size(1200, 800));
    final alice = testCharacter(
      'alice',
      apiConfigId: 'cfg',
      gender: CharacterGender.female,
    )
      ..name = 'Alice'
      ..role = '数据科学家';
    final bob = testCharacter(
      'bob',
      apiConfigId: 'cfg',
      gender: CharacterGender.male,
    )
      ..name = 'Bob'
      ..role = '建筑师';
    await putCharacter(alice);
    await putCharacter(bob);

    await pumpLoaded(
        tester,
        const MemoryManagementPage(
          scope: MemoryConversationScope.settings(),
        ));
    final search = find.byKey(const ValueKey('memory-observer-search'));

    await tester.enterText(search, '女');
    await tester.pump();
    expect(find.byKey(const ValueKey('memory-observer-alice')), findsOneWidget);
    expect(find.byKey(const ValueKey('memory-observer-bob')), findsNothing);

    await tester.enterText(search, '建筑师');
    await tester.pump();
    expect(find.byKey(const ValueKey('memory-observer-bob')), findsOneWidget);
    expect(find.byKey(const ValueKey('memory-observer-alice')), findsNothing);

    await tester.enterText(search, '不存在的观察 AI');
    await tester.pump();
    expect(find.text('没有匹配的观察 AI'), findsOneWidget);
    expect(find.byKey(const ValueKey('memory-observer-all')), findsOneWidget);
    await tester.tap(find.text('清除搜索'));
    await tester.pump();
    final searchField = tester.widget<TextField>(search);
    expect(searchField.controller, isNotNull);
    expect(searchField.controller!.text, isEmpty);
    expect(find.byKey(const ValueKey('memory-observer-alice')), findsOneWidget);
  });

  testWidgets('memory object navigation searches and selects other characters',
      (tester) async {
    useViewport(tester, const Size(1200, 800));
    final alice = testCharacter('alice', apiConfigId: 'cfg')..name = 'Alice';
    final bob = testCharacter('bob', apiConfigId: 'cfg')
      ..name = 'Bob'
      ..role = '建筑师';
    await putCharacter(alice);
    await putCharacter(bob);
    await putMemory(
      PermanentMemory(
        id: 'subject-bob-memory',
        observerCharacterId: alice.id,
        kind: MemoryKind.fact,
        content: 'Bob负责建筑设计',
        subjectIds: [bob.id],
        status: MemoryStatus.active,
        originType: MemoryOriginType.manual,
        originNameSnapshot: '手动记录',
      ),
    );

    await pumpLoaded(
        tester,
        const MemoryManagementPage(
          scope: MemoryConversationScope.settings(),
        ));
    expect(find.byKey(const ValueKey('memory-subject-quick-about-me')),
        findsOneWidget);
    expect(
        find.byKey(const ValueKey('memory-subject-quick-all')), findsOneWidget);
    expect(find.byKey(const ValueKey('memory-subject-quick-other')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('memory-subject-quick-self-growth')),
        findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('memory-subject-quick-other')),
    );
    await tester.pump();
    ChoiceChip otherChip = tester.widget(
      find.byKey(const ValueKey('memory-subject-quick-other')),
    );
    expect(otherChip.selected, isTrue);
    final subjectSearch = find.byKey(const ValueKey('memory-subject-search'));
    await tester.enterText(subjectSearch, '暂不选择');
    await tester.pump();
    await tester.enterText(subjectSearch, '');
    await tester.pump();
    otherChip = tester.widget(
      find.byKey(const ValueKey('memory-subject-quick-other')),
    );
    expect(otherChip.selected, isTrue);
    await tester.enterText(subjectSearch, '建筑师');
    await tester.pumpAndSettle();
    expect(find.text('Bob'), findsWidgets);
    await tester.tap(find.text('Bob').last);
    await tester.pump();

    expect(find.text('Bob负责建筑设计'), findsOneWidget);
    otherChip = tester.widget(
      find.byKey(const ValueKey('memory-subject-quick-other')),
    );
    expect(otherChip.selected, isTrue);
  });

  testWidgets('settings memory object search includes the current observer',
      (tester) async {
    useViewport(tester, const Size(1200, 800));
    final alice = testCharacter('alice', apiConfigId: 'cfg')..name = 'Alice';
    final bob = testCharacter('bob', apiConfigId: 'cfg')..name = 'Bob';
    await putCharacter(alice);
    await putCharacter(bob);
    await putMemory(
      PermanentMemory(
        id: 'observer-memory',
        observerCharacterId: alice.id,
        kind: MemoryKind.fact,
        content: '观察者自己的记录',
        status: MemoryStatus.active,
        originType: MemoryOriginType.manual,
        originNameSnapshot: '手动记录',
      ),
    );

    await pumpLoaded(
        tester,
        const MemoryManagementPage(
          scope: MemoryConversationScope.settings(),
        ));
    await tester.tap(find.byKey(const ValueKey('memory-observer-alice')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('memory-subject-quick-other')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('memory-subject-search')),
      'Alice',
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('memory-subject-option-alice')),
      findsOneWidget,
    );
  });

  testWidgets('advanced filter count excludes navigation and search context',
      (tester) async {
    useViewport(tester, const Size(1200, 800));
    final alice = testCharacter('alice', apiConfigId: 'cfg')..name = 'Alice';
    await putCharacter(alice);
    await putMemory(
      PermanentMemory(
        id: 'context-memory',
        observerCharacterId: alice.id,
        kind: MemoryKind.fact,
        content: '上下文搜索内容',
        status: MemoryStatus.active,
        originType: MemoryOriginType.manual,
        originNameSnapshot: '手动记录',
      ),
    );

    await pumpLoaded(
        tester,
        const MemoryManagementPage(
          scope: MemoryConversationScope.settings(),
        ));
    await tester.tap(find.byKey(const ValueKey('memory-observer-alice')));
    await tester.enterText(
      find.byKey(const ValueKey('memory-audit-search')),
      '上下文',
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('memory-filter-active-summary')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('memory-filter-advanced-badge')),
        findsOneWidget);
  });

  testWidgets('clearing advanced filters preserves observer and search context',
      (tester) async {
    useViewport(tester, const Size(1200, 800));
    final alice = testCharacter('alice', apiConfigId: 'cfg')..name = 'Alice';
    await putCharacter(alice);
    await putMemory(
      PermanentMemory(
        id: 'clear-context-memory',
        observerCharacterId: alice.id,
        kind: MemoryKind.fact,
        content: '上下文保留',
        status: MemoryStatus.active,
        originType: MemoryOriginType.manual,
        originNameSnapshot: '手动记录',
      ),
    );

    await pumpLoaded(
        tester,
        const MemoryManagementPage(
          scope: MemoryConversationScope.settings(),
        ));
    await tester.tap(find.byKey(const ValueKey('memory-observer-alice')));
    final search = find.byKey(const ValueKey('memory-audit-search'));
    await tester.enterText(search, '上下文');
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('open-advanced-memory-filter')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('memory-filter-dialog-status')),
    );
    await tester.tap(find.byKey(const ValueKey('memory-filter-dialog-status')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('已取代').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('应用筛选'));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<Badge>(
            find.byKey(const ValueKey('memory-filter-advanced-badge')),
          )
          .isLabelVisible,
      isTrue,
    );
    await tester.tap(find.byKey(const ValueKey('clear-memory-filter')));
    await tester.pump();

    expect(find.text('Alice 的永久记忆'), findsOneWidget);
    expect(tester.widget<TextField>(search).controller!.text, '上下文');
    expect(find.text('上下文保留'), findsOneWidget);
    expect(
      tester
          .widget<Badge>(
            find.byKey(const ValueKey('memory-filter-advanced-badge')),
          )
          .isLabelVisible,
      isFalse,
    );
  });

  testWidgets('100 observers and 1000 memories stay lazy and filter in memory',
      (tester) async {
    useViewport(tester, const Size(1200, 800));
    final characters = [
      for (var index = 0; index < 100; index++)
        testCharacter('observer-$index', apiConfigId: 'cfg')
          ..name = '观察者 $index',
    ];
    for (final character in characters) {
      await putCharacter(character);
    }
    final memories = [
      for (var index = 0; index < 1000; index++)
        PermanentMemory(
          id: 'history-lazy-$index',
          observerCharacterId: characters.first.id,
          kind: MemoryKind.fact,
          content: '历史惰性 $index',
          status: MemoryStatus.superseded,
          originType: MemoryOriginType.manual,
          originNameSnapshot: '手动记录',
          occurredAt: DateTime(2024, 1, 1).add(Duration(minutes: index)),
          updatedAt: DateTime(2024, 1, 1).add(Duration(minutes: index)),
        ),
    ];
    await TestWidgetsFlutterBinding.ensureInitialized().runAsync(
      () => db.permanentMemoryBox.putAll({
        for (final memory in memories) memory.id: memory,
      }),
    );

    await pumpLoaded(
        tester,
        const MemoryManagementPage(
          scope: MemoryConversationScope.settings(),
        ));
    expect(find.byKey(const ValueKey('memory-observer-observer-99')),
        findsNothing);
    expect(find.text('历史记录（1000）'), findsOneWidget);
    await tester.tap(find.text('历史记录（1000）'));
    await tester.pump();
    expect(
        find.byKey(const ValueKey('memory-row-history-lazy-0')), findsNothing);

    final search = find.byKey(const ValueKey('memory-audit-search'));
    await tester.enterText(search, '历史惰性 999');
    await tester.pump();
    expect(
      find.byKey(const ValueKey('memory-row-history-lazy-999')),
      findsOneWidget,
    );
    expect(find.text('历史惰性 0'), findsNothing);
    await tester.enterText(search, '');
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('open-advanced-memory-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('memory-filter-dialog-status')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('有效').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('应用筛选'));
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('没有符合筛选条件的记忆'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('clear-memory-filter-empty')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('memory-row-history-lazy-999')),
      findsOneWidget,
    );
  });

  testWidgets('responsive boundary and long content stay usable',
      (tester) async {
    final alice = testCharacter('alice', apiConfigId: 'cfg')
      ..name = '这是一个非常非常长的观察 AI 名称'
      ..role = '这是一个非常非常长的职业名称，用于验证窄屏布局不会重叠';
    await putCharacter(alice);
    await putMemory(
      PermanentMemory(
        id: 'responsive-memory',
        observerCharacterId: alice.id,
        kind: MemoryKind.fact,
        content: '这是一个很长很长的记忆摘要，用于验证 320px 宽度下仍然可以换行并通过详情入口继续浏览。',
        status: MemoryStatus.active,
        originType: MemoryOriginType.manual,
        originNameSnapshot: '一个很长的来源场合名称',
      ),
    );

    useViewport(tester, const Size(320, 800));
    await pumpLoaded(
        tester,
        const MemoryManagementPage(
          scope: MemoryConversationScope.settings(),
        ));
    expect(find.byKey(const ValueKey('memory-observer-sidebar')), findsNothing);
    expect(find.textContaining('很长很长的记忆摘要'), findsOneWidget);
    expect(tester.takeException(), isNull);

    useViewport(tester, const Size(600, 800));
    await tester.pump();
    expect(find.byKey(const ValueKey('memory-observer-sidebar')), findsNothing);
    expect(tester.takeException(), isNull);

    useViewport(tester, const Size(899, 800));
    await tester.pump();
    expect(find.byKey(const ValueKey('memory-observer-sidebar')), findsNothing);
    expect(tester.takeException(), isNull);

    useViewport(tester, const Size(900, 800));
    await tester.pump();
    expect(
        find.byKey(const ValueKey('memory-observer-sidebar')), findsOneWidget);
    expect(tester.takeException(), isNull);

    useViewport(tester, const Size(1440, 800));
    await tester.pump();
    expect(
        find.byKey(const ValueKey('memory-observer-sidebar')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('large text scale keeps memory controls usable', (tester) async {
    useViewport(tester, const Size(320, 800));
    tester.platformDispatcher.textScaleFactorTestValue = 1.8;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final alice = testCharacter('alice', apiConfigId: 'cfg')..name = 'Alice';
    await putCharacter(alice);
    await putMemory(
      PermanentMemory(
        id: 'text-scale-memory',
        observerCharacterId: alice.id,
        kind: MemoryKind.fact,
        content: '大字体下仍然可读的记忆摘要',
        status: MemoryStatus.active,
        originType: MemoryOriginType.manual,
        originNameSnapshot: '手动记录',
      ),
    );

    await pumpLoaded(
        tester,
        const MemoryManagementPage(
          scope: MemoryConversationScope.settings(),
        ));
    expect(
        find.byKey(const ValueKey('memory-observer-selector')), findsOneWidget);
    expect(find.byKey(const ValueKey('memory-subject-search')), findsNothing);
    await tester.drag(
      find.byKey(const ValueKey('memory-content')),
      const Offset(0, -600),
    );
    await tester.pump();
    expect(find.text('大字体下仍然可读的记忆摘要'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('long memory lists build rows lazily', (tester) async {
    useViewport(tester, const Size(1200, 800));
    final alice = testCharacter('alice', apiConfigId: 'cfg')..name = 'Alice';
    await putCharacter(alice);
    final memories = [
      for (var index = 0; index < 120; index++)
        PermanentMemory(
          id: 'lazy-memory-$index',
          observerCharacterId: alice.id,
          kind: MemoryKind.fact,
          content: '惰性记忆 $index',
          status: MemoryStatus.active,
          originType: MemoryOriginType.manual,
          originNameSnapshot: '手动记录',
          occurredAt: DateTime(2024, 1, 1).add(Duration(minutes: index)),
          updatedAt: DateTime(2024, 1, 1).add(Duration(minutes: index)),
        ),
    ];
    await TestWidgetsFlutterBinding.ensureInitialized().runAsync(
      () => db.permanentMemoryBox.putAll({
        for (final memory in memories) memory.id: memory,
      }),
    );

    await pumpLoaded(
        tester,
        const MemoryManagementPage(
          scope: MemoryConversationScope.settings(),
        ));

    expect(
      find.byKey(const ValueKey('memory-row-lazy-memory-0')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('memory-row-lazy-memory-119')),
      findsOneWidget,
    );
  });

  testWidgets('subject switch and filter count are visible and composable',
      (tester) async {
    useViewport(tester, const Size(1200, 800));
    final alice = testCharacter('alice', apiConfigId: 'cfg')..name = 'Alice';
    await putCharacter(alice);
    await putMemory(
      PermanentMemory(
        id: 'subject-memory',
        observerCharacterId: alice.id,
        kind: MemoryKind.fact,
        content: '用户住在上海',
        subjectIds: const ['user'],
        status: MemoryStatus.active,
        originType: MemoryOriginType.manual,
        originNameSnapshot: '手动记录',
      ),
    );

    await pumpLoaded(
        tester,
        const MemoryManagementPage(
          scope: MemoryConversationScope.settings(),
        ));
    expect(find.text('记忆对象'), findsOneWidget);
    expect(find.text('迁移诊断'), findsOneWidget);
    expect(find.byKey(const ValueKey('open-advanced-memory-filter')),
        findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('memory-subject-quick-about-me')),
    );
    await tester.pump();
    expect(find.text('用户住在上海'), findsOneWidget);
    expect(find.text('1'), findsWidgets);
  });

  testWidgets('empty and no-result states have clear copy and actions',
      (tester) async {
    useViewport(tester, const Size(1200, 800));
    await pumpLoaded(
        tester,
        const MemoryManagementPage(
          scope: MemoryConversationScope.settings(),
        ));

    expect(find.text('暂无可用观察 AI'), findsWidgets);
    expect(find.text('去创建 AI'), findsOneWidget);

    final alice = testCharacter('alice', apiConfigId: 'cfg')..name = 'Alice';
    await putCharacter(alice);
    await putMemory(
      PermanentMemory(
        id: 'search-memory',
        observerCharacterId: alice.id,
        kind: MemoryKind.fact,
        content: '咖啡偏好',
        status: MemoryStatus.active,
        originType: MemoryOriginType.manual,
        originNameSnapshot: '手动记录',
      ),
    );
    await pumpLoaded(
      tester,
      const MemoryManagementPage(
        key: ValueKey('with-memory'),
        scope: MemoryConversationScope.settings(),
      ),
    );

    await tester.enterText(
      find.byKey(const ValueKey('memory-audit-search')),
      '不存在的记忆',
    );
    await tester.pump();
    expect(find.text('没有找到匹配的记忆'), findsOneWidget);
    expect(find.byKey(const ValueKey('clear-memory-search')), findsOneWidget);
  });

  testWidgets('shows a no-memory state when an observer AI exists',
      (tester) async {
    useViewport(tester, const Size(1200, 800));
    await putCharacter(testCharacter('alice', apiConfigId: 'cfg'));

    await pumpLoaded(
        tester,
        const MemoryManagementPage(
          scope: MemoryConversationScope.settings(),
        ));

    expect(find.text('还没有永久记忆'), findsOneWidget);
    expect(find.text('返回设置'), findsOneWidget);
  });

  testWidgets('filter with no results gets a dedicated empty state',
      (tester) async {
    useViewport(tester, const Size(1200, 800));
    final alice = testCharacter('alice', apiConfigId: 'cfg')..name = 'Alice';
    await putCharacter(alice);
    await putMemory(
      PermanentMemory(
        id: 'filter-memory',
        observerCharacterId: alice.id,
        kind: MemoryKind.fact,
        content: '一条记忆',
        status: MemoryStatus.active,
        originType: MemoryOriginType.manual,
        originNameSnapshot: '手动记录',
        originConversationId: 'group-1',
      ),
    );

    await pumpLoaded(
      tester,
      const MemoryManagementPage(
        conversationId: 'missing-group',
        scope: MemoryConversationScope.settings(),
      ),
    );
    expect(find.text('没有符合筛选条件的记忆'), findsOneWidget);
    expect(find.byKey(const ValueKey('clear-memory-filter-empty')),
        findsOneWidget);
  });

  testWidgets('migration diagnostics opens independently from the browser',
      (tester) async {
    useViewport(tester, const Size(1200, 800));
    final alice = testCharacter('alice', apiConfigId: 'cfg')
      ..name = 'Alice'
      ..memorySummary = '【事实】旧版摘要';
    await putCharacter(alice);
    await TestWidgetsFlutterBinding.ensureInitialized().runAsync(
      () => db.characterMemoryBox.put(
        'legacy',
        CharacterMemory(
          id: 'legacy',
          groupId: 'group-1',
          characterId: alice.id,
          facts: const ['旧版正文'],
        ),
      ),
    );
    await putMemory(
      PermanentMemory(
        id: 'detail-memory',
        observerCharacterId: alice.id,
        kind: MemoryKind.fact,
        content: '当前记忆',
        status: MemoryStatus.active,
        originType: MemoryOriginType.manual,
        originNameSnapshot: '手动记录',
      ),
    );

    await pumpLoaded(
        tester,
        const MemoryManagementPage(
          scope: MemoryConversationScope.settings(),
        ));
    expect(find.text('旧版摘要'), findsNothing);
    expect(find.text('旧版正文'), findsNothing);

    await tester.ensureVisible(
      find.byKey(const ValueKey('memory-migration-diagnostic')),
    );
    await tester.tap(find.byKey(const ValueKey('memory-migration-diagnostic')));
    await tester.pumpAndSettle();
    expect(find.text('迁移诊断'), findsOneWidget);
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('有跨会话摘要 · 1 条旧会话记忆'), findsOneWidget);
    expect(find.text('旧版正文'), findsNothing);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.ensureVisible(
      find.byKey(const ValueKey('memory-details-detail-memory')),
    );
    await tester
        .tap(find.byKey(const ValueKey('memory-details-detail-memory')));
    await tester.pumpAndSettle();
    expect(find.text('记忆详情'), findsOneWidget);
    expect(find.text('当前记忆'), findsOneWidget);
  });

  testWidgets('selection changes do not expose or trigger mutations',
      (tester) async {
    useViewport(tester, const Size(1200, 800));
    final alice = testCharacter('alice', apiConfigId: 'cfg')..name = 'Alice';
    final bob = testCharacter('bob', apiConfigId: 'cfg')..name = 'Bob';
    await putCharacter(alice);
    await putCharacter(bob);
    await putMemory(
      PermanentMemory(
        id: 'safe-memory',
        observerCharacterId: alice.id,
        kind: MemoryKind.fact,
        content: '不可误操作',
        status: MemoryStatus.active,
        originType: MemoryOriginType.manual,
        originNameSnapshot: '手动记录',
      ),
    );

    await pumpLoaded(
        tester,
        const MemoryManagementPage(
          scope: MemoryConversationScope.settings(),
        ));
    await tester.tap(find.byKey(const ValueKey('memory-observer-bob')));
    await tester.pump();

    expect(db.permanentMemoryBox.get('safe-memory')!.pinned, isFalse);
    expect(find.byTooltip('固定'), findsNothing);
    expect(find.byTooltip('删除'), findsNothing);
  });

  testWidgets('chat scope filters the browser and keeps details read-only',
      (tester) async {
    useViewport(tester, const Size(1200, 800));
    final member = testCharacter('group-member', apiConfigId: 'cfg')
      ..name = '群内 AI';
    final outside = testCharacter('outside-ai', apiConfigId: 'cfg')
      ..name = '群外 AI';
    await putCharacter(member);
    await putCharacter(outside);
    await putMemory(
      PermanentMemory(
        id: 'group-visible-memory',
        observerCharacterId: member.id,
        kind: MemoryKind.fact,
        content: '群内可见记忆',
        subjectIds: const ['user'],
        participantIds: [outside.id],
        status: MemoryStatus.active,
        originType: MemoryOriginType.group,
        originNameSnapshot: '当前群聊',
      ),
    );
    await putMemory(
      PermanentMemory(
        id: 'group-hidden-memory',
        observerCharacterId: outside.id,
        kind: MemoryKind.fact,
        content: '群外不可见记忆',
        subjectIds: const ['user'],
        status: MemoryStatus.active,
        originType: MemoryOriginType.group,
        originNameSnapshot: '其他群聊',
      ),
    );

    await pumpLoaded(
      tester,
      MemoryManagementPage(
        scope: MemoryConversationScope.group({'group-member'}),
      ),
    );

    expect(find.text('群内可见记忆'), findsOneWidget);
    expect(find.text('群外不可见记忆'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('memory-subject-quick-other')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('memory-subject-search')));
    await tester.pump();
    expect(find.text('群外 AI'), findsNothing);
    tester.binding.focusManager.primaryFocus?.unfocus();
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('memory-details-group-visible-memory')),
    );
    await tester.pumpAndSettle();

    expect(find.text('群内可见记忆'), findsOneWidget);
    expect(find.byKey(const ValueKey('memory-detail-pin')), findsNothing);
    expect(find.byKey(const ValueKey('memory-detail-correct')), findsNothing);
    expect(find.byKey(const ValueKey('memory-detail-delete')), findsNothing);
  });

  testWidgets('direct scope fixes the observer and hides management UI',
      (tester) async {
    useViewport(tester, const Size(1200, 800));
    final target = testCharacter('direct-target', apiConfigId: 'cfg')
      ..name = '私聊 AI';
    final other = testCharacter('direct-other', apiConfigId: 'cfg')
      ..name = '其他 AI';
    await putCharacter(target);
    await putCharacter(other);
    await putMemory(
      PermanentMemory(
        id: 'direct-visible-memory',
        observerCharacterId: target.id,
        kind: MemoryKind.preference,
        content: '私聊可见记忆',
        subjectIds: const ['user'],
        status: MemoryStatus.active,
        originType: MemoryOriginType.direct,
        originNameSnapshot: '私聊对象',
      ),
    );
    await putMemory(
      PermanentMemory(
        id: 'direct-hidden-memory',
        observerCharacterId: other.id,
        kind: MemoryKind.preference,
        content: '其他私聊不可见记忆',
        subjectIds: const ['user'],
        status: MemoryStatus.active,
        originType: MemoryOriginType.direct,
        originNameSnapshot: '其他对象',
      ),
    );

    await pumpLoaded(
      tester,
      MemoryManagementPage(
        scope: MemoryConversationScope.direct(target.id),
      ),
    );

    expect(find.text('私聊 AI 对我的记忆'), findsOneWidget);
    expect(find.text('私聊可见记忆'), findsOneWidget);
    expect(find.text('其他私聊不可见记忆'), findsNothing);
    expect(find.byKey(const ValueKey('memory-observer-sidebar')), findsNothing);
    expect(find.byKey(const ValueKey('memory-subject-selector')), findsNothing);
    await tester.tap(
      find.byKey(const ValueKey('memory-details-direct-visible-memory')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('memory-detail-pin')), findsNothing);
    expect(find.byKey(const ValueKey('memory-detail-correct')), findsNothing);
    expect(find.byKey(const ValueKey('memory-detail-delete')), findsNothing);
  });

  testWidgets('returns from detail with search and scroll context intact',
      (tester) async {
    useViewport(tester, const Size(1200, 800));
    final observer = testCharacter('state-observer', apiConfigId: 'cfg')
      ..name = '状态观察 AI';
    await putCharacter(observer);
    final memories = [
      for (var index = 0; index < 32; index++)
        PermanentMemory(
          id: 'state-memory-$index',
          observerCharacterId: observer.id,
          kind: MemoryKind.fact,
          content: '目标浏览记忆 $index',
          status: MemoryStatus.active,
          pinned: index == 0,
          originType: MemoryOriginType.manual,
          originNameSnapshot: '手动记录',
          updatedAt: DateTime(2026, 8, 1).add(Duration(minutes: index)),
        ),
    ];
    await TestWidgetsFlutterBinding.ensureInitialized().runAsync(
      () => db.permanentMemoryBox.putAll({
        for (final memory in memories) memory.id: memory,
      }),
    );

    await pumpLoaded(
        tester,
        const MemoryManagementPage(
          scope: MemoryConversationScope.settings(),
        ));
    final search = find.byKey(const ValueKey('memory-audit-search'));
    await tester.enterText(search, '目标浏览');
    await tester.pump();
    final scrollables = find.byType(Scrollable);
    final scrollableIndex = Iterable<int>.generate(
      scrollables.evaluate().length,
    ).firstWhere(
      (index) =>
          tester
              .state<ScrollableState>(scrollables.at(index))
              .position
              .maxScrollExtent >
          0,
    );
    final contentScrollable = scrollables.at(scrollableIndex);
    final scrollable = tester.state<ScrollableState>(contentScrollable);
    scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
    await tester.pump();
    final target = find.byKey(
      const ValueKey('memory-details-state-memory-1'),
    );
    expect(target, findsOneWidget);
    final beforeOffset = scrollable.position.pixels;
    expect(beforeOffset, greaterThan(0));

    await tester.tap(target);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('memory-detail-pin')));
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('memory-detail-pin')));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    expect(db.permanentMemoryBox.get('state-memory-1')!.pinned, isTrue);
    await tester.pageBack();
    await tester.pumpAndSettle();

    final currentContentScrollable = find
        .descendant(
          of: find.byKey(const ValueKey('memory-content')),
          matching: find.byType(Scrollable),
        )
        .first;
    final afterScrollable =
        tester.state<ScrollableState>(currentContentScrollable);
    final afterOffset = afterScrollable.position.pixels;
    expect(afterOffset, closeTo(beforeOffset, 2));
    afterScrollable.position.jumpTo(0);
    await tester.pump();
    expect(tester.widget<TextField>(search).controller!.text, '目标浏览');
    final targetRow = find.byKey(
      const ValueKey('memory-row-state-memory-1'),
    );
    final originalPinnedRow = find.byKey(
      const ValueKey('memory-row-state-memory-0'),
    );
    expect(targetRow, findsOneWidget);
    expect(originalPinnedRow, findsOneWidget);
    expect(
      tester.getTopLeft(targetRow).dy,
      lessThan(
        tester.getTopLeft(originalPinnedRow).dy,
      ),
    );
  });

  testWidgets('shows a retryable error when the memory box cannot be read',
      (tester) async {
    await tester.runAsync(() => db.permanentMemoryBox.close());
    try {
      await tester.pumpWidget(app(const MemoryManagementPage(
        scope: MemoryConversationScope.settings(),
      )));
      await tester.pump();
      expect(find.text('永久记忆加载失败'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      await tester.runAsync(
        () => Hive.openBox<PermanentMemory>('permanent_memories'),
      );
      await tester.tap(find.text('重试'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('永久记忆加载失败'), findsNothing);
      expect(find.text('暂无可用观察 AI'), findsWidgets);
    } finally {
      if (!Hive.isBoxOpen('permanent_memories')) {
        await tester.runAsync(
          () => Hive.openBox<PermanentMemory>('permanent_memories'),
        );
      }
    }
  });
}

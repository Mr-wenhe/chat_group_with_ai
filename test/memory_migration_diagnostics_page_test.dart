import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/character_memory.dart';
import 'package:chat_group/core/models/permanent_memory.dart';
import 'package:chat_group/features/ai_character/character_gender_migrator.dart';
import 'package:chat_group/features/memory/memory_audit_filter.dart';
import 'package:chat_group/features/memory/memory_management_page.dart';
import 'package:chat_group/features/memory/memory_migration_diagnostics_page.dart';
import 'package:chat_group/features/memory/memory_migrator.dart';
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
      await closeLifecycleHive(directory);
    });
  });

  setUp(() async {
    await db.appSettingsBox.clear();
    await db.aiCharacterBox.clear();
    await db.characterMemoryBox.clear();
    await db.chatGroupBox.clear();
    await db.permanentMemoryBox.clear();
  });

  Widget app(Widget home) => ProviderScope(
        overrides: [databaseServiceProvider.overrideWithValue(db)],
        child: MaterialApp(home: home),
      );

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

  testWidgets('opens diagnostics and keeps legacy details collapsed by role',
      (tester) async {
    useViewport(tester, const Size(1000, 800));
    final alice = testCharacter('alice', apiConfigId: 'cfg')
      ..name = 'Alice'
      ..memorySummary = '跨会话摘要正文';
    final bob = testCharacter('bob', apiConfigId: 'cfg')..name = 'Bob';
    await tester.runAsync(() async {
      await db.aiCharacterBox.putAll({alice.id: alice, bob.id: bob});
      await db.chatGroupBox.put(
        'group-1',
        ChatGroup(
          id: 'group-1',
          name: '产品交流群',
          theme: '',
          aiCharacterIds: [alice.id],
        ),
      );
      await db.characterMemoryBox.putAll({
        'session-alice': CharacterMemory(
          id: 'session-alice',
          groupId: 'group-1',
          characterId: alice.id,
          facts: ['旧会话正文'],
        ),
        'session-deleted': CharacterMemory(
          id: 'session-deleted',
          groupId: 'deleted-group',
          characterId: bob.id,
          facts: ['已删除群正文'],
        ),
      });
      await db.permanentMemoryBox.putAll({
        for (var index = 0; index < 2; index++)
          'legacy-$index': PermanentMemory(
            id: 'legacy-$index',
            observerCharacterId: alice.id,
            kind: MemoryKind.fact,
            content: '已迁移永久记忆 $index',
            status: MemoryStatus.active,
            originType: MemoryOriginType.legacyMigration,
            originNameSnapshot: '旧版跨会话摘要，原场合未知',
          ),
      });
      await db.appSettingsBox.put(CharacterGenderMigrator.diagnosticKey, {
        'status': 'completed',
        'characterCount': 2,
      });
    });

    await pumpLoaded(
      tester,
      const MemoryManagementPage(scope: MemoryConversationScope.settings()),
    );
    await tester.tap(find.byKey(const ValueKey('memory-migration-diagnostic')));
    await tester.pumpAndSettle();

    expect(find.text('迁移诊断'), findsOneWidget);
    expect(find.byType(BackButton), findsOneWidget);
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('legacy-diagnostic-character-count')),
          )
          .data,
      '2',
    );
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('legacy-diagnostic-session-count')),
          )
          .data,
      '2',
    );
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('legacy-diagnostic-permanent-count')),
          )
          .data,
      '2',
    );
    expect(
      find.text('旧版数据仅供诊断，不注入 Prompt，也不能在这里编辑。'),
      findsOneWidget,
    );
    expect(find.text('性别迁移：已完成 · 2 个角色'), findsOneWidget);
    expect(find.text('跨会话摘要正文'), findsNothing);
    expect(find.text('旧会话正文'), findsNothing);
    expect(find.text('已删除群正文'), findsNothing);
    expect(find.text('有跨会话摘要 · 1 条旧会话记忆'), findsOneWidget);
    expect(find.text('无跨会话摘要 · 1 条旧会话记忆'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('memory-migration-role-alice')));
    await tester.pumpAndSettle();
    expect(find.text('跨会话摘要正文'), findsOneWidget);
    expect(find.text('产品交流群'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('memory-migration-session-group-1')),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('旧会话正文'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('memory-migration-technical-role-alice')),
      findsOneWidget,
    );
    expect(find.text('角色 ID：alice'), findsNothing);

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('memory-migration-role-bob')),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('memory-migration-role-bob')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('已删除群聊'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('已删除群聊'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('memory-migration-session-deleted-group')),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('已删除群正文'), findsOneWidget);
    expect(find.text('deleted-group'), findsNothing);
    await tester.tap(
      find.byKey(
          const ValueKey('memory-migration-technical-session-deleted-group')),
    );
    await tester.pumpAndSettle();
    expect(find.text('会话 ID：deleted-group'), findsOneWidget);

    expect(find.text('编辑'), findsNothing);
    expect(find.text('固定'), findsNothing);
    expect(find.text('删除'), findsNothing);
  });

  testWidgets('shows a safe summary when permanent-memory migration is partial',
      (tester) async {
    useViewport(tester, const Size(1000, 800));
    await tester.runAsync(() async {
      await db.appSettingsBox.put(MemoryMigrator.diagnosticKey, {
        'status': 'partial',
        'warningCount': 2,
        'reasonCodes': ['legacy_subject_repair_failed'],
      });
    });

    await pumpLoaded(tester, const MemoryMigrationDiagnosticsPage());

    expect(find.text('永久记忆迁移：部分完成'), findsOneWidget);
    expect(find.text('2 项安全诊断待处理'), findsOneWidget);
  });

  testWidgets('builds a large role list lazily', (tester) async {
    useViewport(tester, const Size(1000, 800));
    final characters = [
      for (var index = 0; index < 50; index++)
        testCharacter('legacy-$index', apiConfigId: 'cfg')
          ..name = '旧角色 $index'
          ..memorySummary = '摘要 $index',
    ];
    await tester.runAsync(() async {
      await db.aiCharacterBox.putAll({
        for (final character in characters) character.id: character,
      });
    });

    await pumpLoaded(
      tester,
      const MemoryMigrationDiagnosticsPage(),
    );

    expect(
      find.byKey(const ValueKey('memory-migration-role-legacy-49')),
      findsNothing,
    );
  });

  testWidgets('builds session正文 only after an individual session expands',
      (tester) async {
    useViewport(tester, const Size(1000, 800));
    final character = testCharacter('legacy-character', apiConfigId: 'cfg')
      ..name = '旧角色'
      ..memorySummary = '跨会话摘要';
    final group = ChatGroup(
      id: 'group-large',
      name: '大数据群聊',
      theme: '',
      aiCharacterIds: [character.id],
    );
    await tester.runAsync(() async {
      await db.aiCharacterBox.put(character.id, character);
      await db.chatGroupBox.put(group.id, group);
      await db.characterMemoryBox.put(
        'session-large',
        CharacterMemory(
          id: 'session-large',
          groupId: group.id,
          characterId: character.id,
          facts: [for (var index = 0; index < 100; index++) '会话正文 $index'],
        ),
      );
    });

    await pumpLoaded(tester, const MemoryMigrationDiagnosticsPage());
    await tester.tap(
      find.byKey(const ValueKey('memory-migration-role-legacy-character')),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('旧版会话记忆'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('大数据群聊'),
      400,
      scrollable: find.byType(Scrollable).first,
    );

    expect(find.textContaining('会话正文 0'), findsNothing);
    expect(find.textContaining('会话正文 99'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey('memory-migration-session-group-large')),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('会话正文 0'), findsOneWidget);
    expect(find.textContaining('会话正文 99'), findsOneWidget);
  });

  testWidgets('hides technical role names behind a friendly placeholder',
      (tester) async {
    useViewport(tester, const Size(1000, 800));
    const technicalId = '550e8400-e29b-41d4-a716-446655440000';
    final character = testCharacter(technicalId, apiConfigId: 'cfg')
      ..name = technicalId
      ..memorySummary = '旧版摘要';
    await tester.runAsync(() async {
      await db.aiCharacterBox.put(character.id, character);
    });

    await pumpLoaded(tester, const MemoryMigrationDiagnosticsPage());

    expect(find.text(technicalId), findsNothing);
    expect(find.text('已删除角色'), findsOneWidget);
  });

  testWidgets('shows a retryable error when legacy memory cannot be read',
      (tester) async {
    await tester.runAsync(() => db.characterMemoryBox.close());
    try {
      await tester.pumpWidget(app(const MemoryMigrationDiagnosticsPage()));
      await tester.pump();

      expect(find.text('迁移诊断加载失败'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);

      await tester.runAsync(
        () => Hive.openBox<CharacterMemory>('character_memories'),
      );
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();

      expect(find.text('迁移诊断加载失败'), findsNothing);
      expect(find.text('没有发现可诊断的旧版数据。'), findsOneWidget);
    } finally {
      if (!Hive.isBoxOpen('character_memories')) {
        await tester.runAsync(
          () => Hive.openBox<CharacterMemory>('character_memories'),
        );
      }
    }
  });
}

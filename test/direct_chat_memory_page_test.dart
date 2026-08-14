import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/permanent_memory.dart';
import 'package:chat_group/features/memory/memory_audit_filter.dart';
import 'package:chat_group/features/memory/memory_management_page.dart';
import 'package:chat_group/features/memory/memory_migrator.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/lifecycle_hive.dart';

void main() {
  late Directory directory;
  late DatabaseService db;

  setUpAll(() async {
    directory = await openLifecycleHive();
    db = DatabaseService();
  });

  tearDownAll(() async {
    await closeLifecycleHive(directory, db);
  });

  setUp(() async {
    await db.permanentMemoryBox.clear();
    await db.aiCharacterBox.clear();
    await db.chatGroupBox.clear();
    await db.messageBox.clear();
  });

  Widget app(Widget home) => ProviderScope(
        overrides: [databaseServiceProvider.overrideWithValue(db)],
        child: MaterialApp(home: home),
      );

  Future<void> putCharacter(AICharacter character) =>
      TestWidgetsFlutterBinding.ensureInitialized()
          .runAsync(() => db.aiCharacterBox.put(character.id, character));

  Future<void> putMemory(PermanentMemory memory) =>
      TestWidgetsFlutterBinding.ensureInitialized()
          .runAsync(() => db.permanentMemoryBox.put(memory.id, memory));

  Future<void> pumpLoaded(WidgetTester tester, Widget page) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(app(page));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  test('direct scope rejects mixed subjects before applying filters', () {
    final scope = MemoryConversationScope.direct('target');
    final visible = PermanentMemory(
      id: 'visible',
      observerCharacterId: 'target',
      subjectIds: const ['user'],
      kind: MemoryKind.fact,
      content: '只关于用户',
      status: MemoryStatus.active,
      originType: MemoryOriginType.direct,
      originNameSnapshot: '私聊 AI',
    );
    final mixed = PermanentMemory(
      id: 'mixed',
      observerCharacterId: 'target',
      subjectIds: const ['user', 'other'],
      kind: MemoryKind.fact,
      content: '混合主体',
      status: MemoryStatus.active,
      originType: MemoryOriginType.group,
      originNameSnapshot: '其他群聊',
    );

    final filtered = const MemoryAuditFilter().apply(
      [visible, mixed],
      scope: scope,
    );

    expect(filtered.map((memory) => memory.id), ['visible']);
  });

  testWidgets('direct page fixes identity, keeps scope, and is read-only',
      (tester) async {
    final target = testCharacter(
      'direct-target',
      apiConfigId: 'cfg',
      gender: CharacterGender.male,
    )
      ..name = '私聊 AI'
      ..role = '产品经理'
      ..memorySummary = '【事实】旧版迁移的历史记忆';
    final other = testCharacter('other-ai', apiConfigId: 'cfg')..name = '其他 AI';
    await putCharacter(target);
    await putCharacter(other);

    await putMemory(PermanentMemory(
      id: 'direct-active-group',
      observerCharacterId: target.id,
      subjectIds: const ['user'],
      kind: MemoryKind.preference,
      content: '来自其他群聊的有效记忆',
      status: MemoryStatus.active,
      originType: MemoryOriginType.group,
      originConversationId: 'group-other',
      originNameSnapshot: '产品讨论群',
    ));
    await putMemory(PermanentMemory(
      id: 'direct-active-manual',
      observerCharacterId: target.id,
      subjectIds: const ['user'],
      kind: MemoryKind.fact,
      content: '来自手动记录的有效记忆',
      status: MemoryStatus.active,
      originType: MemoryOriginType.manual,
      originNameSnapshot: '手动记录',
    ));
    await putMemory(PermanentMemory(
      id: 'direct-active-other-chat',
      observerCharacterId: target.id,
      subjectIds: const ['user'],
      kind: MemoryKind.sharedExperience,
      content: '来自其他私聊的有效记忆',
      status: MemoryStatus.active,
      originType: MemoryOriginType.direct,
      originConversationId: 'dm:${other.id}',
      originNameSnapshot: '私聊',
    ));
    await putMemory(PermanentMemory(
      id: 'direct-superseded',
      observerCharacterId: target.id,
      subjectIds: const ['user'],
      kind: MemoryKind.fact,
      content: '已取代的历史记忆',
      status: MemoryStatus.superseded,
      originType: MemoryOriginType.direct,
      originNameSnapshot: '私聊 AI',
    ));
    await putMemory(PermanentMemory(
      id: 'direct-invalidated',
      observerCharacterId: target.id,
      subjectIds: const ['user'],
      kind: MemoryKind.fact,
      content: '已失效的历史记忆',
      status: MemoryStatus.invalidated,
      originType: MemoryOriginType.direct,
      originNameSnapshot: '私聊 AI',
    ));
    await putMemory(PermanentMemory(
      id: 'direct-legacy-growth-hidden',
      observerCharacterId: target.id,
      subjectIds: const [],
      kind: MemoryKind.personaGrowth,
      content: '旧版自身成长不可见',
      status: MemoryStatus.active,
      originType: MemoryOriginType.legacyMigration,
      originNameSnapshot: '旧版记忆',
    ));
    await putMemory(PermanentMemory(
      id: 'direct-mixed-hidden',
      observerCharacterId: target.id,
      subjectIds: [
        'user',
        other.id,
      ],
      kind: MemoryKind.fact,
      content: '混合主体不可见',
      status: MemoryStatus.active,
      originType: MemoryOriginType.group,
      originNameSnapshot: '其他群聊',
    ));
    await putMemory(PermanentMemory(
      id: 'direct-other-subject-hidden',
      observerCharacterId: target.id,
      subjectIds: [other.id],
      kind: MemoryKind.fact,
      content: '其他主体不可见',
      status: MemoryStatus.active,
      originType: MemoryOriginType.group,
      originNameSnapshot: '其他群聊',
    ));
    await putMemory(PermanentMemory(
      id: 'direct-other-observer-hidden',
      observerCharacterId: other.id,
      subjectIds: const ['user'],
      kind: MemoryKind.fact,
      content: '其他观察 AI 不可见',
      status: MemoryStatus.active,
      originType: MemoryOriginType.direct,
      originNameSnapshot: '其他 AI',
    ));

    await TestWidgetsFlutterBinding.ensureInitialized()
        .runAsync(() => MemoryMigrator(db).migrate());

    await pumpLoaded(
      tester,
      MemoryManagementPage(scope: MemoryConversationScope.direct(target.id)),
    );

    expect(find.text('私聊 AI 对我的记忆'), findsOneWidget);
    expect(find.text('男 · 产品经理'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('memory-migration-diagnostic')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('memory-observer-sidebar')), findsNothing);
    expect(
        find.byKey(const ValueKey('memory-observer-selector')), findsNothing);
    expect(find.byKey(const ValueKey('memory-subject-selector')), findsNothing);
    expect(find.text('来自其他群聊的有效记忆'), findsOneWidget);
    expect(find.text('来自手动记录的有效记忆'), findsOneWidget);
    expect(find.text('来自其他私聊的有效记忆'), findsOneWidget);
    expect(find.textContaining('私聊 · 与 其他 AI 的私聊'), findsOneWidget);
    expect(find.text('混合主体不可见'), findsNothing);
    expect(find.text('其他主体不可见'), findsNothing);
    expect(find.text('其他观察 AI 不可见'), findsNothing);
    expect(find.text('旧版自身成长不可见'), findsNothing);
    expect(find.text('历史记录（3）'), findsOneWidget);
    expect(find.text('已取代的历史记忆'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey('open-advanced-memory-filter')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('memory-filter-dialog-observer')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('memory-filter-dialog-subject')),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('memory-filter-dialog-apply')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('memory-history-section')));
    await tester.pump();
    expect(find.text('已取代的历史记忆'), findsOneWidget);
    expect(find.text('已失效的历史记忆'), findsOneWidget);
    expect(find.text('旧版迁移的历史记忆'), findsOneWidget);
    expect(find.textContaining('群聊 · 产品讨论群'), findsOneWidget);

    final search = find.byKey(const ValueKey('memory-audit-search'));
    await tester.enterText(search, '混合主体不可见');
    await tester.pump();
    expect(
      find.byKey(const ValueKey('memory-row-direct-mixed-hidden')),
      findsNothing,
    );

    await tester.enterText(search, '来自其他群聊');
    await tester.pump();
    expect(find.text('来自其他群聊的有效记忆'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('memory-details-direct-active-group')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('memory-detail-pin')), findsNothing);
    expect(find.byKey(const ValueKey('memory-detail-correct')), findsNothing);
    expect(find.byKey(const ValueKey('memory-detail-delete')), findsNothing);
  });

  testWidgets('direct empty state ignores memories from other AI',
      (tester) async {
    final target = testCharacter('empty-direct-target', apiConfigId: 'cfg')
      ..name = '没有记忆的私聊 AI';
    final other = testCharacter('empty-direct-other', apiConfigId: 'cfg')
      ..name = '另一个 AI';
    await putCharacter(target);
    await putCharacter(other);
    await putMemory(PermanentMemory(
      id: 'other-only-memory',
      observerCharacterId: other.id,
      kind: MemoryKind.fact,
      content: '另一个 AI 的记忆',
      subjectIds: const ['user'],
      status: MemoryStatus.active,
      originType: MemoryOriginType.direct,
      originNameSnapshot: '另一个 AI',
    ));

    await pumpLoaded(
      tester,
      MemoryManagementPage(scope: MemoryConversationScope.direct(target.id)),
    );

    expect(find.text('还没有永久记忆'), findsOneWidget);
    expect(find.text('返回聊天'), findsOneWidget);
    expect(find.text('返回全部记录'), findsNothing);
    expect(find.text('另一个 AI 的记忆'), findsNothing);
  });
}

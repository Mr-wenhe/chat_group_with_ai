import 'dart:async';
import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/database/data_lifecycle_settings.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/permanent_memory.dart';
import 'package:chat_group/features/memory/memory_audit_filter.dart';
import 'package:chat_group/features/memory/memory_controls.dart';
import 'package:chat_group/features/memory/memory_detail_page.dart';
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
    await db.messageBox.clear();
    await db.chatGroupBox.clear();
  });

  Widget app(Widget home) => ProviderScope(
        overrides: [databaseServiceProvider.overrideWithValue(db)],
        child: MaterialApp(home: home),
      );

  Future<void> putCharacter(WidgetTester tester, AICharacter character) =>
      tester.runAsync(() => db.aiCharacterBox.put(character.id, character));

  Future<void> putMemory(WidgetTester tester, PermanentMemory memory) =>
      tester.runAsync(() => db.permanentMemoryBox.put(memory.id, memory));

  Future<void> pumpPage(
    WidgetTester tester,
    PermanentMemory memory, {
    MemoryConversationScope scope = const MemoryConversationScope.settings(),
    MemoryControls? testControls,
  }) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(app(MemoryDetailPage(
      memory: memory,
      scope: scope,
      testControls: testControls,
    )));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> pumpInteraction(WidgetTester tester) async {
    await tester.runAsync(() async {});
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('shows friendly public memory details and source message',
      (tester) async {
    final observer = testCharacter('observer', apiConfigId: 'cfg')..name = '小林';
    final subject = testCharacter('subject', apiConfigId: 'cfg')..name = '阿青';
    await putCharacter(tester, observer);
    await putCharacter(tester, subject);
    final message = Message(
      id: 'source-message',
      groupId: 'group-1',
      senderId: 'user',
      senderType: 'user',
      content: '我最近开始喝无糖咖啡。',
    );
    await tester.runAsync(() => db.messageBox.put(message.id, message));
    await tester.runAsync(() => db.chatGroupBox.put(
          'group-1',
          ChatGroup(
            id: 'group-1',
            name: '咖啡研究所',
            theme: '咖啡',
            aiCharacterIds: const [],
          ),
        ));
    final memory = PermanentMemory(
      id: 'technical-memory-id',
      observerCharacterId: observer.id,
      kind: MemoryKind.preference,
      content: '完整正文：用户偏好无糖咖啡。',
      subjectIds: ['user', subject.id],
      status: MemoryStatus.active,
      pinned: true,
      originType: MemoryOriginType.group,
      originConversationId: 'group-1',
      originNameSnapshot: '咖啡研究所',
      sourceMessageIds: [message.id],
      occurredAt: DateTime(2026, 8, 1, 9),
      createdAt: DateTime(2026, 8, 1, 10),
      updatedAt: DateTime(2026, 8, 1, 11),
    );
    await putMemory(tester, memory);

    await pumpPage(tester, memory);

    expect(find.text('完整正文：用户偏好无糖咖啡。'), findsOneWidget);
    expect(find.text('小林'), findsOneWidget);
    expect(find.text('我、阿青'), findsOneWidget);
    expect(find.text('偏好'), findsOneWidget);
    expect(find.text('有效'), findsOneWidget);
    expect(find.text('固定'), findsWidgets);
    expect(find.text('群聊 · 咖啡研究所'), findsOneWidget);
    expect(find.text('发生时间'), findsOneWidget);
    expect(find.text('创建时间'), findsOneWidget);
    expect(find.text('更新时间'), findsOneWidget);
    expect(find.text('我最近开始喝无糖咖啡。'), findsOneWidget);
    final sourceButton = tester.widget<TextButton>(
      find.byKey(const ValueKey('memory-detail-open-source')),
    );
    expect(sourceButton.onPressed, isNotNull);
    expect(find.text('technical-memory-id'), findsNothing);
    expect(find.text('group-1'), findsNothing);
  });

  testWidgets('uses the presenter format for a direct snapshot without an ID',
      (tester) async {
    final observer = testCharacter('direct-observer', apiConfigId: 'cfg')
      ..name = '私聊 AI';
    await putCharacter(tester, observer);
    final memory = PermanentMemory(
      id: 'direct-snapshot-memory',
      observerCharacterId: observer.id,
      kind: MemoryKind.preference,
      content: '空来源 ID 也要保持友好来源格式',
      subjectIds: const ['user'],
      status: MemoryStatus.active,
      originType: MemoryOriginType.direct,
      originNameSnapshot: '私聊 AI',
    );
    await putMemory(tester, memory);

    await pumpPage(tester, memory);

    expect(find.text('私聊 · 与 私聊 AI 的私聊'), findsOneWidget);
  });

  testWidgets('hides technical observer names from the public detail view',
      (tester) async {
    const technicalId = '550e8400-e29b-41d4-a716-446655440000';
    final technicalCharacter = testCharacter(technicalId, apiConfigId: 'cfg')
      ..name = technicalId;
    await putCharacter(tester, technicalCharacter);
    final memory = PermanentMemory(
      id: 'technical-name-memory',
      observerCharacterId: technicalId,
      kind: MemoryKind.fact,
      content: '技术名称不应出现在普通详情中',
      subjectIds: const ['user'],
      status: MemoryStatus.active,
      originType: MemoryOriginType.manual,
      originNameSnapshot: '手动记录',
    );
    await putMemory(tester, memory);

    await pumpPage(tester, memory);

    expect(find.text('已删除角色'), findsOneWidget);
    expect(find.text(technicalId), findsNothing);
  });

  testWidgets('summarizes a long source message in the detail page',
      (tester) async {
    final source = Message(
      id: 'long-source-message',
      groupId: 'group-1',
      senderId: 'user',
      senderType: 'user',
      content: '摘要开头 ${'细节内容 ' * 80}',
    );
    final memory = PermanentMemory(
      id: 'long-source-memory',
      observerCharacterId: 'observer',
      kind: MemoryKind.fact,
      content: '完整记忆正文',
      subjectIds: const ['user'],
      status: MemoryStatus.active,
      originType: MemoryOriginType.group,
      originConversationId: 'group-1',
      originNameSnapshot: '群聊',
      sourceMessageIds: [source.id],
    );
    await tester.runAsync(() async {
      await db.messageBox.put(source.id, source);
      await db.permanentMemoryBox.put(memory.id, memory);
    });

    await pumpPage(tester, memory);

    expect(find.textContaining('摘要开头'), findsOneWidget);
    expect(find.text(source.content), findsNothing);
  });

  testWidgets(
      'shows unavailable source message and hides technical data in chat scope',
      (tester) async {
    final memory = PermanentMemory(
      id: 'hidden-memory-id',
      observerCharacterId: 'missing-observer',
      kind: MemoryKind.fact,
      content: '来源已经不存在的记忆',
      status: MemoryStatus.active,
      originType: MemoryOriginType.group,
      originNameSnapshot: '旧群聊',
      sourceMessageIds: const ['missing-message'],
      subjectIds: const ['user'],
    );
    await putMemory(tester, memory);

    await pumpPage(
      tester,
      memory,
      scope: MemoryConversationScope.group({'missing-observer'}),
    );

    expect(find.text('原始消息已不可用'), findsOneWidget);
    final sourceButton = tester.widget<TextButton>(
      find.byKey(const ValueKey('memory-detail-open-source-unavailable')),
    );
    expect(sourceButton.onPressed, isNull);
    expect(find.text('技术信息'), findsNothing);
    expect(find.byKey(const ValueKey('memory-detail-pin')), findsNothing);
    expect(find.byKey(const ValueKey('memory-detail-correct')), findsNothing);
    expect(find.byKey(const ValueKey('memory-detail-delete')), findsNothing);
  });

  testWidgets('settings exposes technical information and guarded mutations',
      (tester) async {
    final memory = PermanentMemory(
      id: 'settings-memory-id',
      observerCharacterId: 'observer',
      kind: MemoryKind.fact,
      content: '设置可以管理的记忆',
      status: MemoryStatus.active,
      originType: MemoryOriginType.manual,
      originNameSnapshot: '手动记录',
      pinned: false,
    );
    await putMemory(tester, memory);
    await pumpPage(tester, memory);

    expect(find.byKey(const ValueKey('memory-detail-pin')), findsOneWidget);
    expect(find.byKey(const ValueKey('memory-detail-correct')), findsOneWidget);
    expect(find.byKey(const ValueKey('memory-detail-delete')), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('memory-detail-technical-information')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(
      find.byKey(const ValueKey('memory-detail-technical-information')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('settings-memory-id'), findsOneWidget);

    await tester
        .ensureVisible(find.byKey(const ValueKey('memory-detail-delete')));
    await tester.tap(find.byKey(const ValueKey('memory-detail-delete')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('后续不会再注入，旧版本不会自动恢复'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await pumpInteraction(tester);
    expect(db.permanentMemoryBox.get(memory.id), isNotNull);
  });

  testWidgets('pinned correction retains a confirmation step', (tester) async {
    final memory = PermanentMemory(
      id: 'pinned-memory',
      observerCharacterId: 'observer',
      kind: MemoryKind.fact,
      content: '固定内容',
      status: MemoryStatus.active,
      pinned: true,
      originType: MemoryOriginType.manual,
      originNameSnapshot: '手动记录',
    );
    await putMemory(tester, memory);
    await pumpPage(tester, memory);

    await tester
        .ensureVisible(find.byKey(const ValueKey('memory-detail-correct')));
    await tester.tap(find.byKey(const ValueKey('memory-detail-correct')));
    await tester.pump();
    await tester.enterText(
        find.byKey(const ValueKey('memory-correction-content')), '修正内容');
    await tester.tap(find.text('保存修正'));
    await tester.runAsync(() async {});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('修正固定记忆？'), findsOneWidget);
    expect(db.permanentMemoryBox.values.any((item) => item.content == '修正内容'),
        isFalse);
    await tester.tap(find.text('取消'));
    await tester.pump();
  });

  testWidgets('does not render a memory outside a deep-linked chat scope',
      (tester) async {
    final memory = PermanentMemory(
      id: 'out-of-scope-memory',
      observerCharacterId: 'other-ai',
      kind: MemoryKind.fact,
      content: '不应在当前私聊出现的正文',
      status: MemoryStatus.active,
      originType: MemoryOriginType.group,
      originNameSnapshot: '其他场合',
      subjectIds: const ['other-ai'],
    );
    await putMemory(tester, memory);

    await pumpPage(
      tester,
      memory,
      scope: MemoryConversationScope.direct('current-ai'),
    );

    expect(find.text('不应在当前私聊出现的正文'), findsNothing);
    expect(find.text('这条记忆不可用'), findsOneWidget);
    expect(find.byKey(const ValueKey('memory-detail-delete')), findsNothing);
  });

  testWidgets('restores management actions after a failed delete',
      (tester) async {
    final memory = PermanentMemory(
      id: 'failed-delete-memory',
      observerCharacterId: 'observer',
      kind: MemoryKind.fact,
      content: '删除失败后仍可重试',
      status: MemoryStatus.active,
      originType: MemoryOriginType.manual,
      originNameSnapshot: '手动记录',
    );
    final controls = _FailingMemoryControls(db);
    await putMemory(tester, memory);

    await pumpPage(tester, memory, testControls: controls);
    await tester.tap(find.byKey(const ValueKey('memory-detail-delete')));
    await tester.pump();
    final confirmDelete = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.widgetWithText(FilledButton, '删除'),
    );
    await tester.tap(confirmDelete);
    await tester.runAsync(() async {});
    await tester.pump();

    expect(find.text('操作失败，请稍后重试。'), findsOneWidget);
    final deleteButton = tester.widget<FilledButton>(
      find.byKey(const ValueKey('memory-detail-delete')),
    );
    expect(deleteButton.onPressed, isNotNull);
  });

  testWidgets('one pin tap invokes controls only once', (tester) async {
    final memory = PermanentMemory(
      id: 'duplicate-pin-memory',
      observerCharacterId: 'observer',
      kind: MemoryKind.fact,
      content: '只固定一次',
      status: MemoryStatus.active,
      originType: MemoryOriginType.manual,
      originNameSnapshot: '手动记录',
    );
    final controls = _CountingMemoryControls(db, blockPin: true);
    await putMemory(tester, memory);

    await pumpPage(tester, memory, testControls: controls);
    final pin = find.byKey(const ValueKey('memory-detail-pin'));
    await tester.tap(pin);
    await tester.tap(pin);
    expect(controls.pinCalls, 1);
    controls.completePin();
    await tester.runAsync(() async {});
    await tester.pump();

    expect(controls.pinCalls, 1);
  });

  testWidgets('system back returns true after a successful mutation',
      (tester) async {
    final memory = PermanentMemory(
      id: 'changed-system-back-memory',
      observerCharacterId: 'observer',
      kind: MemoryKind.fact,
      content: '系统返回应携带修改结果',
      status: MemoryStatus.active,
      originType: MemoryOriginType.manual,
      originNameSnapshot: '手动记录',
    );
    await putMemory(tester, memory);
    final controls = _CountingMemoryControls(db);
    bool? result;
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      app(
        Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () async {
                result = await Navigator.of(context).push<bool>(
                  MaterialPageRoute(
                    builder: (_) => MemoryDetailPage(
                      memory: memory,
                      scope: const MemoryConversationScope.settings(),
                      testControls: controls,
                    ),
                  ),
                );
              },
              child: const Text('打开修改详情'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开修改详情'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('memory-detail-pin')));
    await tester.pump();
    await tester.pageBack();
    await pumpInteraction(tester);

    expect(result, isTrue);
  });

  testWidgets('system back returns from the detail route through PopScope',
      (tester) async {
    final memory = PermanentMemory(
      id: 'system-back-memory',
      observerCharacterId: 'observer',
      kind: MemoryKind.fact,
      content: '系统返回测试',
      status: MemoryStatus.active,
      originType: MemoryOriginType.manual,
      originNameSnapshot: '手动记录',
    );
    await putMemory(tester, memory);
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      app(
        Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => MemoryDetailPage(
                    memory: memory,
                    scope: const MemoryConversationScope.settings(),
                  ),
                ),
              ),
              child: const Text('打开详情'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开详情'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pageBack();
    await pumpInteraction(tester);
    expect(find.text('打开详情'), findsOneWidget);
  });

  testWidgets(
      'uses deleted character snapshots and hides UUID origin snapshots',
      (tester) async {
    final deleted = testCharacter('deleted-observer', apiConfigId: 'cfg')
      ..name = '历史观察 AI';
    await tester.runAsync(
      () => DataLifecycleSettings(db).saveDeletedCharacter(deleted),
    );
    final memory = PermanentMemory(
      id: 'snapshot-memory',
      observerCharacterId: deleted.id,
      kind: MemoryKind.fact,
      content: '历史快照正文',
      status: MemoryStatus.active,
      originType: MemoryOriginType.group,
      originNameSnapshot: '550e8400-e29b-41d4-a716-446655440000',
    );
    await putMemory(tester, memory);
    await pumpPage(tester, memory);

    expect(find.text('历史观察 AI'), findsOneWidget);
    expect(find.text('已删除角色'), findsNothing);
    expect(find.text('550e8400-e29b-41d4-a716-446655440000'), findsNothing);
    expect(find.textContaining('已删除群聊'), findsOneWidget);
  });
}

class _FailingMemoryControls extends MemoryControls {
  _FailingMemoryControls(super.db);

  @override
  Future<void> deletePermanent(PermanentMemory memory) =>
      Future<void>.error(StateError('test delete failure'));
}

class _CountingMemoryControls extends MemoryControls {
  int pinCalls = 0;
  final bool blockPin;
  final Completer<void> _pinCompletion = Completer<void>();

  _CountingMemoryControls(super.db, {this.blockPin = false});

  @override
  Future<void> pinPermanent(PermanentMemory memory) {
    pinCalls += 1;
    return blockPin ? _pinCompletion.future : Future<void>.value();
  }

  void completePin() {
    if (!_pinCompletion.isCompleted) _pinCompletion.complete();
  }
}

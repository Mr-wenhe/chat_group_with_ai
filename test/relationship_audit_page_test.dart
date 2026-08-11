import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/database/data_lifecycle_settings.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/relationship_event.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/core/models/user_profile.dart';
import 'package:chat_group/features/chat_group/chat_room_page.dart';
import 'package:chat_group/features/memory/relationship_audit_filter.dart';
import 'package:chat_group/features/memory/relationship_audit_filter_widget.dart';
import 'package:chat_group/features/memory/relationship_audit_page.dart';
import 'package:chat_group/features/memory/relationship_edit_dialog.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/lifecycle_hive.dart';

void main() {
  late Directory directory;
  late DatabaseService db;

  setUp(() async {
    directory = await openLifecycleHive();
    db = DatabaseService();
  });

  tearDown(() async {
    await closeLifecycleHive(directory, db);
  });

  Widget app({NavigatorObserver? navigatorObserver}) => ProviderScope(
        overrides: [databaseServiceProvider.overrideWithValue(db)],
        child: MaterialApp(
          navigatorObservers: [
            if (navigatorObserver != null) navigatorObserver,
          ],
          home: const RelationshipAuditPage(),
        ),
      );

  AICharacter character(String id, String name) => AICharacter(
        id: id,
        name: name,
        avatar: name.substring(0, 1),
        age: 20,
        role: '测试角色',
        personalityTags: const [],
        systemPrompt: 'test',
        apiKey: '',
        apiProvider: '',
      );

  RelationshipState state({
    required String source,
    required RelationshipTargetType targetType,
    required String target,
    int revision = 2,
    RelationshipStage stage = RelationshipStage.friend,
  }) =>
      RelationshipState.global(
        sourceCharacterId: source,
        targetType: targetType,
        targetId: target,
        affinity: 42,
        trust: -7,
        friction: 13,
        familiarity: 86,
        recentMood: RelationshipMood.warm,
        notes: '当前关系备注',
        stage: stage,
        revision: revision,
        updatedAt: DateTime(2026, 8, 9, 10),
        lastEventId: 'event-$source-$target',
        lastInteractionAt: DateTime(2026, 8, 8, 10),
      );

  RelationshipEvent event({
    required String id,
    required String source,
    RelationshipTargetType targetType = RelationshipTargetType.ai,
    required String target,
    required int revision,
    required RelationshipEventCreator creator,
    String? originConversationId,
    String originNameSnapshot = '来源群聊',
    List<String> sourceMessageIds = const [],
    RelationshipStage stageAfter = RelationshipStage.friend,
    DateTime? occurredAt,
  }) =>
      RelationshipEvent(
        id: id,
        sourceCharacterId: source,
        targetType: targetType,
        targetId: target,
        reason: '事件 $revision',
        affinityBefore: revision - 1,
        affinityAfter: revision,
        trustBefore: 10 + revision - 1,
        trustAfter: 10 + revision,
        frictionBefore: 2,
        frictionAfter: 3,
        familiarityBefore: 20 + revision - 1,
        familiarityAfter: 20 + revision,
        moodBefore: RelationshipMood.neutral,
        moodAfter: RelationshipMood.warm,
        stageBefore: RelationshipStage.acquaintance,
        stageAfter: stageAfter,
        originConversationId: originConversationId,
        originNameSnapshot: originNameSnapshot,
        sourceMessageIds: sourceMessageIds,
        revision: revision,
        occurredAt: occurredAt ?? DateTime(2026, 8, 1, revision),
        confidence: creator == RelationshipEventCreator.manual ? 1.0 : 0.7,
        createdBy: creator,
      );

  testWidgets('shows directional global snapshots and all current fields',
      (tester) async {
    await tester.runAsync(() async {
      final a = character('a', '阿月');
      final b = character('b', '小明');
      await db.aiCharacterBox.put(a.id, a);
      await db.aiCharacterBox.put(b.id, b);
      await db.userProfileBox.put(
        'me',
        UserProfile(
          displayName: '小明',
          preferredAddress: '你',
          avatar: '',
          bio: '',
        ),
      );
      final aToB = state(
        source: 'a',
        targetType: RelationshipTargetType.ai,
        target: 'b',
      );
      final bToA = state(
        source: 'b',
        targetType: RelationshipTargetType.ai,
        target: 'a',
      );
      final aToUser = state(
        source: 'a',
        targetType: RelationshipTargetType.user,
        target: 'user',
      );
      await db.relationshipStateBox.put(aToB.id, aToB);
      await db.relationshipStateBox.put(bToA.id, bToA);
      await db.relationshipStateBox.put(aToUser.id, aToUser);
      await db.relationshipStateBox.put(
        'legacy',
        RelationshipState(
          id: 'legacy',
          groupId: 'group-legacy',
          sourceCharacterId: 'a',
          targetType: RelationshipTargetType.ai,
          targetId: 'b',
        ),
      );
      await db.relationshipEventBox.put(
        'e1',
        event(
          id: 'e1',
          source: 'a',
          target: 'b',
          revision: 1,
          creator: RelationshipEventCreator.automatic,
          originConversationId: 'group-other',
        ),
      );
      await db.relationshipEventBox.put(
        'e2',
        event(
          id: 'e2',
          source: 'a',
          target: 'b',
          revision: 2,
          creator: RelationshipEventCreator.manual,
          originConversationId: null,
          originNameSnapshot: '人工编辑',
        ),
      );
      await db.relationshipEventBox.put(
        'e3',
        event(
          id: 'e3',
          source: 'a',
          target: 'b',
          revision: 3,
          creator: RelationshipEventCreator.legacyMigration,
          originConversationId: 'group-legacy',
        ),
      );
    });

    await tester.pumpWidget(app());
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('阿月 → 小明'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('小明 → 阿月'),
      320,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('小明 → 阿月'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('阿月 → 小明（我）'),
      320,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('阿月 → 小明（我）'), findsOneWidget);
    expect(find.textContaining('目标类型：用户'), findsOneWidget);
    expect(find.text('亲密度 42'), findsAtLeastNWidgets(3));
    expect(find.text('信任 -7'), findsAtLeastNWidgets(3));
    expect(find.text('摩擦 13'), findsAtLeastNWidgets(3));
    expect(find.text('熟悉度 86'), findsAtLeastNWidgets(3));
    expect(find.text('当前情绪：温暖'), findsAtLeastNWidgets(3));
    expect(find.text('阶段：朋友'), findsAtLeastNWidgets(3));
    expect(find.textContaining('当前关系备注'), findsAtLeastNWidgets(3));
    expect(find.text('revision 2'), findsAtLeastNWidgets(3));
    expect(find.text('已固定'), findsNothing);
    await tester.scrollUntilVisible(
      find.text('旧版关系诊断'),
      320,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('旧版关系诊断'), findsOneWidget);
  });

  testWidgets(
      'keeps global current relation visible when conversation filter is set',
      (tester) async {
    await tester.runAsync(() async {
      final a = character('a', '阿月');
      final b = character('b', '小明');
      await db.aiCharacterBox.put(a.id, a);
      await db.aiCharacterBox.put(b.id, b);
      final relation = state(
        source: 'a',
        targetType: RelationshipTargetType.ai,
        target: 'b',
      );
      await db.relationshipStateBox.put(relation.id, relation);
      await db.relationshipEventBox.put(
        'event-other-conversation',
        event(
          id: 'event-other-conversation',
          source: 'a',
          target: 'b',
          revision: 2,
          creator: RelationshipEventCreator.automatic,
          originConversationId: 'group-other',
        ),
      );
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseServiceProvider.overrideWithValue(db)],
        child: const MaterialApp(
          home: RelationshipAuditPage(conversationId: 'group-current'),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('阿月 → 小明'), findsOneWidget);
    final conversationSelector = find.byKey(
      const ValueKey('relationship-filter-conversation'),
    );
    expect(conversationSelector, findsOneWidget);
    final conversationDropdown = find.descendant(
      of: conversationSelector,
      matching: find.byType(DropdownButton<String>),
    );
    expect(
      tester.widget<DropdownButton<String>>(conversationDropdown).value,
      'group-current',
    );
  });

  testWidgets('missing observer and target roles use deleted placeholders',
      (tester) async {
    await tester.runAsync(() async {
      final relation = state(
        source: 'deleted-observer',
        targetType: RelationshipTargetType.ai,
        target: 'deleted-target',
      );
      await db.relationshipStateBox.put(relation.id, relation);
    });

    await tester.pumpWidget(app());
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('已删除角色 → 已删除角色'), findsOneWidget);
  });

  testWidgets('deleted observer and target use identity snapshots',
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
          'deleted-target': {
            'name': '快照目标',
            'avatar': '目',
            'age': 28,
            'role': '目标',
          },
        },
      );
      final relation = state(
        source: 'deleted-observer',
        targetType: RelationshipTargetType.ai,
        target: 'deleted-target',
      );
      await db.relationshipStateBox.put(relation.id, relation);
    });

    await tester.pumpWidget(app());
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('快照观察者 → 快照目标'), findsOneWidget);
    expect(find.text('已删除角色 → 已删除角色'), findsNothing);
  });

  testWidgets('timeline sorts by revision and labels every event source',
      (tester) async {
    await tester.runAsync(() async {
      final a = character('a', '阿月');
      final b = character('b', '小明');
      await db.aiCharacterBox.put(a.id, a);
      await db.aiCharacterBox.put(b.id, b);
      final relation = state(
        source: 'a',
        targetType: RelationshipTargetType.ai,
        target: 'b',
        revision: 3,
      );
      await db.relationshipStateBox.put(relation.id, relation);
      for (final record in [
        (
          'timeline-1',
          1,
          RelationshipEventCreator.automatic,
        ),
        (
          'timeline-3',
          3,
          RelationshipEventCreator.legacyMigration,
        ),
        (
          'timeline-2',
          2,
          RelationshipEventCreator.manual,
        ),
      ]) {
        await db.relationshipEventBox.put(
          record.$1,
          event(
            id: record.$1,
            source: 'a',
            target: 'b',
            revision: record.$2,
            creator: record.$3,
          ),
        );
      }
    });

    await tester.pumpWidget(app());
    await tester.pump(const Duration(milliseconds: 200));
    await tester.ensureVisible(find.text('原因：事件 1'));
    expect(find.text('来源：自动'), findsOneWidget);
    expect(find.text('来源：人工'), findsOneWidget);
    expect(find.text('来源：旧版迁移'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('原因：事件 3')).dy,
      lessThan(tester.getTopLeft(find.text('原因：事件 2')).dy),
    );
    expect(
      tester.getTopLeft(find.text('原因：事件 2')).dy,
      lessThan(tester.getTopLeft(find.text('原因：事件 1')).dy),
    );
  });

  test('filter applies observer, target type, target AI, stage and pin', () {
    final values = [
      state(
        source: 'a',
        targetType: RelationshipTargetType.ai,
        target: 'b',
        stage: RelationshipStage.friend,
      ),
      state(
        source: 'b',
        targetType: RelationshipTargetType.user,
        target: 'user',
        stage: RelationshipStage.romantic,
      ),
    ];
    const filter = RelationshipAuditFilter(
      observerCharacterId: 'b',
      targetType: RelationshipTargetType.user,
      stage: RelationshipStage.romantic,
      pinnedOnly: false,
    );
    expect(filter.apply(values, isPinned: (_) => false), [values.last]);

    final targetFilter = filter.copyWith(
      clearObserverCharacterId: true,
      clearTargetType: true,
      clearStage: true,
      clearPinnedOnly: true,
      targetAiId: 'b',
    );
    expect(
      targetFilter.apply(values, isPinned: (_) => false),
      [values.first],
    );
  });

  testWidgets('switching target type clears an incompatible target AI filter',
      (tester) async {
    var current = const RelationshipAuditFilter();
    final a = character('a', '阿月');
    final b = character('b', '小明');
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) => MaterialApp(
          home: Scaffold(
            body: RelationshipAuditFilterWidget(
              filter: current,
              characters: [a, b],
              originConversations: const {},
              onChanged: (next) => setState(() => current = next),
            ),
          ),
        ),
      ),
    );

    final targetAiDropdown = find.descendant(
      of: find.byKey(const ValueKey('relationship-filter-target-ai')),
      matching: find.byType(DropdownButton<String>),
    );
    await tester.tap(targetAiDropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('小明').last);
    await tester.pump();
    expect(current.targetType, RelationshipTargetType.ai);
    expect(current.targetAiId, 'b');

    final targetTypeDropdown = find.descendant(
      of: find.byKey(const ValueKey('relationship-filter-target-type')),
      matching: find.byType(DropdownButton<String>),
    );
    await tester.tap(targetTypeDropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('用户').last);
    await tester.pump();

    expect(current.targetType, RelationshipTargetType.user);
    expect(current.targetAiId, isNull);

    await tester.tap(targetAiDropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('小明').last);
    await tester.pump();
    await tester.tap(targetTypeDropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部目标').last);
    await tester.pump();

    expect(current.targetType, isNull);
    expect(current.targetAiId, isNull);
  });

  testWidgets('source trace uses real message group and degrades safely',
      (tester) async {
    await tester.runAsync(() async {
      final a = character('a', '阿月');
      await db.aiCharacterBox.put(a.id, a);
      await db.chatGroupBox.put(
        'real-group',
        ChatGroup(
          id: 'real-group',
          name: '真实群聊',
          theme: '测试',
          aiCharacterIds: [a.id],
        ),
      );
      final relation = state(
        source: 'a',
        targetType: RelationshipTargetType.user,
        target: 'user',
      );
      await db.relationshipStateBox.put(relation.id, relation);
      await db.messageBox.put(
        'source-message',
        Message(
          id: 'source-message',
          groupId: 'real-group',
          senderId: 'user',
          senderType: 'user',
          content: '真实来源',
        ),
      );
      await db.relationshipEventBox.put(
        'source-event',
        event(
          id: 'source-event',
          source: 'a',
          targetType: RelationshipTargetType.user,
          target: 'user',
          revision: 2,
          creator: RelationshipEventCreator.automatic,
          originConversationId: 'wrong-conversation',
          sourceMessageIds: const ['source-message'],
        ),
      );
    });
    final navigatorObserver = _RecordingNavigatorObserver();
    await tester.pumpWidget(app(navigatorObserver: navigatorObserver));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.ensureVisible(find.text('查看原消息'));
    await tester.pump();
    final sourceTapTarget = find.ancestor(
      of: find.text('查看原消息'),
      matching: find.byType(InkWell),
    );
    expect(sourceTapTarget, findsOneWidget);
    tester.widget<InkWell>(sourceTapTarget).onTap!.call();

    expect(navigatorObserver.pushedRoutes, hasLength(2));
    final sourceRoute =
        navigatorObserver.pushedRoutes.last as MaterialPageRoute<dynamic>;
    final destination = sourceRoute.builder(
      tester.element(find.byType(RelationshipAuditPage)),
    );
    expect(destination, isA<ChatRoomPage>());
    final chatRoom = destination as ChatRoomPage;
    expect(chatRoom.groupId, 'real-group');
    expect(chatRoom.initialMessageId, 'source-message');

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('missing source message disables trace and preserves snapshot',
      (tester) async {
    await tester.runAsync(() async {
      final a = character('a', '阿月');
      await db.aiCharacterBox.put(a.id, a);
      final relation = state(
        source: 'a',
        targetType: RelationshipTargetType.user,
        target: 'user',
      );
      await db.relationshipStateBox.put(relation.id, relation);
      await db.relationshipEventBox.put(
        'missing-source-event',
        event(
          id: 'missing-source-event',
          source: 'a',
          targetType: RelationshipTargetType.user,
          target: 'user',
          revision: 2,
          creator: RelationshipEventCreator.automatic,
          originConversationId: 'deleted-group',
          originNameSnapshot: '删除前来源群聊',
          sourceMessageIds: const ['missing-source-message'],
        ),
      );
      await db.messageBox.put(
        'orphan-source-message',
        Message(
          id: 'orphan-source-message',
          groupId: 'deleted-group',
          senderId: 'user',
          senderType: 'user',
          content: '群聊已删除',
        ),
      );
      await db.relationshipEventBox.put(
        'missing-group-event',
        event(
          id: 'missing-group-event',
          source: 'a',
          targetType: RelationshipTargetType.user,
          target: 'user',
          revision: 3,
          creator: RelationshipEventCreator.automatic,
          originConversationId: 'deleted-group',
          originNameSnapshot: '已删除来源群聊',
          sourceMessageIds: const ['orphan-source-message'],
        ),
      );
    });

    await tester.pumpWidget(app());
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('原消息已不可用（删除前来源群聊）'), findsOneWidget);
    expect(find.text('原消息已不可用（已删除来源群聊）'), findsOneWidget);
    expect(find.text('查看原消息'), findsNothing);
  });

  testWidgets('manual save failure keeps the edit dialog and input',
      (tester) async {
    final initial = state(
      source: 'a',
      targetType: RelationshipTargetType.user,
      target: 'user',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: RelationshipEditDialog(
          relationship: initial,
          onSave: (_) async => throw StateError('写入失败'),
        ),
      ),
    );
    final notesField = find.byWidgetPredicate(
      (widget) => widget is TextField && widget.decoration?.labelText == '关系备注',
    );
    await tester.enterText(notesField, '保留中的编辑');
    await tester.tap(find.byKey(const ValueKey('relationship-edit-save')));
    await tester.pump();

    expect(find.byType(RelationshipEditDialog), findsOneWidget);
    expect(find.textContaining('保存失败'), findsOneWidget);
    expect(
      tester.widget<TextField>(notesField).controller!.text,
      '保留中的编辑',
    );
  });

  testWidgets('romantic edit requires confirmation before saving',
      (tester) async {
    final initial = state(
      source: 'a',
      targetType: RelationshipTargetType.user,
      target: 'user',
      stage: RelationshipStage.friend,
    );
    RelationshipEditValues? savedValues;
    await tester.pumpWidget(
      MaterialApp(
        home: RelationshipEditDialog(
          relationship: initial,
          onSave: (values) async => savedValues = values,
        ),
      ),
    );

    final stageDropdown = find.byType(DropdownButton<RelationshipStage>);
    await tester.tap(stageDropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('romantic').last);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('relationship-edit-save')));
    await tester.pumpAndSettle();

    expect(find.text('确认 romantic 关系'), findsOneWidget);
    expect(savedValues, isNull);
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    expect(savedValues, isNull);
    expect(find.byType(RelationshipEditDialog), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('relationship-edit-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认保存'));
    await tester.pumpAndSettle();

    expect(savedValues?.stage, RelationshipStage.romantic);
    expect(find.byType(RelationshipEditDialog), findsNothing);
  });

  testWidgets('delete confirmation cancellation keeps relationship data',
      (tester) async {
    await tester.runAsync(() async {
      final a = character('a', '阿月');
      final b = character('b', '小明');
      await db.aiCharacterBox.put(a.id, a);
      await db.aiCharacterBox.put(b.id, b);
      final relation = state(
        source: 'a',
        targetType: RelationshipTargetType.ai,
        target: 'b',
      );
      await db.relationshipStateBox.put(relation.id, relation);
      await db.relationshipEventBox.put(
        'delete-cancel-event',
        event(
          id: 'delete-cancel-event',
          source: 'a',
          target: 'b',
          revision: 2,
          creator: RelationshipEventCreator.manual,
        ),
      );
    });

    await tester.pumpWidget(app());
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.byTooltip('关系操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除关系及历史'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('继续'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pump();

    expect(
      db.relationshipStateBox.get(
        RelationshipState.stableGlobalId(
          'a',
          RelationshipTargetType.ai,
          'b',
        ),
      ),
      isNotNull,
    );
    expect(db.relationshipEventBox.get('delete-cancel-event'), isNotNull);
  });

  testWidgets('empty source evidence never fabricates a trace action',
      (tester) async {
    await tester.runAsync(() async {
      final a = character('a', '阿月');
      await db.aiCharacterBox.put(a.id, a);
      final relation = state(
        source: 'a',
        targetType: RelationshipTargetType.user,
        target: 'user',
      );
      await db.relationshipStateBox.put(relation.id, relation);
      await db.relationshipEventBox.put(
        'manual-no-source',
        event(
          id: 'manual-no-source',
          source: 'a',
          targetType: RelationshipTargetType.user,
          target: 'user',
          revision: 2,
          creator: RelationshipEventCreator.manual,
          originConversationId: null,
          originNameSnapshot: '人工编辑',
        ),
      );
    });

    await tester.pumpWidget(app());
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('人工编辑，无原始消息证据'), findsOneWidget);
    expect(find.text('查看原消息'), findsNothing);
  });
}

class _RecordingNavigatorObserver extends NavigatorObserver {
  final List<Route<dynamic>> pushedRoutes = [];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushedRoutes.add(route);
    super.didPush(route, previousRoute);
  }
}

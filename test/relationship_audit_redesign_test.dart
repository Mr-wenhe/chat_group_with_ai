import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/core/models/user_profile.dart';
import 'package:chat_group/features/memory/relationship_audit_detail_page.dart';
import 'package:chat_group/features/memory/relationship_audit_page.dart';
import 'package:chat_group/features/memory/relationship_private_detail_page.dart';
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

  AICharacter character(String id, String name) => AICharacter(
        id: id,
        name: name,
        avatar: name.substring(0, 1),
        age: 25,
        role: '测试角色',
        personalityTags: const [],
        systemPrompt: 'test',
        apiKey: '',
        apiProvider: '',
      );

  RelationshipState relationship({
    required String source,
    required RelationshipTargetType targetType,
    required String target,
  }) =>
      RelationshipState.global(
        sourceCharacterId: source,
        targetType: targetType,
        targetId: target,
        affinity: -24,
        trust: 42,
        friction: 8,
        familiarity: 66,
        recentMood: RelationshipMood.warm,
        stage: RelationshipStage.friend,
        notes: '本地备注',
        updatedAt: DateTime(2026, 8, 17, 12),
      );

  Widget app(Widget home, {NavigatorObserver? observer}) => ProviderScope(
        overrides: [databaseServiceProvider.overrideWithValue(db)],
        child: MaterialApp(
          navigatorObservers: [if (observer != null) observer],
          home: home,
        ),
      );

  testWidgets('list opens an independent full detail page', (tester) async {
    final observer = character('observer', '周明');
    final relation = relationship(
      source: observer.id,
      targetType: RelationshipTargetType.user,
      target: 'user',
    );
    await tester.runAsync(() async {
      await db.aiCharacterBox.put(observer.id, observer);
      await db.userProfileBox.put(
        'me',
        UserProfile(
          displayName: '小明',
          preferredAddress: '你',
          avatar: '',
          bio: '',
        ),
      );
      await db.relationshipStateBox.put(relation.id, relation);
    });

    await tester.pumpWidget(app(const RelationshipAuditPage()));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('全局关系审计'), findsOneWidget);
    expect(find.text('小明'), findsOneWidget);
    expect(find.text('朋友'), findsOneWidget);
    expect(find.text('亲密度'), findsNothing);

    final row = find.byKey(ValueKey('relationship-row-${relation.id}'));
    await tester.ensureVisible(row);
    final inkWell = find.descendant(of: row, matching: find.byType(InkWell));
    tester.widget<InkWell>(inkWell).onTap!.call();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(RelationshipAuditDetailPage), findsOneWidget);
    expect(find.text('当前关系概览'), findsOneWidget);
    expect(find.text('-24'), findsOneWidget);
  });

  testWidgets('group scope limits observers without clipping global targets',
      (tester) async {
    final inGroup = character('in-group', '群内观察者');
    final outside = character('outside', '群外观察者');
    final target = character('target', '全局目标');
    final visible = relationship(
      source: inGroup.id,
      targetType: RelationshipTargetType.ai,
      target: target.id,
    );
    final hidden = relationship(
      source: outside.id,
      targetType: RelationshipTargetType.ai,
      target: target.id,
    );
    await tester.runAsync(() async {
      for (final value in [inGroup, outside, target]) {
        await db.aiCharacterBox.put(value.id, value);
      }
      await db.relationshipStateBox.put(visible.id, visible);
      await db.relationshipStateBox.put(hidden.id, hidden);
    });

    await tester.pumpWidget(
      app(
        RelationshipAuditPage(
          conversationId: 'group-1',
          conversationName: '狼人杀',
          allowedObserverCharacterIds: {inGroup.id},
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    expect(
        find.byKey(ValueKey('relationship-row-${visible.id}')), findsOneWidget);
    expect(find.byKey(ValueKey('relationship-row-${hidden.id}')), findsNothing);
    expect(find.text('事件来源已锁定'), findsOneWidget);
    expect(find.text('全局目标'), findsOneWidget);
  });

  testWidgets('private detail stays read-only and shows empty state',
      (tester) async {
    final observer = character('observer', '周明');
    await tester.runAsync(() async {
      await db.aiCharacterBox.put(observer.id, observer);
    });

    await tester.pumpWidget(
      app(RelationshipPrivateDetailPage(characterId: observer.id)),
    );
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('周明对我的关系'), findsOneWidget);
    expect(find.text('只读'), findsOneWidget);
    expect(find.text('尚未形成可展示的关系'), findsOneWidget);
    expect(find.text('亲密度'), findsNothing);
    expect(find.byType(PopupMenuButton), findsNothing);
  });

  testWidgets('private detail fixes the AI to user direction', (tester) async {
    final observer = character('observer', '周明');
    final relation = relationship(
      source: observer.id,
      targetType: RelationshipTargetType.user,
      target: 'user',
    );
    await tester.runAsync(() async {
      await db.aiCharacterBox.put(observer.id, observer);
      await db.relationshipStateBox.put(relation.id, relation);
    });

    await tester.pumpWidget(
      app(RelationshipPrivateDetailPage(characterId: observer.id)),
    );
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('周明'), findsOneWidget);
    expect(find.text('我'), findsAtLeastNWidgets(1));
    expect(find.text('关系摘要'), findsOneWidget);
    expect(find.text('编辑关系'), findsNothing);
    expect(find.text('前往完整关系审计'), findsOneWidget);
  });

  testWidgets('relationship detail avoids narrow-screen overflow',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final observer = character('observer', '这是一个很长的角色名称');
    final relation = relationship(
      source: observer.id,
      targetType: RelationshipTargetType.user,
      target: 'user',
    );
    await tester.runAsync(() async {
      await db.aiCharacterBox.put(observer.id, observer);
      await db.relationshipStateBox.put(relation.id, relation);
    });

    await tester.pumpWidget(
      app(RelationshipPrivateDetailPage(characterId: observer.id)),
    );
    await tester.pump(const Duration(milliseconds: 200));

    expect(tester.takeException(), isNull);
    expect(find.text('关系摘要'), findsOneWidget);
  });
}

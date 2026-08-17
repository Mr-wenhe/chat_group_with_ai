import 'package:chat_group/core/models/relationship_event.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/features/memory/relationship_audit_presenter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  RelationshipState relation({
    required String id,
    required RelationshipStage stage,
    DateTime? updatedAt,
  }) =>
      RelationshipState.global(
        id: id,
        sourceCharacterId: 'source',
        targetType: RelationshipTargetType.ai,
        targetId: id,
        stage: stage,
        updatedAt: updatedAt ?? DateTime(2026, 8, 1),
      );

  RelationshipEvent event({
    int familiarityBefore = 1,
    int familiarityAfter = 2,
    int trustBefore = 0,
    int trustAfter = 0,
  }) =>
      RelationshipEvent(
        sourceCharacterId: 'source',
        targetType: RelationshipTargetType.user,
        targetId: 'user',
        reason: '测试事件',
        affinityBefore: 0,
        affinityAfter: 0,
        trustBefore: trustBefore,
        trustAfter: trustAfter,
        frictionBefore: 0,
        frictionAfter: 0,
        familiarityBefore: familiarityBefore,
        familiarityAfter: familiarityAfter,
        moodBefore: RelationshipMood.neutral,
        moodAfter: RelationshipMood.neutral,
        stageBefore: RelationshipStage.acquaintance,
        stageAfter: RelationshipStage.acquaintance,
        originConversationId: 'group-1',
        originNameSnapshot: '狼人杀',
        revision: 1,
        createdBy: RelationshipEventCreator.automatic,
      );

  test('groups relationship stages and sorts pinned before recency', () {
    final values = [
      relation(
        id: 'old-pinned',
        stage: RelationshipStage.friend,
        updatedAt: DateTime(2026, 8, 1),
      ),
      relation(
        id: 'new-normal',
        stage: RelationshipStage.acquaintance,
        updatedAt: DateTime(2026, 8, 3),
      ),
      relation(
        id: 'new-pinned',
        stage: RelationshipStage.friend,
        updatedAt: DateTime(2026, 8, 2),
      ),
    ];
    final sections = RelationshipAuditPresenter.sections(
      values,
      isPinned: (value) => value.id.endsWith('pinned'),
    );

    expect(sections.map((section) => section.title), ['亲近关系', '普通关系']);
    expect(
      sections.first.relationships.map((value) => value.id),
      ['new-pinned', 'old-pinned'],
    );
  });

  test('sorts a pinned relationship ahead of a newer unpinned relationship',
      () {
    final sections = RelationshipAuditPresenter.sections(
      [
        relation(
          id: 'new-unpinned',
          stage: RelationshipStage.friend,
          updatedAt: DateTime(2026, 8, 3),
        ),
        relation(
          id: 'old-pinned',
          stage: RelationshipStage.friend,
          updatedAt: DateTime(2026, 8, 1),
        ),
      ],
      isPinned: (value) => value.id == 'old-pinned',
    );

    expect(
      sections.single.relationships.map((value) => value.id),
      ['old-pinned', 'new-unpinned'],
    );
  });

  test('search projection excludes technical identifiers', () {
    final value = relation(
      id: 'technical-only',
      stage: RelationshipStage.friend,
    );
    expect(
      RelationshipAuditPresenter.matchesSearch(
        value,
        observerName: '周明',
        observerRole: '分析师',
        targetName: '我',
        targetRole: '用户',
        query: '分析师',
      ),
      isTrue,
    );
    expect(
      RelationshipAuditPresenter.matchesSearch(
        value,
        observerName: '周明',
        observerRole: '分析师',
        targetName: '我',
        targetRole: '用户',
        query: 'technical-only',
      ),
      isFalse,
    );
  });

  test('recent change summary is deterministic and directional', () {
    expect(
      RelationshipAuditPresenter.recentChangeSummary([event()]),
      '熟悉度提升 · 来自狼人杀',
    );
    expect(
      RelationshipAuditPresenter.recentChangeSummary([
        event(
          familiarityAfter: 1,
          trustAfter: 2,
        ),
      ]),
      '信任提升 · 来自狼人杀',
    );
    expect(
      RelationshipAuditPresenter.recentChangeSummary(const []),
      '当前来源暂无关系事件',
    );
  });
}

import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/relationship_event.dart';
import 'package:chat_group/core/models/relationship_state.dart';

enum RelationshipTargetQuickFilter { all, user, ai }

class RelationshipAuditSection {
  final String title;
  final List<RelationshipState> relationships;

  const RelationshipAuditSection(this.title, this.relationships);
}

/// Pure display rules shared by the list and detail surfaces.
class RelationshipAuditPresenter {
  const RelationshipAuditPresenter._();

  static String stageLabel(RelationshipStage stage) => switch (stage) {
        RelationshipStage.stranger => '陌生人',
        RelationshipStage.acquaintance => '认识',
        RelationshipStage.friend => '朋友',
        RelationshipStage.closeFriend => '密友',
        RelationshipStage.romantic => '浪漫关系',
        RelationshipStage.strained => '紧张',
        RelationshipStage.hostile => '敌对',
      };

  static String moodLabel(RelationshipMood mood) => switch (mood) {
        RelationshipMood.neutral => '中性',
        RelationshipMood.warm => '温暖',
        RelationshipMood.annoyed => '恼怒',
        RelationshipMood.awkward => '尴尬',
        RelationshipMood.protective => '保护',
        RelationshipMood.cold => '冷淡',
      };

  static String targetTypeLabel(RelationshipTargetType type) => switch (type) {
        RelationshipTargetType.ai => 'AI',
        RelationshipTargetType.user => '用户',
      };

  static String roleLabel(AICharacter? character) {
    final role = character?.role.trim() ?? '';
    return role.isEmpty ? '未设置职业' : role;
  }

  static String displayName(AICharacter? character, String id) {
    final name = character?.name.trim() ?? '';
    return name.isEmpty ? '已删除角色' : name;
  }

  static String avatar(AICharacter? character, String fallback) {
    final value = character?.avatar.trim() ?? '';
    if (value.isNotEmpty) return value;
    final name = character?.name.trim() ?? '';
    return name.isEmpty ? fallback : name.substring(0, 1);
  }

  static List<RelationshipAuditSection> sections(
    Iterable<RelationshipState> relationships, {
    required bool Function(RelationshipState relationship) isPinned,
  }) {
    final grouped = <String, List<RelationshipState>>{
      '亲近关系': [],
      '普通关系': [],
      '紧张关系': [],
    };
    for (final relationship in relationships) {
      grouped[_sectionTitle(relationship.stage)]!.add(relationship);
    }
    for (final values in grouped.values) {
      values.sort((left, right) {
        final pinned = _rank(isPinned(left)).compareTo(_rank(isPinned(right)));
        if (pinned != 0) return pinned;
        final updated = right.updatedAt.compareTo(left.updatedAt);
        if (updated != 0) return updated;
        return left.id.compareTo(right.id);
      });
    }
    return [
      for (final entry in grouped.entries)
        if (entry.value.isNotEmpty)
          RelationshipAuditSection(entry.key, List.unmodifiable(entry.value)),
    ];
  }

  static bool matchesSearch(
    RelationshipState relationship, {
    required String observerName,
    required String observerRole,
    required String targetName,
    required String targetRole,
    String? query,
  }) {
    final normalized = query?.trim().toLowerCase() ?? '';
    if (normalized.isEmpty) return true;
    final projection = [
      observerName,
      observerRole,
      targetName,
      targetRole,
      stageLabel(relationship.stage),
      moodLabel(relationship.recentMood),
      relationship.notes,
    ].join(' ');
    return projection.toLowerCase().contains(normalized);
  }

  static String recentChangeSummary(
    List<RelationshipEvent> events, {
    String emptyLabel = '当前来源暂无关系事件',
  }) {
    if (events.isEmpty) return emptyLabel;
    final event = events.first;
    final source = sourceLabel(event);
    final numeric = _numericChanges(event);
    final onlyFamiliarity = numeric.length == 1 && numeric.first == '熟悉度';
    if (onlyFamiliarity) {
      final direction =
          event.familiarityAfter > event.familiarityBefore ? '提升' : '下降';
      return '熟悉度$direction · 来自$source';
    }
    if (event.stageAfter != event.stageBefore) {
      return '关系阶段更新 · 来自$source';
    }
    if (event.trustAfter > event.trustBefore) {
      return '信任提升 · 来自$source';
    }
    if (event.frictionAfter > event.frictionBefore) {
      return '摩擦增加 · 来自$source';
    }
    if (event.affinityAfter != event.affinityBefore) {
      return '亲密度变化 · 来自$source';
    }
    if (event.trustAfter != event.trustBefore) {
      return '信任变化 · 来自$source';
    }
    if (event.frictionAfter != event.frictionBefore) {
      return '摩擦减少 · 来自$source';
    }
    if (event.moodAfter != event.moodBefore) {
      return '情绪变化 · 来自$source';
    }
    return '关系状态更新 · 来自$source';
  }

  static String sourceLabel(RelationshipEvent event) {
    final snapshot = event.originNameSnapshot.trim();
    if (snapshot.isNotEmpty) return snapshot;
    final conversationId = event.originConversationId?.trim() ?? '';
    if (conversationId.startsWith('dm:')) return '私聊';
    if (conversationId.isNotEmpty) return conversationId;
    return switch (event.createdBy) {
      RelationshipEventCreator.manual => '人工编辑',
      RelationshipEventCreator.automatic => '自动记录',
      RelationshipEventCreator.legacyMigration => '旧版迁移',
    };
  }

  static String creatorLabel(RelationshipEventCreator creator) =>
      switch (creator) {
        RelationshipEventCreator.automatic => '自动',
        RelationshipEventCreator.manual => '人工',
        RelationshipEventCreator.legacyMigration => '旧版迁移',
      };

  static List<String> changedMetricNames(RelationshipEvent event) {
    return [
      if (event.affinityAfter != event.affinityBefore) '亲密度',
      if (event.trustAfter != event.trustBefore) '信任',
      if (event.frictionAfter != event.frictionBefore) '摩擦',
      if (event.familiarityAfter != event.familiarityBefore) '熟悉度',
    ];
  }

  static String _sectionTitle(RelationshipStage stage) => switch (stage) {
        RelationshipStage.friend ||
        RelationshipStage.closeFriend ||
        RelationshipStage.romantic =>
          '亲近关系',
        RelationshipStage.stranger || RelationshipStage.acquaintance => '普通关系',
        RelationshipStage.strained || RelationshipStage.hostile => '紧张关系',
      };

  static List<String> _numericChanges(RelationshipEvent event) => [
        if (event.affinityAfter != event.affinityBefore) '亲密度',
        if (event.trustAfter != event.trustBefore) '信任',
        if (event.frictionAfter != event.frictionBefore) '摩擦',
        if (event.familiarityAfter != event.familiarityBefore) '熟悉度',
      ];

  static int _rank(bool value) => value ? 0 : 1;
}

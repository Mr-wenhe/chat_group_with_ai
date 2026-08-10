import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/relationship_event.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

enum RelationshipAuditAction { edit, reset, delete }

class RelationshipAuditCard extends StatelessWidget {
  final RelationshipState relationship;
  final String observerName;
  final String targetName;
  final List<RelationshipEvent> events;
  final bool pinned;
  final Map<String, Message> sourceMessagesById;
  final bool Function(Message message) canOpenSource;
  final VoidCallback onEdit;
  final VoidCallback onReset;
  final VoidCallback onDelete;
  final VoidCallback onPin;
  final VoidCallback onUnpin;
  final ValueChanged<Message> onOpenSource;

  const RelationshipAuditCard({
    super.key,
    required this.relationship,
    required this.observerName,
    required this.targetName,
    required this.events,
    required this.pinned,
    required this.sourceMessagesById,
    required this.canOpenSource,
    required this.onEdit,
    required this.onReset,
    required this.onDelete,
    required this.onPin,
    required this.onUnpin,
    required this.onOpenSource,
  });

  @override
  Widget build(BuildContext context) {
    final targetLabel = relationship.targetType == RelationshipTargetType.user
        ? targetName == '我'
            ? '我'
            : '$targetName（我）'
        : targetName;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: ExpansionTile(
        initiallyExpanded: true,
        tilePadding: const EdgeInsets.fromLTRB(14, 6, 8, 6),
        childrenPadding: EdgeInsets.zero,
        title: Text(
          '$observerName → $targetLabel',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Text(
          '目标类型：${_targetTypeLabel(relationship.targetType)} · '
          'revision ${relationship.revision}',
        ),
        trailing: _actions(context),
        children: [
          _CurrentSnapshot(
            relationship: relationship,
            pinned: pinned,
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
            child: Row(
              children: [
                const Icon(Icons.timeline_rounded, size: 18),
                const SizedBox(width: 6),
                Text(
                  '事件时间线（${events.length}）',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
          if (events.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(14, 4, 14, 14),
              child: Text('暂无该筛选条件下的关系事件'),
            )
          else
            for (final event in events)
              _RelationshipEventTile(
                event: event,
                sourceMessagesById: sourceMessagesById,
                canOpenSource: canOpenSource,
                onOpenSource: onOpenSource,
              ),
        ],
      ),
    );
  }

  Widget _actions(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: pinned ? '取消固定关系' : '固定关系',
          icon: Icon(
            pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
            size: 18,
            color: pinned ? Colors.orange : null,
          ),
          onPressed: pinned ? onUnpin : onPin,
        ),
        PopupMenuButton<RelationshipAuditAction>(
          tooltip: '关系操作',
          onSelected: (action) {
            switch (action) {
              case RelationshipAuditAction.edit:
                onEdit();
              case RelationshipAuditAction.reset:
                onReset();
              case RelationshipAuditAction.delete:
                onDelete();
            }
          },
          itemBuilder: (context) => const [
            PopupMenuItem(
              value: RelationshipAuditAction.edit,
              child: ListTile(
                leading: Icon(Icons.edit_outlined),
                title: Text('编辑关系'),
                contentPadding: EdgeInsets.zero,
              ),
            ),
            PopupMenuItem(
              value: RelationshipAuditAction.reset,
              child: ListTile(
                leading: Icon(Icons.restart_alt_rounded),
                title: Text('重置关系'),
                contentPadding: EdgeInsets.zero,
              ),
            ),
            PopupMenuItem(
              value: RelationshipAuditAction.delete,
              child: ListTile(
                leading: Icon(Icons.delete_outline, color: Colors.red),
                title: Text('删除关系及历史'),
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ],
        ),
        const Icon(Icons.expand_more_rounded),
      ],
    );
  }

  static String _targetTypeLabel(RelationshipTargetType type) => switch (type) {
        RelationshipTargetType.ai => 'AI',
        RelationshipTargetType.user => '用户',
      };
}

class _CurrentSnapshot extends StatelessWidget {
  final RelationshipState relationship;
  final bool pinned;

  const _CurrentSnapshot({
    required this.relationship,
    required this.pinned,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 5,
            children: [
              Text('亲密度 ${relationship.affinity}'),
              Text('信任 ${relationship.trust}'),
              Text('摩擦 ${relationship.friction}'),
              Text('熟悉度 ${relationship.familiarity}'),
              Text('当前情绪：${_moodLabel(relationship.recentMood)}'),
              Text('阶段：${_stageLabel(relationship.stage)}'),
              Text('revision ${relationship.revision}'),
              Text(pinned ? '已固定' : '未固定'),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '关系备注：${relationship.notes.trim().isEmpty ? '（空）' : relationship.notes}',
          ),
          const SizedBox(height: 5),
          Text('最近更新时间：${_format(relationship.updatedAt)}'),
          Text('最近互动时间：${_format(relationship.lastInteractionAt)}'),
          Text('最新事件：${relationship.lastEventId ?? '暂无事件'}'),
        ],
      ),
    );
  }

  static String _format(DateTime value) =>
      DateFormat('yyyy-MM-dd HH:mm').format(value.toLocal());

  static String _moodLabel(RelationshipMood mood) => switch (mood) {
        RelationshipMood.neutral => '中性',
        RelationshipMood.warm => '温暖',
        RelationshipMood.annoyed => '恼怒',
        RelationshipMood.awkward => '尴尬',
        RelationshipMood.protective => '保护',
        RelationshipMood.cold => '冷淡',
      };

  static String _stageLabel(RelationshipStage stage) => switch (stage) {
        RelationshipStage.stranger => '陌生人',
        RelationshipStage.acquaintance => '认识',
        RelationshipStage.friend => '朋友',
        RelationshipStage.closeFriend => '密友',
        RelationshipStage.romantic => 'romantic',
        RelationshipStage.strained => '紧张',
        RelationshipStage.hostile => '敌对',
      };
}

class _RelationshipEventTile extends StatelessWidget {
  final RelationshipEvent event;
  final Map<String, Message> sourceMessagesById;
  final bool Function(Message message) canOpenSource;
  final ValueChanged<Message> onOpenSource;

  const _RelationshipEventTile({
    required this.event,
    required this.sourceMessagesById,
    required this.canOpenSource,
    required this.onOpenSource,
  });

  @override
  Widget build(BuildContext context) {
    final sourceMessage = _firstSourceMessage();
    final sourceAvailable =
        sourceMessage != null && canOpenSource(sourceMessage);
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 4, 14, 10),
      padding: const EdgeInsets.fromLTRB(10, 9, 10, 9),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 4,
            children: [
              Text('revision ${event.revision}',
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              Text(_format(event.occurredAt)),
              Text(_creatorLabel(event.createdBy)),
              Text('置信度 ${event.confidence.toStringAsFixed(2)}'),
            ],
          ),
          const SizedBox(height: 5),
          Text('原因：${event.reason}'),
          const SizedBox(height: 4),
          Wrap(
            spacing: 10,
            runSpacing: 4,
            children: [
              Text('亲密度 ${event.affinityBefore} → ${event.affinityAfter}'),
              Text('信任 ${event.trustBefore} → ${event.trustAfter}'),
              Text('摩擦 ${event.frictionBefore} → ${event.frictionAfter}'),
              Text(
                  '熟悉度 ${event.familiarityBefore} → ${event.familiarityAfter}'),
              Text(
                  '情绪 ${_moodLabel(event.moodBefore)} → ${_moodLabel(event.moodAfter)}'),
              Text(
                  '阶段 ${_stageLabel(event.stageBefore)} → ${_stageLabel(event.stageAfter)}'),
            ],
          ),
          const SizedBox(height: 5),
          Text('来源快照：${event.originNameSnapshot}'),
          Text('来源场合：${event.originConversationId ?? '无'}'),
          Text('来源消息：${event.sourceMessageIds.length} 条'),
          if (event.notesBefore != event.notesAfter)
            Text('备注：${event.notesBefore} → ${event.notesAfter}'),
          const SizedBox(height: 3),
          if (event.sourceMessageIds.isEmpty)
            Text(
              _emptyEvidenceLabel(event.createdBy),
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            )
          else if (!sourceAvailable)
            Tooltip(
              message: '来源消息或来源场合已不可用',
              child: TextButton.icon(
                onPressed: null,
                icon: const Icon(Icons.link_off_rounded, size: 15),
                label: Text('原消息已不可用（${event.originNameSnapshot}）'),
              ),
            )
          else
            TextButton.icon(
              onPressed: () => onOpenSource(sourceMessage),
              icon: const Icon(Icons.chat_bubble_outline_rounded, size: 15),
              label: const Text('查看原消息'),
            ),
        ],
      ),
    );
  }

  Message? _firstSourceMessage() {
    for (final id in event.sourceMessageIds) {
      final message = sourceMessagesById[id];
      if (message != null) return message;
    }
    return null;
  }

  static String _emptyEvidenceLabel(RelationshipEventCreator creator) =>
      switch (creator) {
        RelationshipEventCreator.manual => '人工编辑，无原始消息证据',
        RelationshipEventCreator.legacyMigration => '旧版迁移记录，无原始消息证据',
        RelationshipEventCreator.automatic => '自动记录，无原始消息证据',
      };

  static String _creatorLabel(RelationshipEventCreator creator) =>
      switch (creator) {
        RelationshipEventCreator.automatic => '来源：自动',
        RelationshipEventCreator.manual => '来源：人工',
        RelationshipEventCreator.legacyMigration => '来源：旧版迁移',
      };

  static String _format(DateTime value) =>
      DateFormat('yyyy-MM-dd HH:mm').format(value.toLocal());

  static String _moodLabel(RelationshipMood mood) => switch (mood) {
        RelationshipMood.neutral => '中性',
        RelationshipMood.warm => '温暖',
        RelationshipMood.annoyed => '恼怒',
        RelationshipMood.awkward => '尴尬',
        RelationshipMood.protective => '保护',
        RelationshipMood.cold => '冷淡',
      };

  static String _stageLabel(RelationshipStage stage) => switch (stage) {
        RelationshipStage.stranger => '陌生人',
        RelationshipStage.acquaintance => '认识',
        RelationshipStage.friend => '朋友',
        RelationshipStage.closeFriend => '密友',
        RelationshipStage.romantic => 'romantic',
        RelationshipStage.strained => '紧张',
        RelationshipStage.hostile => '敌对',
      };
}

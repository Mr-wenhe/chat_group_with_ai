import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/features/memory/relationship_audit_filter.dart';
import 'package:flutter/material.dart';

class RelationshipAuditFilterWidget extends StatelessWidget {
  final RelationshipAuditFilter filter;
  final List<AICharacter> characters;
  final Map<String, String> originConversations;
  final ValueChanged<RelationshipAuditFilter> onChanged;

  const RelationshipAuditFilterWidget({
    super.key,
    required this.filter,
    required this.characters,
    required this.originConversations,
    required this.onChanged,
  });

  static const _all = '__all__';
  static const _allTargetAi = '__all_target_ai__';

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _observerSelector(),
              _targetTypeSelector(),
              _targetAiSelector(),
              _stageSelector(),
              _pinnedSelector(),
              _conversationSelector(),
            ],
          ),
          if (!filter.isEmpty) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _filterChip(
                  label: '观察者：${_observerLabel()}',
                  visible: filter.observerCharacterId != null,
                  onDeleted: () => onChanged(
                    filter.copyWith(clearObserverCharacterId: true),
                  ),
                ),
                _filterChip(
                  label: '目标：${_targetTypeLabel(filter.targetType)}',
                  visible: filter.targetType != null,
                  onDeleted: () => onChanged(
                    filter.copyWith(clearTargetType: true),
                  ),
                ),
                _filterChip(
                  label: '目标 AI：${_targetAiLabel()}',
                  visible: filter.targetAiId != null,
                  onDeleted: () => onChanged(
                    filter.copyWith(clearTargetAiId: true),
                  ),
                ),
                _filterChip(
                  label: '阶段：${_stageLabel(filter.stage)}',
                  visible: filter.stage != null,
                  onDeleted: () => onChanged(
                    filter.copyWith(clearStage: true),
                  ),
                ),
                _filterChip(
                  label: filter.pinnedOnly == true ? '仅固定' : '仅未固定',
                  visible: filter.pinnedOnly != null,
                  onDeleted: () => onChanged(
                    filter.copyWith(clearPinnedOnly: true),
                  ),
                ),
                _filterChip(
                  label: '场合：${filter.originConversationId}',
                  visible: filter.originConversationId != null,
                  onDeleted: () => onChanged(
                    filter.copyWith(clearOriginConversationId: true),
                  ),
                ),
                TextButton.icon(
                  key: const ValueKey('relationship-filter-clear'),
                  onPressed: () => onChanged(const RelationshipAuditFilter()),
                  icon: const Icon(Icons.filter_list_off_rounded, size: 18),
                  label: const Text('清除筛选'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _observerSelector() {
    final selected = filter.observerCharacterId ?? _all;
    return _selector<String>(
      key: const ValueKey('relationship-filter-observer'),
      label: '观察者 AI',
      value: selected,
      items: [
        const (_all, '全部观察者'),
        for (final character in characters) (character.id, character.name),
      ],
      onChanged: (value) => onChanged(
        value == _all
            ? filter.copyWith(clearObserverCharacterId: true)
            : filter.copyWith(observerCharacterId: value),
      ),
    );
  }

  Widget _targetTypeSelector() {
    final selected = filter.targetType?.name ?? _all;
    return _selector<String>(
      key: const ValueKey('relationship-filter-target-type'),
      label: '目标类型',
      value: selected,
      items: const [
        (_all, '全部目标'),
        ('user', '用户'),
        ('ai', 'AI'),
      ],
      onChanged: (value) {
        if (value == _all) {
          onChanged(
            filter.copyWith(
              clearTargetType: true,
              clearTargetAiId: true,
            ),
          );
          return;
        }
        final targetType = RelationshipTargetType.values.firstWhere(
          (type) => type.name == value,
        );
        onChanged(
          targetType == RelationshipTargetType.user
              ? filter.copyWith(
                  targetType: targetType,
                  clearTargetAiId: true,
                )
              : filter.copyWith(targetType: targetType),
        );
      },
    );
  }

  Widget _targetAiSelector() {
    final selected = filter.targetAiId ?? _allTargetAi;
    return _selector<String>(
      key: const ValueKey('relationship-filter-target-ai'),
      label: '目标 AI',
      value: selected,
      items: [
        const (_allTargetAi, '全部目标 AI'),
        for (final character in characters) (character.id, character.name),
      ],
      onChanged: (value) => onChanged(
        value == _allTargetAi
            ? filter.copyWith(clearTargetAiId: true)
            : filter.copyWith(
                targetAiId: value,
                targetType: RelationshipTargetType.ai,
              ),
      ),
    );
  }

  Widget _stageSelector() {
    final selected = filter.stage?.name ?? _all;
    return _selector<String>(
      key: const ValueKey('relationship-filter-stage'),
      label: '关系阶段',
      value: selected,
      items: [
        const (_all, '全部阶段'),
        for (final stage in RelationshipStage.values)
          (stage.name, _stageLabel(stage)),
      ],
      onChanged: (value) => onChanged(
        value == _all
            ? filter.copyWith(clearStage: true)
            : filter.copyWith(
                stage: RelationshipStage.values.firstWhere(
                  (stage) => stage.name == value,
                ),
              ),
      ),
    );
  }

  Widget _pinnedSelector() {
    final selected = filter.pinnedOnly == null
        ? _all
        : filter.pinnedOnly!
            ? 'pinned'
            : 'unpinned';
    return _selector<String>(
      key: const ValueKey('relationship-filter-pinned'),
      label: '固定状态',
      value: selected,
      items: const [
        (_all, '全部关系'),
        ('pinned', '仅固定'),
        ('unpinned', '仅未固定'),
      ],
      onChanged: (value) => onChanged(
        value == _all
            ? filter.copyWith(clearPinnedOnly: true)
            : filter.copyWith(pinnedOnly: value == 'pinned'),
      ),
    );
  }

  Widget _conversationSelector() {
    final selected = filter.originConversationId ?? _all;
    final items = <(String, String)>[
      const (_all, '全部来源场合'),
      for (final entry in originConversations.entries)
        (entry.key, '${entry.value} (${entry.key})'),
    ];
    if (filter.originConversationId != null &&
        !originConversations.containsKey(filter.originConversationId)) {
      items.add(
        (
          filter.originConversationId!,
          '${filter.originConversationId}（来源场合不可用）'
        ),
      );
    }
    return _selector<String>(
      key: const ValueKey('relationship-filter-conversation'),
      label: '事件场合',
      value: selected,
      items: items,
      onChanged: (value) => onChanged(
        value == _all
            ? filter.copyWith(clearOriginConversationId: true)
            : filter.copyWith(originConversationId: value),
      ),
    );
  }

  Widget _selector<T>({
    required Key key,
    required String label,
    required T value,
    required List<(T, String)> items,
    required ValueChanged<T> onChanged,
  }) {
    return InputDecorator(
      key: key,
      decoration: InputDecoration(
        labelText: label,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        isDense: true,
        border: const OutlineInputBorder(),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          isDense: true,
          value: value,
          items: [
            for (final item in items)
              DropdownMenuItem<T>(
                value: item.$1,
                child: Text(item.$2, style: const TextStyle(fontSize: 13)),
              ),
          ],
          onChanged: (next) {
            if (next != null) onChanged(next);
          },
        ),
      ),
    );
  }

  Widget _filterChip({
    required String label,
    required bool visible,
    required VoidCallback onDeleted,
  }) {
    if (!visible) return const SizedBox.shrink();
    return InputChip(label: Text(label), onDeleted: onDeleted);
  }

  String _observerLabel() {
    if (filter.observerCharacterId == null) return '全部';
    return characters
            .where((character) => character.id == filter.observerCharacterId)
            .map((character) => character.name)
            .firstOrNull ??
        '已删除角色';
  }

  String _targetAiLabel() {
    if (filter.targetAiId == null) return '全部';
    return characters
            .where((character) => character.id == filter.targetAiId)
            .map((character) => character.name)
            .firstOrNull ??
        '已删除角色';
  }

  static String _targetTypeLabel(RelationshipTargetType? type) =>
      switch (type) {
        null => '全部',
        RelationshipTargetType.user => '用户',
        RelationshipTargetType.ai => 'AI',
      };

  static String _stageLabel(RelationshipStage? stage) => switch (stage) {
        null => '全部',
        RelationshipStage.stranger => '陌生人',
        RelationshipStage.acquaintance => '认识',
        RelationshipStage.friend => '朋友',
        RelationshipStage.closeFriend => '密友',
        RelationshipStage.romantic => 'romantic',
        RelationshipStage.strained => '紧张',
        RelationshipStage.hostile => '敌对',
      };
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

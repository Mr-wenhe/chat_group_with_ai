import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/features/memory/relationship_audit_filter.dart';
import 'package:chat_group/features/memory/relationship_audit_presenter.dart';
import 'package:flutter/material.dart';

/// Compact browsing controls. The six legacy selectors remain available in a
/// transactional dialog so the first screen stays focused on scanning rows.
class RelationshipAuditFilterWidget extends StatelessWidget {
  final RelationshipAuditFilter filter;
  final List<AICharacter> characters;
  final Map<String, String> originConversations;
  final bool originConversationLocked;
  final bool observerSelectionLocked;
  final ValueChanged<RelationshipAuditFilter> onChanged;

  const RelationshipAuditFilterWidget({
    super.key,
    required this.filter,
    required this.characters,
    required this.originConversations,
    this.originConversationLocked = false,
    this.observerSelectionLocked = false,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final conditionCount = filter.advancedCriterionCount -
        (originConversationLocked && filter.originConversationId != null
            ? 1
            : 0);
    final hasAdvancedCriteria = conditionCount > 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _RelationshipSearchField(
            initialValue: filter.searchQuery ?? '',
            onChanged: (value) => onChanged(
              filter.copyWith(
                searchQuery: value,
                clearSearchQuery: value.trim().isEmpty,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Badge(
                isLabelVisible: conditionCount > 0,
                label: Text('$conditionCount'),
                child: OutlinedButton.icon(
                  key: const ValueKey('open-relationship-filter'),
                  onPressed: () => _showAdvancedFilter(context),
                  icon: const Icon(Icons.tune_rounded, size: 18),
                  label: const Text('筛选'),
                ),
              ),
              if (hasAdvancedCriteria)
                Text(
                  '已设置 $conditionCount 项条件',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              if (hasAdvancedCriteria)
                TextButton(
                  key: const ValueKey('relationship-filter-clear'),
                  onPressed: () => onChanged(filter.clearAdvancedFilters()),
                  child: const Text('清除筛选'),
                ),
            ],
          ),
          if (filter.originConversationId != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                originConversationLocked
                    ? '事件来源已锁定：${_originLabel(filter.originConversationId!)}（仅影响时间线）'
                    : '事件来源：${_originLabel(filter.originConversationId!)}（仅影响时间线）',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 12,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _showAdvancedFilter(BuildContext context) async {
    final dialog = _RelationshipAdvancedFilterDialog(
      filter: filter,
      characters: characters,
      originConversations: originConversations,
      originConversationLocked: originConversationLocked,
      observerSelectionLocked: observerSelectionLocked,
    );
    final isNarrow = MediaQuery.sizeOf(context).width < 600;
    if (!context.mounted) return;
    final Future<RelationshipAuditFilter?> future;
    if (isNarrow) {
      future = showModalBottomSheet<RelationshipAuditFilter>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => dialog,
      );
    } else {
      future = showDialog<RelationshipAuditFilter>(
        context: context,
        builder: (_) => dialog,
      );
    }
    final next = await future;
    if (context.mounted && next != null) onChanged(next);
  }

  String _originLabel(String id) => originConversations[id] ?? id;
}

class _RelationshipSearchField extends StatefulWidget {
  final String initialValue;
  final ValueChanged<String> onChanged;

  const _RelationshipSearchField({
    required this.initialValue,
    required this.onChanged,
  });

  @override
  State<_RelationshipSearchField> createState() =>
      _RelationshipSearchFieldState();
}

class _RelationshipSearchFieldState extends State<_RelationshipSearchField> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialValue);

  @override
  void didUpdateWidget(covariant _RelationshipSearchField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialValue == _controller.text) return;
    _controller.value = TextEditingValue(
      text: widget.initialValue,
      selection: TextSelection.collapsed(offset: widget.initialValue.length),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
        key: const ValueKey('relationship-audit-search'),
        controller: _controller,
        onChanged: widget.onChanged,
        decoration: const InputDecoration(
          labelText: '搜索关系',
          hintText: '搜索目标、职业、阶段、情绪或备注',
          prefixIcon: Icon(Icons.search_rounded),
        ),
      );
}

class _RelationshipAdvancedFilterDialog extends StatefulWidget {
  final RelationshipAuditFilter filter;
  final List<AICharacter> characters;
  final Map<String, String> originConversations;
  final bool originConversationLocked;
  final bool observerSelectionLocked;

  const _RelationshipAdvancedFilterDialog({
    required this.filter,
    required this.characters,
    required this.originConversations,
    required this.originConversationLocked,
    required this.observerSelectionLocked,
  });

  @override
  State<_RelationshipAdvancedFilterDialog> createState() =>
      _RelationshipAdvancedFilterDialogState();
}

class _RelationshipAdvancedFilterDialogState
    extends State<_RelationshipAdvancedFilterDialog> {
  late RelationshipAuditFilter _draft = widget.filter;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('筛选关系'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!widget.observerSelectionLocked) ...[
              _selector<String>(
                key: const ValueKey('relationship-filter-observer'),
                label: '观察者 AI',
                value: _draft.observerCharacterId ?? _all,
                items: [
                  const (_all, '全部观察者'),
                  for (final character in widget.characters)
                    (character.id, character.name),
                ],
                onChanged: (value) => _update(
                  value == _all
                      ? _draft.copyWith(clearObserverCharacterId: true)
                      : _draft.copyWith(observerCharacterId: value),
                ),
              ),
              const SizedBox(height: 12),
            ],
            _selector<String>(
              key: const ValueKey('relationship-filter-target-type'),
              label: '目标类型',
              value: _draft.targetType?.name ?? _all,
              items: const [
                (_all, '全部目标'),
                ('user', '用户'),
                ('ai', 'AI'),
              ],
              onChanged: (value) {
                if (value == _all) {
                  _update(_draft.copyWith(
                    clearTargetType: true,
                    clearTargetAiId: true,
                  ));
                  return;
                }
                final targetType = RelationshipTargetType.values.firstWhere(
                  (type) => type.name == value,
                );
                _update(
                  targetType == RelationshipTargetType.user
                      ? _draft.copyWith(
                          targetType: targetType,
                          clearTargetAiId: true,
                        )
                      : _draft.copyWith(targetType: targetType),
                );
              },
            ),
            const SizedBox(height: 12),
            _selector<String>(
              key: const ValueKey('relationship-filter-target-ai'),
              label: '目标 AI',
              value: _draft.targetAiId ?? _allTargetAi,
              items: [
                const (_allTargetAi, '全部目标 AI'),
                for (final character in widget.characters)
                  (character.id, character.name),
              ],
              onChanged: (value) => _update(
                value == _allTargetAi
                    ? _draft.copyWith(clearTargetAiId: true)
                    : _draft.copyWith(
                        targetAiId: value,
                        targetType: RelationshipTargetType.ai,
                      ),
              ),
            ),
            const SizedBox(height: 12),
            _selector<String>(
              key: const ValueKey('relationship-filter-stage'),
              label: '关系阶段',
              value: _draft.stage?.name ?? _all,
              items: [
                const (_all, '全部阶段'),
                for (final stage in RelationshipStage.values)
                  (stage.name, RelationshipAuditPresenter.stageLabel(stage)),
              ],
              onChanged: (value) => _update(
                value == _all
                    ? _draft.copyWith(clearStage: true)
                    : _draft.copyWith(
                        stage: RelationshipStage.values.firstWhere(
                          (stage) => stage.name == value,
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 12),
            _selector<String>(
              key: const ValueKey('relationship-filter-pinned'),
              label: '固定状态',
              value: _draft.pinnedOnly == null
                  ? _all
                  : _draft.pinnedOnly!
                      ? 'pinned'
                      : 'unpinned',
              items: const [
                (_all, '全部关系'),
                ('pinned', '仅固定'),
                ('unpinned', '仅未固定'),
              ],
              onChanged: (value) => _update(
                value == _all
                    ? _draft.copyWith(clearPinnedOnly: true)
                    : _draft.copyWith(pinnedOnly: value == 'pinned'),
              ),
            ),
            if (!widget.originConversationLocked) ...[
              const SizedBox(height: 12),
              _conversationSelector(),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () =>
              setState(() => _draft = _draft.clearAdvancedFilters()),
          child: const Text('清除高级筛选'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _draft),
          child: const Text('应用'),
        ),
      ],
    );
  }

  static const _all = '__all__';
  static const _allTargetAi = '__all_target_ai__';

  Widget _conversationSelector() {
    final selected = _draft.originConversationId ?? _all;
    final items = <(String, String)>[
      const (_all, '全部来源场合'),
      for (final entry in widget.originConversations.entries)
        (entry.key, entry.value),
    ];
    if (_draft.originConversationId != null &&
        !widget.originConversations.containsKey(_draft.originConversationId)) {
      items.add((_draft.originConversationId!, _draft.originConversationId!));
    }
    return _selector<String>(
      key: const ValueKey('relationship-filter-conversation'),
      label: '事件场合',
      value: selected,
      items: items,
      onChanged: (value) => _update(
        value == _all
            ? _draft.copyWith(clearOriginConversationId: true)
            : _draft.copyWith(originConversationId: value),
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
          isExpanded: true,
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

  void _update(RelationshipAuditFilter next) => setState(() => _draft = next);
}

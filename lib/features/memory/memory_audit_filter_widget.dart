import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/permanent_memory.dart';
import 'package:chat_group/features/memory/memory_audit_filter.dart';
import 'package:flutter/material.dart';

class MemoryAuditFilterWidget extends StatelessWidget {
  static const _all = '__all__';

  final MemoryAuditFilter filter;
  final List<AICharacter> characters;
  final Map<String, String> originConversations;
  final ValueChanged<MemoryAuditFilter> onChanged;

  const MemoryAuditFilterWidget({
    super.key,
    required this.filter,
    required this.characters,
    this.originConversations = const {},
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _originConversationDropdown(context)),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: OutlinedButton.icon(
                  onPressed: () => _showOriginConversationInput(context),
                  icon: const Icon(Icons.edit_location_alt_outlined, size: 16),
                  label: const Text('输入场合'),
                ),
              ),
            ],
          ),
          if (!filter.isEmpty) _activeFilterSummary(),
          _quickFilters(),
          _searchableSelector(
            key: ValueKey('observer-${filter.observerCharacterId}'),
            label: '观察 AI',
            value: filter.observerCharacterId ?? _all,
            entries: [
              const DropdownMenuEntry(value: _all, label: '全部 AI'),
              for (final character in characters)
                DropdownMenuEntry(value: character.id, label: character.name),
            ],
            onSelected: (value) => onChanged(filter.copyWith(
              observerCharacterId: value,
              clearObserverCharacterId: value == _all,
            )),
          ),
          const _HelpText('观察 AI 是拥有这条记忆、会在对话中使用它的角色。'),
          _searchableSelector(
            key: ValueKey('subject-${filter.subjectFilter.characterId}'),
            label: '记忆对象',
            value: filter.subjectFilter.characterId ?? _all,
            entries: [
              const DropdownMenuEntry(value: _all, label: '全部对象'),
              const DropdownMenuEntry(value: '__about_me__', label: '关于我'),
              const DropdownMenuEntry(value: '__self_growth__', label: '自身成长'),
              for (final character in characters)
                DropdownMenuEntry(value: character.id, label: character.name),
            ],
            onSelected: (value) {
              final subject = switch (value) {
                _all => SubjectFilter.all,
                '__about_me__' => SubjectFilter.aboutMe,
                '__self_growth__' => SubjectFilter.selfGrowth,
                _ => SubjectFilter.aboutCharacter(value),
              };
              onChanged(filter.copyWith(subjectFilter: subject));
            },
          ),
          const _HelpText('记忆对象是这条内容所描述的用户、角色或观察 AI 自身。'),
          const _HelpText('来源只说明记忆在哪里形成，不限制它能否跨群聊或私聊使用。'),
          const _HelpText('有效记忆会参与检索；已取代和已失效内容仅供回看。固定记忆不会被自动流程覆盖。'),
        ],
      ),
    );
  }

  Widget _activeFilterSummary() {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (filter.observerCharacterId != null)
            _removableChip(
              label: '角色: ${_charName(filter.observerCharacterId)}',
              onRemove: () => onChanged(
                filter.copyWith(clearObserverCharacterId: true),
              ),
            ),
          if (filter.originConversationId != null)
            _removableChip(
              label: '场合: ${filter.originConversationId}',
              onRemove: () => onChanged(
                filter.copyWith(clearOriginConversationId: true),
              ),
            ),
          if (filter.status != null)
            _removableChip(
              label: '状态: ${_statusLabel(filter.status!)}',
              onRemove: () => onChanged(filter.copyWith(clearStatus: true)),
            ),
          if (filter.memoryKind != null)
            _removableChip(
              label: '类型: ${_kindLabel(filter.memoryKind!)}',
              onRemove: () => onChanged(filter.copyWith(clearMemoryKind: true)),
            ),
          if (filter.originType != null)
            _removableChip(
              label: '来源: ${filter.originType!.name}',
              onRemove: () => onChanged(filter.copyWith(clearOriginType: true)),
            ),
          if (filter.pinnedOnly != null)
            _removableChip(
              label: filter.pinnedOnly! ? '仅固定' : '仅未固定',
              onRemove: () => onChanged(filter.copyWith(clearPinnedOnly: true)),
            ),
          if (filter.subjectFilter != SubjectFilter.all)
            _removableChip(
              label: _subjectLabel(filter.subjectFilter),
              onRemove: () =>
                  onChanged(filter.copyWith(clearSubjectFilter: true)),
            ),
          if (!filter.isEmpty)
            TextButton.icon(
              onPressed: () => onChanged(const MemoryAuditFilter()),
              icon: const Icon(Icons.filter_list_off_rounded, size: 18),
              label: const Text('清除筛选'),
            ),
        ],
      ),
    );
  }

  Widget _quickFilters() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _choiceGroup(
          label: '记忆对象',
          options: [
            (
              label: '全部',
              selected: filter.subjectFilter == SubjectFilter.all,
              onTap: () => onChanged(
                    filter.copyWith(subjectFilter: SubjectFilter.all),
                  ),
            ),
            (
              label: '关于我',
              selected: filter.subjectFilter == SubjectFilter.aboutMe,
              onTap: () => onChanged(
                    filter.copyWith(subjectFilter: SubjectFilter.aboutMe),
                  ),
            ),
            (
              label: '自身成长',
              selected: filter.subjectFilter == SubjectFilter.selfGrowth,
              onTap: () => onChanged(
                    filter.copyWith(subjectFilter: SubjectFilter.selfGrowth),
                  ),
            ),
            for (final character in characters)
              (
                label: character.name,
                selected: filter.subjectFilter ==
                    SubjectFilter.aboutCharacter(character.id),
                onTap: () => onChanged(filter.copyWith(
                      subjectFilter: SubjectFilter.aboutCharacter(character.id),
                    )),
              ),
          ],
        ),
        _choiceGroup(
          label: '来源方式',
          options: [
            (
              label: '全部来源',
              selected: filter.originType == null,
              onTap: () => onChanged(filter.copyWith(clearOriginType: true)),
            ),
            for (final entry in const {
              MemoryOriginType.group: '群聊',
              MemoryOriginType.direct: '私聊',
              MemoryOriginType.manual: '手动',
              MemoryOriginType.legacyMigration: '迁移',
            }.entries)
              (
                label: entry.value,
                selected: filter.originType == entry.key,
                onTap: () => onChanged(
                      filter.copyWith(originType: entry.key),
                    ),
              ),
          ],
        ),
        _choiceGroup(
          label: '记忆状态',
          options: [
            (
              label: '全部状态',
              selected: filter.status == null,
              onTap: () => onChanged(filter.copyWith(clearStatus: true)),
            ),
            for (final entry in const {
              MemoryStatus.active: '有效',
              MemoryStatus.superseded: '已取代',
              MemoryStatus.invalidated: '已失效',
            }.entries)
              (
                label: entry.value,
                selected: filter.status == entry.key,
                onTap: () => onChanged(filter.copyWith(status: entry.key)),
              ),
          ],
        ),
        _choiceGroup(
          label: '记忆类型',
          options: [
            (
              label: '全部类型',
              selected: filter.memoryKind == null,
              onTap: () => onChanged(filter.copyWith(clearMemoryKind: true)),
            ),
            for (final entry in const {
              MemoryKind.fact: '知',
              MemoryKind.preference: '偏好',
              MemoryKind.commitment: '承诺',
              MemoryKind.sharedExperience: '经历',
              MemoryKind.relationshipNote: '关系',
              MemoryKind.personaGrowth: '成长',
              MemoryKind.explicitInstruction: '指令',
            }.entries)
              (
                label: entry.value,
                selected: filter.memoryKind == entry.key,
                onTap: () => onChanged(filter.copyWith(memoryKind: entry.key)),
              ),
          ],
        ),
        _choiceGroup(
          label: '固定状态',
          options: [
            (
              label: '固定状态: 全部',
              selected: filter.pinnedOnly == null,
              onTap: () => onChanged(filter.copyWith(clearPinnedOnly: true)),
            ),
            (
              label: '仅固定',
              selected: filter.pinnedOnly == true,
              onTap: () => onChanged(filter.copyWith(pinnedOnly: true)),
            ),
            (
              label: '仅未固定',
              selected: filter.pinnedOnly == false,
              onTap: () => onChanged(filter.copyWith(pinnedOnly: false)),
            ),
          ],
        ),
      ],
    );
  }

  Widget _choiceGroup({
    required String label,
    required List<({String label, bool selected, VoidCallback onTap})> options,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 12)),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final option in options)
                ChoiceChip(
                  label: Text(
                    option.label,
                    style: const TextStyle(fontSize: 12),
                  ),
                  selected: option.selected,
                  onSelected: (_) => option.onTap(),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _originConversationDropdown(BuildContext context) {
    const allValue = '__all_origin_conversations__';
    final values = <String>[allValue, ...originConversations.keys];
    final selectedId = filter.originConversationId;
    if (selectedId != null && !values.contains(selectedId)) {
      values.add(selectedId);
    }
    final labels = <String, String>{
      allValue: '全部场合',
      for (final entry in originConversations.entries)
        entry.key:
            '${entry.value.isEmpty ? entry.key : entry.value} (${entry.key})',
    };
    if (selectedId != null && !labels.containsKey(selectedId)) {
      labels[selectedId] = selectedId;
    }

    return InputDecorator(
      decoration: InputDecoration(
        labelText: '场合',
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: BorderSide(color: Theme.of(context).colorScheme.outline),
        ),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          isDense: true,
          value: selectedId ?? allValue,
          items: [
            for (final value in values)
              DropdownMenuItem<String>(
                value: value,
                child: Text(
                  labels[value] ?? value,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
          ],
          onChanged: (value) {
            if (value == null || value == allValue) {
              onChanged(filter.copyWith(clearOriginConversationId: true));
            } else {
              onChanged(filter.copyWith(originConversationId: value));
            }
          },
        ),
      ),
    );
  }

  Future<void> _showOriginConversationInput(BuildContext context) async {
    final entered = await showDialog<String>(
      context: context,
      builder: (_) => _OriginConversationDialog(
        initialValue: filter.originConversationId ?? '',
      ),
    );
    if (entered == null || entered.isEmpty) {
      if (entered != null) {
        onChanged(filter.copyWith(clearOriginConversationId: true));
      }
    } else {
      onChanged(filter.copyWith(originConversationId: entered));
    }
  }

  Widget _removableChip({
    required String label,
    required VoidCallback onRemove,
  }) {
    return Chip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      deleteIcon: const Icon(Icons.close_rounded, size: 16),
      onDeleted: onRemove,
      visualDensity: VisualDensity.compact,
    );
  }

  String _charName(String? id) {
    if (id == null) return '';
    final character = characters.cast<AICharacter?>().firstWhere(
          (item) => item?.id == id,
          orElse: () => null,
        );
    return character?.name ?? id;
  }

  String _statusLabel(MemoryStatus status) => switch (status) {
        MemoryStatus.active => '有效',
        MemoryStatus.superseded => '已取代',
        MemoryStatus.invalidated => '已失效',
      };

  String _kindLabel(MemoryKind kind) => switch (kind) {
        MemoryKind.fact => '知',
        MemoryKind.preference => '偏好',
        MemoryKind.commitment => '承诺',
        MemoryKind.sharedExperience => '经历',
        MemoryKind.relationshipNote => '关系',
        MemoryKind.personaGrowth => '成长',
        MemoryKind.explicitInstruction => '指令',
      };

  String _subjectLabel(SubjectFilter value) => switch (value.characterId) {
        '__all__' => '全部主体',
        '__about_me__' => '关于我',
        '__self_growth__' => '自身成长',
        final id => _charName(id),
      };

  Widget _searchableSelector({
    required Key key,
    required String label,
    required String value,
    required List<DropdownMenuEntry<String>> entries,
    required ValueChanged<String> onSelected,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: DropdownMenu<String>(
        key: key,
        label: Text(label),
        initialSelection: value,
        dropdownMenuEntries: entries,
        enableFilter: true,
        enableSearch: true,
        expandedInsets: EdgeInsets.zero,
        onSelected: (selected) {
          if (selected != null) onSelected(selected);
        },
      ),
    );
  }
}

class _OriginConversationDialog extends StatefulWidget {
  final String initialValue;

  const _OriginConversationDialog({required this.initialValue});

  @override
  State<_OriginConversationDialog> createState() =>
      _OriginConversationDialogState();
}

class _OriginConversationDialogState extends State<_OriginConversationDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialValue);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('输入场合 ID'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: '场合 ID',
          hintText: '例如 group-1 或 dm:character-id',
        ),
        onSubmitted: (value) => Navigator.pop(context, value.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: const Text('应用'),
        ),
      ],
    );
  }
}

class _HelpText extends StatelessWidget {
  final String text;

  const _HelpText(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

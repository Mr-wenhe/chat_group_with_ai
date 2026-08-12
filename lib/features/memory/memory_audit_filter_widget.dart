import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/permanent_memory.dart';
import 'package:chat_group/features/memory/memory_audit_filter.dart';
import 'package:chat_group/features/memory/memory_audit_filter_dialog.dart';
import 'package:chat_group/features/memory/memory_audit_presenter.dart';
import 'package:flutter/material.dart';

class MemoryAuditFilterWidget extends StatelessWidget {
  static const _all = '__all__';

  final MemoryAuditFilter filter;
  final List<AICharacter> characters;
  final Map<String, String> originConversations;
  final MemoryAuditPresenter? presenter;
  final ValueChanged<MemoryAuditFilter> onChanged;

  const MemoryAuditFilterWidget({
    super.key,
    required this.filter,
    required this.characters,
    this.originConversations = const {},
    this.presenter,
    required this.onChanged,
  });

  MemoryAuditPresenter get _displayPresenter =>
      presenter ??
      MemoryAuditPresenter(
        characterNames: {
          for (final character in characters) character.id: character.name,
        },
        conversationNames: originConversations,
      );

  @override
  Widget build(BuildContext context) {
    final observerEntries = <DropdownMenuEntry<String>>[
      const DropdownMenuEntry(value: _all, label: '全部 AI'),
      for (final character in characters)
        DropdownMenuEntry(value: character.id, label: character.name),
    ];
    final selectedObserver = filter.observerCharacterId;
    if (selectedObserver != null &&
        !observerEntries.any((entry) => entry.value == selectedObserver)) {
      observerEntries.add(
        DropdownMenuEntry(
            value: selectedObserver, label: _charName(selectedObserver)),
      );
    }
    final subjectEntries = <DropdownMenuEntry<String>>[
      const DropdownMenuEntry(value: _all, label: '全部对象'),
      const DropdownMenuEntry(value: '__about_me__', label: '关于我'),
      const DropdownMenuEntry(value: '__self_growth__', label: '自身成长'),
      for (final character in characters)
        DropdownMenuEntry(value: character.id, label: character.name),
    ];
    final selectedSubject = filter.subjectFilter.characterId;
    if (selectedSubject != null &&
        !subjectEntries.any((entry) => entry.value == selectedSubject) &&
        selectedSubject != '__all__' &&
        selectedSubject != '__about_me__' &&
        selectedSubject != '__self_growth__') {
      subjectEntries.add(
        DropdownMenuEntry(
            value: selectedSubject, label: _charName(selectedSubject)),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _MemoryAuditSearchField(
            initialValue: filter.searchQuery ?? '',
            onChanged: (value) => onChanged(
              filter.copyWith(
                searchQuery: value,
                clearSearchQuery: value.trim().isEmpty,
              ),
            ),
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _originConversationSelector()),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: OutlinedButton.icon(
                  key: const ValueKey('open-advanced-memory-filter'),
                  onPressed: () => _showAdvancedFilter(context),
                  icon: const Icon(Icons.tune_rounded, size: 16),
                  label: const Text('高级筛选'),
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
            entries: observerEntries,
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
            entries: subjectEntries,
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
              label: '场合: ${_originName(filter.originConversationId!)}',
              onRemove: () => onChanged(
                filter.copyWith(clearOriginConversationId: true),
              ),
            ),
          if (filter.status != null)
            _removableChip(
              label: '状态: ${MemoryAuditLabels.status(filter.status!).label}',
              onRemove: () => onChanged(filter.copyWith(clearStatus: true)),
            ),
          if (filter.memoryKind != null)
            _removableChip(
              label: '类型: ${MemoryAuditLabels.kind(filter.memoryKind!).label}',
              onRemove: () => onChanged(filter.copyWith(clearMemoryKind: true)),
            ),
          if (filter.originType != null)
            _removableChip(
              label:
                  '来源: ${MemoryAuditLabels.originType(filter.originType!).label}',
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
            for (final value in MemoryOriginType.values)
              (
                label: MemoryAuditLabels.originType(value).label,
                selected: filter.originType == value,
                onTap: () => onChanged(
                      filter.copyWith(originType: value),
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
            for (final value in MemoryStatus.values)
              (
                label: MemoryAuditLabels.status(value).label,
                selected: filter.status == value,
                onTap: () => onChanged(filter.copyWith(status: value)),
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
            for (final value in MemoryKind.values)
              (
                label: MemoryAuditLabels.kind(value).label,
                selected: filter.memoryKind == value,
                onTap: () => onChanged(filter.copyWith(memoryKind: value)),
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

  Widget _originConversationSelector() {
    const allValue = '__all_origin_conversations__';
    final values = <String>[allValue, ...originConversations.keys];
    final selectedId = filter.originConversationId;
    if (selectedId != null && !values.contains(selectedId)) {
      values.add(selectedId);
    }
    final entries = <DropdownMenuEntry<String>>[
      const DropdownMenuEntry(value: allValue, label: '全部场合'),
      for (final value in values.skip(1))
        DropdownMenuEntry(
          value: value,
          label: _originName(value),
        ),
    ];
    return _searchableSelector(
      key: const ValueKey('memory-filter-origin-conversation'),
      label: '来源场合',
      value: selectedId ?? allValue,
      entries: entries,
      onSelected: (value) {
        if (value == allValue) {
          onChanged(filter.copyWith(clearOriginConversationId: true));
        } else {
          onChanged(filter.copyWith(originConversationId: value));
        }
      },
    );
  }

  Future<void> _showAdvancedFilter(BuildContext context) async {
    final next = await showDialog<MemoryAuditFilter>(
      context: context,
      builder: (_) => MemoryAuditFilterDialog(
        filter: filter,
        characters: characters,
        originConversations: originConversations,
        presenter: _displayPresenter,
      ),
    );
    if (next != null) onChanged(next);
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
    return _displayPresenter.characterNames[id] ??
        _displayPresenter.characterSnapshotNames[id] ??
        '已删除角色';
  }

  String _originName(String id) => _displayPresenter.resolveConversationName(
        id,
        snapshotName: originConversations[id] ?? '',
      );

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

class _MemoryAuditSearchField extends StatefulWidget {
  final String initialValue;
  final ValueChanged<String> onChanged;

  const _MemoryAuditSearchField({
    required this.initialValue,
    required this.onChanged,
  });

  @override
  State<_MemoryAuditSearchField> createState() =>
      _MemoryAuditSearchFieldState();
}

class _MemoryAuditSearchFieldState extends State<_MemoryAuditSearchField> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialValue);

  @override
  void didUpdateWidget(covariant _MemoryAuditSearchField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialValue != _controller.text) {
      _controller.value = TextEditingValue(
        text: widget.initialValue,
        selection: TextSelection.collapsed(offset: widget.initialValue.length),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: const ValueKey('memory-audit-search'),
      controller: _controller,
      onChanged: widget.onChanged,
      decoration: const InputDecoration(
        labelText: '搜索记忆',
        hintText: '搜索观察 AI、正文、对象、来源场合或中文术语',
        prefixIcon: Icon(Icons.search_rounded),
      ),
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

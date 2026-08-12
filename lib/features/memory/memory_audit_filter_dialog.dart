import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/permanent_memory.dart';
import 'package:chat_group/features/memory/memory_audit_filter.dart';
import 'package:chat_group/features/memory/memory_audit_presenter.dart';
import 'package:flutter/material.dart';

class MemoryAuditFilterDialog extends StatefulWidget {
  final MemoryAuditFilter filter;
  final List<AICharacter> characters;
  final Map<String, String> originConversations;
  final MemoryAuditPresenter presenter;

  const MemoryAuditFilterDialog({
    super.key,
    required this.filter,
    required this.characters,
    required this.originConversations,
    required this.presenter,
  });

  @override
  State<MemoryAuditFilterDialog> createState() =>
      _MemoryAuditFilterDialogState();
}

class _MemoryAuditFilterDialogState extends State<MemoryAuditFilterDialog> {
  static const _all = '__all__';
  static const _allOrigin = '__all_origin_conversations__';
  static const _aboutMe = '__about_me__';
  static const _selfGrowth = '__self_growth__';

  late MemoryAuditFilter _draft = widget.filter;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('高级筛选'),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 520,
          maxHeight: MediaQuery.sizeOf(context).height * .55,
        ),
        child: SingleChildScrollView(
          child: Column(
            children: [
              _searchableSelector(
                key: const ValueKey('memory-filter-dialog-observer'),
                label: '观察 AI',
                value: _draft.observerCharacterId ?? _all,
                entries: _observerEntries(),
                onSelected: (value) => _update(_draft.copyWith(
                  observerCharacterId: value,
                  clearObserverCharacterId: value == _all,
                )),
              ),
              _searchableSelector(
                key: const ValueKey('memory-filter-dialog-subject'),
                label: '记忆对象',
                value: _draft.subjectFilter.characterId ?? _all,
                entries: _subjectEntries(),
                onSelected: (value) => _update(
                  _draft.copyWith(subjectFilter: _subjectFilter(value)),
                ),
              ),
              _searchableSelector(
                key: const ValueKey('memory-filter-dialog-origin-conversation'),
                label: '来源场合',
                value: _draft.originConversationId ?? _allOrigin,
                entries: _originEntries(),
                onSelected: (value) => _update(
                  value == _allOrigin
                      ? _draft.copyWith(clearOriginConversationId: true)
                      : _draft.copyWith(originConversationId: value),
                ),
              ),
              _enumField<MemoryOriginType>(
                key: const ValueKey('memory-filter-dialog-origin-type'),
                label: '来源方式',
                allLabel: '全部来源方式',
                value: _draft.originType,
                values: MemoryOriginType.values,
                describe: MemoryAuditLabels.originType,
                onChanged: (value) => _update(
                  value == null
                      ? _draft.copyWith(clearOriginType: true)
                      : _draft.copyWith(originType: value),
                ),
              ),
              _enumField<MemoryStatus>(
                key: const ValueKey('memory-filter-dialog-status'),
                label: '记忆状态',
                allLabel: '全部状态',
                value: _draft.status,
                values: MemoryStatus.values,
                describe: MemoryAuditLabels.status,
                onChanged: (value) => _update(
                  value == null
                      ? _draft.copyWith(clearStatus: true)
                      : _draft.copyWith(status: value),
                ),
              ),
              _enumField<MemoryKind>(
                key: const ValueKey('memory-filter-dialog-kind'),
                label: '记忆类型',
                allLabel: '全部类型',
                value: _draft.memoryKind,
                values: MemoryKind.values,
                describe: MemoryAuditLabels.kind,
                onChanged: (value) => _update(
                  value == null
                      ? _draft.copyWith(clearMemoryKind: true)
                      : _draft.copyWith(memoryKind: value),
                ),
              ),
              _enumField<bool>(
                key: const ValueKey('memory-filter-dialog-pinned'),
                label: '固定状态',
                allLabel: '全部固定状态',
                value: _draft.pinnedOnly,
                values: const [true, false],
                describe: MemoryAuditLabels.pinned,
                onChanged: (value) => _update(
                  value == null
                      ? _draft.copyWith(clearPinnedOnly: true)
                      : _draft.copyWith(pinnedOnly: value),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => setState(() => _draft = const MemoryAuditFilter()),
          child: const Text('重置'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _draft),
          child: const Text('应用筛选'),
        ),
      ],
    );
  }

  void _update(MemoryAuditFilter next) {
    setState(() => _draft = next);
  }

  List<DropdownMenuEntry<String>> _observerEntries() {
    final entries = <DropdownMenuEntry<String>>[
      const DropdownMenuEntry(value: _all, label: '全部 AI'),
      for (final character in widget.characters)
        DropdownMenuEntry(value: character.id, label: character.name),
    ];
    final selected = _draft.observerCharacterId;
    if (selected != null && !entries.any((entry) => entry.value == selected)) {
      entries.add(
        DropdownMenuEntry(value: selected, label: _characterName(selected)),
      );
    }
    return entries;
  }

  List<DropdownMenuEntry<String>> _subjectEntries() {
    final entries = <DropdownMenuEntry<String>>[
      const DropdownMenuEntry(value: _all, label: '全部对象'),
      const DropdownMenuEntry(value: _aboutMe, label: '关于我'),
      const DropdownMenuEntry(value: _selfGrowth, label: '自身成长'),
      for (final character in widget.characters)
        DropdownMenuEntry(value: character.id, label: character.name),
    ];
    final selected = _draft.subjectFilter.characterId;
    if (selected != null &&
        !_isBuiltInSubject(selected) &&
        !entries.any((entry) => entry.value == selected)) {
      entries.add(
        DropdownMenuEntry(value: selected, label: _characterName(selected)),
      );
    }
    return entries;
  }

  List<DropdownMenuEntry<String>> _originEntries() {
    final entries = <DropdownMenuEntry<String>>[
      const DropdownMenuEntry(value: _allOrigin, label: '全部来源场合'),
      for (final entry in widget.originConversations.entries)
        DropdownMenuEntry(
          value: entry.key,
          label: widget.presenter.resolveConversationName(
            entry.key,
            snapshotName: entry.value,
          ),
        ),
    ];
    final selected = _draft.originConversationId;
    if (selected != null && !entries.any((entry) => entry.value == selected)) {
      entries.add(
        DropdownMenuEntry(
          value: selected,
          label: widget.presenter.resolveConversationName(selected),
        ),
      );
    }
    return entries;
  }

  SubjectFilter _subjectFilter(String value) => switch (value) {
        _all => SubjectFilter.all,
        _aboutMe => SubjectFilter.aboutMe,
        _selfGrowth => SubjectFilter.selfGrowth,
        _ => SubjectFilter.aboutCharacter(value),
      };

  bool _isBuiltInSubject(String value) =>
      value == _all || value == _aboutMe || value == _selfGrowth;

  String _characterName(String id) =>
      widget.presenter.characterNames[id] ??
      widget.presenter.characterSnapshotNames[id] ??
      '已删除角色';

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

  Widget _enumField<T>({
    required Key key,
    required String label,
    required String allLabel,
    required T? value,
    required List<T> values,
    required MemoryAuditLabel Function(T) describe,
    required ValueChanged<T?> onChanged,
  }) {
    final helperText = value == null ? '不限定' : describe(value).description;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: DropdownButtonFormField<T?>(
        key: key,
        value: value,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: label,
          helperText: helperText,
        ),
        items: [
          DropdownMenuItem<T?>(value: null, child: Text(allLabel)),
          for (final item in values)
            DropdownMenuItem<T?>(
              value: item,
              child: Text(describe(item).label),
            ),
        ],
        onChanged: onChanged,
      ),
    );
  }
}

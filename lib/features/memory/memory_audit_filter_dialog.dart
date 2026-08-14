import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/permanent_memory.dart';
import 'package:chat_group/features/memory/memory_audit_filter.dart';
import 'package:chat_group/features/memory/memory_audit_presenter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class MemoryAuditFilterDialog extends StatefulWidget {
  final MemoryAuditFilter filter;
  final List<AICharacter> characters;
  final Map<String, String> originConversations;
  final MemoryAuditPresenter presenter;
  final MemoryConversationScope scope;
  final bool inBottomSheet;
  final bool showNavigationSelectors;

  const MemoryAuditFilterDialog({
    super.key,
    required this.filter,
    required this.characters,
    required this.originConversations,
    required this.presenter,
    this.scope = const MemoryConversationScope.settings(),
    this.inBottomSheet = false,
    this.showNavigationSelectors = true,
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

  late MemoryAuditFilter _draft;
  bool _isApplying = false;

  @override
  void initState() {
    super.initState();
    _draft = widget.scope.constrainFilter(widget.filter).copyWith();
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): _close,
      },
      child: FocusTraversalGroup(
        child: widget.inBottomSheet
            ? _buildBottomSheet(context)
            : AlertDialog(
                title: const Text('高级筛选'),
                content: _buildFields(context),
                actions: _buildActions(),
              ),
      ),
    );
  }

  Widget _buildBottomSheet(BuildContext context) {
    return AnimatedPadding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '高级筛选',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Semantics(
                    key: const ValueKey('memory-filter-dialog-close'),
                    label: '关闭',
                    button: true,
                    child: IconButton(
                      tooltip: '关闭',
                      onPressed: _close,
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ),
                ],
              ),
              _buildFields(context),
              Align(
                alignment: Alignment.centerRight,
                child: Wrap(
                  spacing: 8,
                  children: _buildActions(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFields(BuildContext context) {
    final screenHeight = MediaQuery.sizeOf(context).height;
    final keyboardInset =
        widget.inBottomSheet ? MediaQuery.viewInsetsOf(context).bottom : 0.0;
    final availableHeight =
        (screenHeight - keyboardInset).clamp(0.0, screenHeight);
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: 520,
        maxHeight: availableHeight * .62,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.showNavigationSelectors &&
                widget.scope.showsObserverFilter)
              _searchableSelector(
                key: const ValueKey('memory-filter-dialog-observer'),
                label: '观察 AI',
                value: _draft.observerCharacterId ?? _all,
                entries: _observerEntries(),
                emptyMessage: '暂无可选观察 AI',
                onSelected: (value) => _update(_draft.copyWith(
                  observerCharacterId: value,
                  clearObserverCharacterId: value == _all,
                )),
              ),
            if (widget.showNavigationSelectors &&
                widget.scope.showsObserverFilter)
              const _HelpText('拥有并可能在对话中使用这条记忆的角色。'),
            if (widget.showNavigationSelectors &&
                widget.scope.showsSubjectFilter)
              _searchableSelector(
                key: const ValueKey('memory-filter-dialog-subject'),
                label: '记忆对象',
                value: _draft.subjectFilter.characterId ?? _all,
                entries: _subjectEntries(),
                emptyMessage: '暂无可选记忆对象',
                onSelected: (value) => _update(
                  _draft.copyWith(subjectFilter: _subjectFilter(value)),
                ),
              ),
            if (widget.showNavigationSelectors &&
                widget.scope.showsSubjectFilter)
              const _HelpText('这条内容所描述的用户、角色或观察 AI 自身。'),
            _searchableSelector(
              key: const ValueKey('memory-filter-dialog-origin-conversation'),
              label: '来源场合',
              value: _draft.originConversationId ?? _allOrigin,
              entries: _originEntries(),
              emptyMessage: '暂无可选来源场合',
              onSelected: (value) => _update(
                value == _allOrigin
                    ? _draft.copyWith(clearOriginConversationId: true)
                    : _draft.copyWith(originConversationId: value),
              ),
            ),
            const _HelpText('记忆最初形成的位置，不代表只能在那里使用。'),
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
    );
  }

  List<Widget> _buildActions() {
    return [
      SizedBox(
        height: 48,
        child: TextButton(
          key: const ValueKey('memory-filter-dialog-reset'),
          onPressed: () => setState(() {
            _draft = widget.scope
                .constrainFilter(const MemoryAuditFilter())
                .copyWith();
          }),
          child: const Text('重置'),
        ),
      ),
      SizedBox(
        height: 48,
        child: TextButton(
          key: const ValueKey('memory-filter-dialog-cancel'),
          onPressed: _close,
          child: const Text('取消'),
        ),
      ),
      SizedBox(
        height: 48,
        child: FilledButton(
          key: const ValueKey('memory-filter-dialog-apply'),
          onPressed: _isApplying ? null : _apply,
          child: const Text('应用筛选'),
        ),
      ),
    ];
  }

  void _update(MemoryAuditFilter next) {
    setState(() => _draft = widget.scope.constrainFilter(next));
  }

  void _close() {
    if (Navigator.of(context).canPop()) Navigator.pop(context);
  }

  void _apply() {
    if (_isApplying) return;
    setState(() => _isApplying = true);
    Navigator.pop(
      context,
      widget.scope.constrainFilter(_draft).copyWith(),
    );
  }

  List<DropdownMenuEntry<String>> _observerEntries() {
    final allowed = widget.scope.allowedObserverCharacterIds;
    final available = widget.characters
        .where((character) => allowed == null || allowed.contains(character.id))
        .toList(growable: false);
    final selected = _draft.observerCharacterId;
    if (available.isEmpty && selected == null) return const [];

    final entries = <DropdownMenuEntry<String>>[
      const DropdownMenuEntry(value: _all, label: '全部 AI'),
      for (final character in available)
        DropdownMenuEntry(
          value: character.id,
          label: MemoryAuditPresenter.safeDisplayName(
            character.name,
            character.id,
          ),
        ),
    ];
    if (selected != null && !entries.any((entry) => entry.value == selected)) {
      entries.add(
        DropdownMenuEntry(value: selected, label: _characterName(selected)),
      );
    }
    return entries;
  }

  List<DropdownMenuEntry<String>> _subjectEntries() {
    final selectedObserver = _draft.observerCharacterId;
    final allowed = widget.scope.allowedSubjectIds;
    final excludeObserver =
        widget.scope.type == MemoryConversationScopeType.group;
    final available = widget.characters.where((character) {
      if (allowed != null && !allowed.contains(character.id)) return false;
      return !excludeObserver ||
          selectedObserver == null ||
          character.id != selectedObserver;
    }).toList(growable: false);
    final entries = <DropdownMenuEntry<String>>[
      const DropdownMenuEntry(value: _all, label: '全部对象'),
      const DropdownMenuEntry(value: _aboutMe, label: '关于我'),
      const DropdownMenuEntry(value: _selfGrowth, label: '自身成长'),
      for (final character in available)
        DropdownMenuEntry(
          value: character.id,
          label: MemoryAuditPresenter.safeDisplayName(
            character.name,
            character.id,
          ),
        ),
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
    final selected = _draft.originConversationId;
    if (widget.originConversations.isEmpty && selected == null) return const [];

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

  String _characterName(String id) => MemoryAuditPresenter.safeDisplayName(
        widget.presenter.characterNames[id] ??
            widget.presenter.characterSnapshotNames[id],
        id,
      );

  Widget _searchableSelector({
    required Key key,
    required String label,
    required String value,
    required List<DropdownMenuEntry<String>> entries,
    required String emptyMessage,
    required ValueChanged<String> onSelected,
  }) {
    if (entries.isEmpty) return _emptySelector(key, label, emptyMessage);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Container(
        key: key,
        child: Semantics(
          container: true,
          label: '$label，可输入搜索',
          child: DropdownMenu<String>(
            key: ValueKey('$label-$value'),
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
        ),
      ),
    );
  }

  Widget _emptySelector(Key key, String label, String message) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Semantics(
        key: key,
        container: true,
        label: '$label：$message',
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: label,
            floatingLabelBehavior: FloatingLabelBehavior.always,
            helperText: message,
            enabled: false,
          ),
          child: const SizedBox(height: 24),
        ),
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
          floatingLabelBehavior: FloatingLabelBehavior.always,
          helperText: helperText,
          helperMaxLines: 2,
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

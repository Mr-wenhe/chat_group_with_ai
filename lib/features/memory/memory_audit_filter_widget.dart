import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/permanent_memory.dart';
import 'package:chat_group/features/memory/memory_audit_filter.dart';
import 'package:flutter/material.dart';

class MemoryAuditFilterWidget extends StatelessWidget {
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _originConversationFilter(context),
              OutlinedButton.icon(
                onPressed: () => _showOriginConversationInput(context),
                icon: const Icon(Icons.edit_location_alt_outlined, size: 16),
                label: const Text('输入场合'),
              ),
              _observerChip(context),
              _subjectFilterChips(),
              _originTypeChips(),
              _statusChips(),
              _kindChips(),
              _pinnedChips(),
            ],
          ),
        ),
        if (filter.isEmpty)
          const SizedBox.shrink()
        else
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
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
                    onRemove: () => onChanged(
                      filter.copyWith(clearStatus: true),
                    ),
                  ),
                if (filter.memoryKind != null)
                  _removableChip(
                    label: '类型: ${_kindLabel(filter.memoryKind!)}',
                    onRemove: () => onChanged(
                      filter.copyWith(clearMemoryKind: true),
                    ),
                  ),
                if (filter.originType != null)
                  _removableChip(
                    label: '来源: ${filter.originType!.name}',
                    onRemove: () => onChanged(
                      filter.copyWith(clearOriginType: true),
                    ),
                  ),
                if (filter.pinnedOnly != null)
                  _removableChip(
                    label: filter.pinnedOnly! ? '仅固定' : '仅未固定',
                    onRemove: () => onChanged(
                      filter.copyWith(clearPinnedOnly: true),
                    ),
                  ),
                if (filter.subjectFilter != SubjectFilter.all)
                  _removableChip(
                    label: _subjectLabel(filter.subjectFilter),
                    onRemove: () => onChanged(
                      filter.copyWith(clearSubjectFilter: true),
                    ),
                  ),
                const SizedBox(width: 4),
                TextButton.icon(
                  onPressed: () => onChanged(const MemoryAuditFilter()),
                  icon: const Icon(Icons.filter_list_off_rounded, size: 18),
                  label: const Text('清除筛选'),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _originConversationFilter(BuildContext context) {
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
                child:
                    Text(labels[value]!, style: const TextStyle(fontSize: 13)),
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

  Widget _observerChip(BuildContext context) {
    final selectedId = filter.observerCharacterId;
    final selectedChar = selectedId == null
        ? null
        : characters.cast<AICharacter?>().firstWhere(
              (x) => x?.id == selectedId,
              orElse: () => null,
            );
    final hint = selectedChar?.name ?? '观察 AI';
    return InputDecorator(
      isEmpty: selectedId == null,
      decoration: InputDecoration(
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: BorderSide(
            color: Theme.of(context).colorScheme.outline,
          ),
        ),
        labelText: hint,
        labelStyle: TextStyle(
          fontSize: 13,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String?>(
          isDense: true,
          value: selectedId,
          hint: const Text('全部 AI', style: TextStyle(fontSize: 13)),
          items: [
            const DropdownMenuItem<String?>(
              value: null,
              child: Text('全部 AI', style: TextStyle(fontSize: 13)),
            ),
            for (final c in characters)
              DropdownMenuItem<String?>(
                value: c.id,
                child: Text(c.name, style: const TextStyle(fontSize: 13)),
              ),
          ],
          onChanged: (v) {
            if (v == selectedId) return;
            onChanged(filter.copyWith(
              observerCharacterId: v,
              clearObserverCharacterId: v == null,
            ));
          },
        ),
      ),
    );
  }

  Widget _subjectFilterChips() {
    final options = <({String label, SubjectFilter filter, bool selected})>[
      (
        label: '全部',
        filter: SubjectFilter.all,
        selected: filter.subjectFilter == SubjectFilter.all
      ),
      (
        label: '关于我',
        filter: SubjectFilter.aboutMe(),
        selected: filter.subjectFilter == SubjectFilter.aboutMe()
      ),
      (
        label: '自身成长',
        filter: SubjectFilter.selfGrowth(),
        selected: filter.subjectFilter == SubjectFilter.selfGrowth()
      ),
    ];
    for (final c in characters) {
      options.add((
        label: c.name,
        filter: SubjectFilter.aboutCharacter(c.id),
        selected: filter.subjectFilter == SubjectFilter.aboutCharacter(c.id),
      ));
    }
    return Wrap(
      spacing: 4,
      children: [
        for (final opt in options)
          ChoiceChip(
            label: Text(opt.label, style: const TextStyle(fontSize: 12)),
            selected: opt.selected,
            onSelected: (_) => onChanged(
              filter.copyWith(subjectFilter: opt.filter),
            ),
            visualDensity: VisualDensity.compact,
          ),
      ],
    );
  }

  Widget _originTypeChips() {
    final options = <({String label, MemoryOriginType? type, bool selected})>[
      (label: '全部来源', type: null, selected: filter.originType == null),
      (
        label: '群聊',
        type: MemoryOriginType.group,
        selected: filter.originType == MemoryOriginType.group
      ),
      (
        label: '私聊',
        type: MemoryOriginType.direct,
        selected: filter.originType == MemoryOriginType.direct
      ),
      (
        label: '手动',
        type: MemoryOriginType.manual,
        selected: filter.originType == MemoryOriginType.manual
      ),
      (
        label: '迁移',
        type: MemoryOriginType.legacyMigration,
        selected: filter.originType == MemoryOriginType.legacyMigration
      ),
    ];
    return Wrap(
      spacing: 4,
      children: [
        for (final opt in options)
          ChoiceChip(
            label: Text(opt.label, style: const TextStyle(fontSize: 12)),
            selected: opt.selected,
            onSelected: (_) => onChanged(
              filter.copyWith(
                originType: opt.type,
                clearOriginType: opt.type == null,
              ),
            ),
            visualDensity: VisualDensity.compact,
          ),
      ],
    );
  }

  Widget _statusChips() {
    final options = <({String label, MemoryStatus? status, bool selected})>[
      (label: '全部状态', status: null, selected: filter.status == null),
      (
        label: '有效',
        status: MemoryStatus.active,
        selected: filter.status == MemoryStatus.active
      ),
      (
        label: '已取代',
        status: MemoryStatus.superseded,
        selected: filter.status == MemoryStatus.superseded
      ),
      (
        label: '已失效',
        status: MemoryStatus.invalidated,
        selected: filter.status == MemoryStatus.invalidated
      ),
    ];
    return Wrap(
      spacing: 4,
      children: [
        for (final opt in options)
          ChoiceChip(
            label: Text(opt.label, style: const TextStyle(fontSize: 12)),
            selected: opt.selected,
            onSelected: (_) => onChanged(
              filter.copyWith(
                status: opt.status,
                clearStatus: opt.status == null,
              ),
            ),
            visualDensity: VisualDensity.compact,
          ),
      ],
    );
  }

  Widget _kindChips() {
    const kindMap = <MemoryKind, String>{
      MemoryKind.fact: '知',
      MemoryKind.preference: '偏好',
      MemoryKind.commitment: '承诺',
      MemoryKind.sharedExperience: '经历',
      MemoryKind.relationshipNote: '关系',
      MemoryKind.personaGrowth: '成长',
      MemoryKind.explicitInstruction: '指令',
    };
    final options = <({String label, MemoryKind? kind, bool selected})>[
      (label: '全部类型', kind: null, selected: filter.memoryKind == null),
      for (final entry in kindMap.entries)
        (
          label: entry.value,
          kind: entry.key,
          selected: filter.memoryKind == entry.key
        ),
    ];
    return Wrap(
      spacing: 4,
      children: [
        for (final opt in options)
          ChoiceChip(
            label: Text(opt.label, style: const TextStyle(fontSize: 12)),
            selected: opt.selected,
            onSelected: (_) => onChanged(
              filter.copyWith(
                memoryKind: opt.kind,
                clearMemoryKind: opt.kind == null,
              ),
            ),
            visualDensity: VisualDensity.compact,
          ),
      ],
    );
  }

  Widget _pinnedChips() {
    final options = <({String label, bool? only, bool selected})>[
      (label: '固定状态: 全部', only: null, selected: filter.pinnedOnly == null),
      (label: '仅固定', only: true, selected: filter.pinnedOnly == true),
      (label: '仅未固定', only: false, selected: filter.pinnedOnly == false),
    ];
    return Wrap(
      spacing: 4,
      children: [
        for (final opt in options)
          ChoiceChip(
            label: Text(opt.label, style: const TextStyle(fontSize: 12)),
            selected: opt.selected,
            onSelected: (_) => onChanged(
              filter.copyWith(
                pinnedOnly: opt.only,
                clearPinnedOnly: opt.only == null,
              ),
            ),
            visualDensity: VisualDensity.compact,
          ),
      ],
    );
  }

  Future<void> _showOriginConversationInput(BuildContext context) async {
    final entered = await showDialog<String>(
      context: context,
      builder: (_) => _OriginConversationDialog(
        initialValue: filter.originConversationId ?? '',
      ),
    );
    if (entered == null) return;
    if (entered.isEmpty) {
      onChanged(filter.copyWith(clearOriginConversationId: true));
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
    final c = characters.cast<AICharacter?>().firstWhere(
          (x) => x?.id == id,
          orElse: () => null,
        );
    return c?.name ?? id;
  }

  String _statusLabel(MemoryStatus status) {
    return switch (status) {
      MemoryStatus.active => '有效',
      MemoryStatus.superseded => '已取代',
      MemoryStatus.invalidated => '已失效',
    };
  }

  String _kindLabel(MemoryKind kind) {
    return switch (kind) {
      MemoryKind.fact => '知',
      MemoryKind.preference => '偏好',
      MemoryKind.commitment => '承诺',
      MemoryKind.sharedExperience => '经历',
      MemoryKind.relationshipNote => '关系',
      MemoryKind.personaGrowth => '成长',
      MemoryKind.explicitInstruction => '指令',
    };
  }

  String _subjectLabel(SubjectFilter filter) {
    return switch (filter.characterId) {
      '__all__' => '全部主体',
      '__about_me__' => '关于我',
      '__self_growth__' => '自身成长',
      final id => _charName(id),
    };
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

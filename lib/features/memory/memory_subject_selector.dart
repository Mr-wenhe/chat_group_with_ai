import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/features/memory/memory_audit_presenter.dart';
import 'package:flutter/material.dart';

class MemorySubjectSelector extends StatefulWidget {
  static const allValue = '__all__';
  static const aboutMeValue = '__about_me__';
  static const otherCharactersValue = '__other_characters__';
  static const selfGrowthValue = '__self_growth__';

  final String value;
  final List<AICharacter> characters;
  final ValueChanged<String> onChanged;

  const MemorySubjectSelector({
    super.key,
    required this.value,
    required this.characters,
    required this.onChanged,
  });

  @override
  State<MemorySubjectSelector> createState() => _MemorySubjectSelectorState();
}

class _MemorySubjectSelectorState extends State<MemorySubjectSelector> {
  FocusNode? _searchFocusNode;
  late bool _showCharacterSearch;

  @override
  void initState() {
    super.initState();
    _showCharacterSearch = _isOtherValue(widget.value);
  }

  @override
  void didUpdateWidget(covariant MemorySubjectSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      _showCharacterSearch = _isOtherValue(widget.value);
      if (!_showCharacterSearch) _searchFocusNode?.unfocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final selectedCharacter = _selectedCharacter;
    final otherSelected = _showCharacterSearch || selectedCharacter != null;
    return Padding(
      key: const ValueKey('memory-subject-selector'),
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '记忆对象',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          _buildQuickChoices(otherSelected),
          if (_showCharacterSearch || selectedCharacter != null) ...[
            const SizedBox(height: 8),
            _buildCharacterSearch(selectedCharacter),
          ],
        ],
      ),
    );
  }

  Widget _buildQuickChoices(bool otherSelected) => Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _quickChoice(
            key: const ValueKey('memory-subject-quick-about-me'),
            label: '关于我',
            selected: widget.value == MemorySubjectSelector.aboutMeValue,
            onSelected: (_) =>
                _selectBuiltIn(MemorySubjectSelector.aboutMeValue),
          ),
          _quickChoice(
            key: const ValueKey('memory-subject-quick-all'),
            label: '全部对象',
            selected: widget.value == MemorySubjectSelector.allValue &&
                !otherSelected,
            onSelected: (_) => _selectBuiltIn(MemorySubjectSelector.allValue),
          ),
          _quickChoice(
            key: const ValueKey('memory-subject-quick-other'),
            label: '其他角色',
            selected: otherSelected,
            onSelected: (_) => _beginOtherSelection(),
          ),
          _quickChoice(
            key: const ValueKey('memory-subject-quick-self-growth'),
            label: '自身成长',
            selected: widget.value == MemorySubjectSelector.selfGrowthValue,
            onSelected: (_) =>
                _selectBuiltIn(MemorySubjectSelector.selfGrowthValue),
          ),
        ],
      );

  Widget _buildCharacterSearch(AICharacter? selectedCharacter) =>
      Autocomplete<AICharacter>(
        key: ValueKey(
          'memory-subject-autocomplete-${selectedCharacter?.id ?? 'none'}',
        ),
        initialValue: TextEditingValue(
          text: selectedCharacter == null
              ? ''
              : MemoryAuditPresenter.safeDisplayName(
                  selectedCharacter.name,
                  selectedCharacter.id,
                ),
        ),
        displayStringForOption: (character) =>
            MemoryAuditPresenter.safeDisplayName(character.name, character.id),
        optionsBuilder: _characterOptions,
        onSelected: (character) => widget.onChanged(character.id),
        fieldViewBuilder: (
          context,
          controller,
          focusNode,
          onFieldSubmitted,
        ) {
          _searchFocusNode = focusNode;
          return TextField(
            key: const ValueKey('memory-subject-search'),
            controller: controller,
            focusNode: focusNode,
            onSubmitted: (_) => onFieldSubmitted(),
            decoration: const InputDecoration(
              labelText: '搜索其他角色',
              hintText: '按角色名、性别或职业搜索',
              prefixIcon: Icon(Icons.person_search_outlined),
            ),
          );
        },
        optionsViewBuilder: (context, onSelected, options) =>
            _subjectOptionsView(context, options, onSelected),
      );

  Iterable<AICharacter> _characterOptions(TextEditingValue value) {
    final query = value.text.trim().toLowerCase();
    if (query.isEmpty) return widget.characters;
    return widget.characters.where(
      (character) =>
          '${character.name} ${character.role} ${character.displayGenderLabel}'
              .toLowerCase()
              .contains(query),
    );
  }

  Widget _subjectOptionsView(
    BuildContext context,
    Iterable<AICharacter> options,
    AutocompleteOnSelected<AICharacter> onSelected,
  ) {
    final materializedOptions = options.toList(growable: false);
    return Align(
      alignment: Alignment.topLeft,
      child: Material(
        elevation: 4,
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 280),
          child: ListView.builder(
            padding: EdgeInsets.zero,
            itemCount: materializedOptions.length,
            itemBuilder: (context, index) {
              final character = materializedOptions[index];
              return ListTile(
                key: ValueKey('memory-subject-option-${character.id}'),
                dense: true,
                leading: _CharacterAvatar(
                  avatar: character.avatar,
                  name: MemoryAuditPresenter.safeDisplayName(
                    character.name,
                    character.id,
                  ),
                ),
                title: Text(
                  MemoryAuditPresenter.safeDisplayName(
                    character.name,
                    character.id,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${character.displayGenderLabel} · ${character.role.trim().isEmpty ? '未设置职业' : character.role}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => onSelected(character),
              );
            },
          ),
        ),
      ),
    );
  }

  ChoiceChip _quickChoice({
    required Key key,
    required String label,
    required bool selected,
    required ValueChanged<bool> onSelected,
  }) {
    return ChoiceChip(
      key: key,
      label: Text(label),
      selected: selected,
      onSelected: onSelected,
    );
  }

  AICharacter? get _selectedCharacter {
    for (final character in widget.characters) {
      if (character.id == widget.value) return character;
    }
    return null;
  }

  void _selectBuiltIn(String value) {
    setState(() => _showCharacterSearch = false);
    _searchFocusNode?.unfocus();
    widget.onChanged(value);
  }

  void _beginOtherSelection() {
    setState(() => _showCharacterSearch = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocusNode?.requestFocus();
    });
  }

  bool _isOtherValue(String value) =>
      value != MemorySubjectSelector.allValue &&
      value != MemorySubjectSelector.aboutMeValue &&
      value != MemorySubjectSelector.selfGrowthValue;
}

class _CharacterAvatar extends StatelessWidget {
  final String avatar;
  final String name;

  const _CharacterAvatar({required this.avatar, required this.name});

  @override
  Widget build(BuildContext context) {
    final text = avatar.trim().isEmpty
        ? (name.trim().isEmpty ? 'AI' : name.characters.first)
        : avatar.trim();
    return CircleAvatar(radius: 16, child: Text(text));
  }
}

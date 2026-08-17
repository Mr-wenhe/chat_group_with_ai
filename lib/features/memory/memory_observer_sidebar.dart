import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/features/memory/memory_audit_presenter.dart';
import 'package:flutter/material.dart';

/// Wide-screen observer navigation for the permanent-memory browser.
class MemoryObserverSidebar extends StatelessWidget {
  static const width = 280.0;

  final double? sidebarWidth;
  final List<AICharacter> characters;
  final String? selectedObserverId;
  final String searchQuery;
  final bool showAll;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onClearSearch;
  final VoidCallback onSelectAll;
  final ValueChanged<String> onSelectObserver;

  const MemoryObserverSidebar({
    super.key,
    this.sidebarWidth,
    required this.characters,
    required this.selectedObserverId,
    required this.searchQuery,
    this.showAll = true,
    required this.onSearchChanged,
    required this.onClearSearch,
    required this.onSelectAll,
    required this.onSelectObserver,
  });

  @override
  Widget build(BuildContext context) {
    final visibleCharacters = _filterCharacters();
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      key: const ValueKey('memory-observer-sidebar'),
      width: sidebarWidth ?? width,
      child: Material(
        color: cs.surfaceContainerLow,
        child: SafeArea(
          right: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                child: Text(
                  '观察 AI',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: _ObserverSearchField(
                  value: searchQuery,
                  onChanged: onSearchChanged,
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.only(bottom: 16),
                  itemCount: _itemCount(visibleCharacters),
                  itemBuilder: (context, index) {
                    if (showAll && index == 0) {
                      return _ObserverNavTile(
                        key: const ValueKey('memory-observer-all'),
                        label: '全部 AI',
                        subtitle: '查看所有观察视角',
                        avatar: '',
                        avatarKey: 'all',
                        selected: selectedObserverId == null,
                        onTap: onSelectAll,
                      );
                    }
                    if (showAll && index == 1) {
                      return const Divider(height: 1);
                    }
                    if (characters.isEmpty) {
                      return const Padding(
                        padding: EdgeInsets.all(20),
                        child: Text(
                          '暂无可用观察 AI',
                          textAlign: TextAlign.center,
                        ),
                      );
                    }
                    if (visibleCharacters.isEmpty) {
                      return _searchEmpty(context, onClearSearch);
                    }
                    final character =
                        visibleCharacters[index - (showAll ? 2 : 0)];
                    return _ObserverNavTile(
                      key: ValueKey('memory-observer-${character.id}'),
                      label: _displayName(character),
                      subtitle: _characterSubtitle(character),
                      avatar: character.avatar,
                      avatarKey: character.id,
                      selected: selectedObserverId == character.id,
                      onTap: () => onSelectObserver(character.id),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<AICharacter> _filterCharacters() {
    final query = searchQuery.trim().toLowerCase();
    if (query.isEmpty) return characters;
    return characters.where((character) {
      final searchable =
          '${character.name} ${character.displayGenderLabel} ${character.role}'
              .toLowerCase();
      return searchable.contains(query);
    }).toList(growable: false);
  }

  int _itemCount(List<AICharacter> visibleCharacters) {
    final leadingItems = showAll ? 2 : 0;
    if (characters.isEmpty || visibleCharacters.isEmpty) {
      return leadingItems + 1;
    }
    return visibleCharacters.length + leadingItems;
  }
}

class _ObserverSearchField extends StatefulWidget {
  final String value;
  final ValueChanged<String> onChanged;

  const _ObserverSearchField({
    required this.value,
    required this.onChanged,
  });

  @override
  State<_ObserverSearchField> createState() => _ObserverSearchFieldState();
}

class _ObserverSearchFieldState extends State<_ObserverSearchField> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.value);

  @override
  void didUpdateWidget(covariant _ObserverSearchField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value == _controller.text) return;
    _controller.value = TextEditingValue(
      text: widget.value,
      selection: TextSelection.collapsed(offset: widget.value.length),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
        key: const ValueKey('memory-observer-search'),
        controller: _controller,
        onChanged: widget.onChanged,
        decoration: const InputDecoration(
          labelText: '搜索观察 AI',
          hintText: '名字、性别或职业',
          prefixIcon: Icon(Icons.search_rounded),
        ),
      );
}

/// Narrow-screen searchable observer picker.
class MemoryObserverSelector extends StatelessWidget {
  final List<AICharacter> characters;
  final String? selectedObserverId;
  final bool showAll;
  final VoidCallback onSelectAll;
  final ValueChanged<String> onSelectObserver;

  const MemoryObserverSelector({
    super.key,
    required this.characters,
    required this.selectedObserverId,
    this.showAll = true,
    required this.onSelectAll,
    required this.onSelectObserver,
  });

  @override
  Widget build(BuildContext context) {
    if (characters.isEmpty) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(20, 12, 20, 0),
        child: InputDecorator(
          key: ValueKey('memory-observer-selector'),
          decoration: InputDecoration(
            labelText: '观察 AI',
            helperText: '暂无可用观察 AI',
          ),
          child: Text('暂无可用观察 AI'),
        ),
      );
    }

    final choices = <_ObserverChoice>[
      if (showAll)
        const _ObserverChoice(
          id: null,
          label: '全部 AI',
          metadata: '查看所有观察视角',
        ),
      for (final character in characters)
        _ObserverChoice(
          id: character.id,
          label: _displayName(character),
          metadata: _characterSubtitle(character),
        ),
    ];
    final selected = choices.firstWhere(
      (choice) => choice.id == selectedObserverId,
      orElse: () => choices.first,
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: KeyedSubtree(
        key: const ValueKey('memory-observer-selector'),
        child: Autocomplete<_ObserverChoice>(
          key: ValueKey(
            'memory-observer-autocomplete-${selected.id ?? 'all'}',
          ),
          initialValue: TextEditingValue(text: selected.label),
          displayStringForOption: (choice) => choice.label,
          optionsBuilder: (value) {
            final query = value.text.trim().toLowerCase();
            if (query.isEmpty) return choices;
            return choices.where(
              (choice) => choice.searchableText.contains(query),
            );
          },
          onSelected: (choice) {
            if (choice.id == null) {
              onSelectAll();
            } else {
              onSelectObserver(choice.id!);
            }
          },
          fieldViewBuilder: (
            context,
            controller,
            focusNode,
            onFieldSubmitted,
          ) =>
              TextField(
            key: const ValueKey('memory-observer-search'),
            controller: controller,
            focusNode: focusNode,
            onSubmitted: (_) => onFieldSubmitted(),
            decoration: const InputDecoration(
              labelText: '观察 AI',
              hintText: '按名字、性别或职业搜索',
              prefixIcon: Icon(Icons.search_rounded),
            ),
          ),
          optionsViewBuilder: (context, onSelected, options) =>
              _observerOptionsView(context, onSelected, options),
        ),
      ),
    );
  }

  Widget _observerOptionsView(
    BuildContext context,
    AutocompleteOnSelected<_ObserverChoice> onSelected,
    Iterable<_ObserverChoice> options,
  ) {
    final materializedOptions = options.toList(growable: false);
    return Align(
      alignment: Alignment.topLeft,
      child: Material(
        elevation: 4,
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 260),
          child: ListView.builder(
            padding: EdgeInsets.zero,
            itemCount: materializedOptions.length,
            itemBuilder: (context, index) {
              final choice = materializedOptions[index];
              return ListTile(
                dense: true,
                title: Text(choice.label),
                subtitle: Text(choice.metadata),
                onTap: () => onSelected(choice),
              );
            },
          ),
        ),
      ),
    );
  }
}

String _characterSubtitle(AICharacter character) {
  final role = character.role.trim().isEmpty ? '未设置职业' : character.role;
  return '${character.displayGenderLabel} · $role';
}

String _displayName(AICharacter character) =>
    MemoryAuditPresenter.safeDisplayName(character.name, character.id);

Widget _searchEmpty(BuildContext context, VoidCallback onClearSearch) =>
    Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '没有匹配的观察 AI',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: onClearSearch,
            child: const Text('清除搜索'),
          ),
        ],
      ),
    );

class _ObserverChoice {
  final String? id;
  final String label;
  final String metadata;

  const _ObserverChoice({
    required this.id,
    required this.label,
    required this.metadata,
  });

  String get searchableText => '$label $metadata'.toLowerCase();
}

class _ObserverNavTile extends StatelessWidget {
  final String label;
  final String subtitle;
  final String avatar;
  final String avatarKey;
  final bool selected;
  final VoidCallback onTap;

  const _ObserverNavTile({
    super.key,
    required this.label,
    required this.subtitle,
    required this.avatar,
    required this.avatarKey,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final avatarText = avatar.trim().isEmpty
        ? (label == '全部 AI'
            ? null
            : (label.trim().isEmpty ? 'AI' : label.characters.first))
        : avatar.trim();
    return Container(
      decoration: BoxDecoration(
        color: selected ? cs.primaryContainer.withValues(alpha: .65) : null,
        border: Border(
          left: BorderSide(
            color: selected ? cs.primary : Colors.transparent,
            width: 3,
          ),
        ),
      ),
      child: ListTile(
        selected: selected,
        leading: CircleAvatar(
          key: ValueKey(
            'memory-observer-avatar-$avatarKey',
          ),
          radius: 16,
          backgroundColor: selected ? cs.primary : cs.surfaceContainerHighest,
          child: avatarText == null
              ? Icon(
                  Icons.groups_2_outlined,
                  size: 18,
                  color: selected ? cs.onPrimary : cs.onSurfaceVariant,
                )
              : Text(
                  avatarText,
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                  style: TextStyle(
                    color: selected ? cs.onPrimary : cs.onSurfaceVariant,
                  ),
                ),
        ),
        title: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
        onTap: onTap,
      ),
    );
  }
}

import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/features/memory/memory_audit_filter.dart';
import 'package:chat_group/features/memory/memory_audit_filter_dialog.dart';
import 'package:chat_group/features/memory/memory_audit_presenter.dart';
import 'package:flutter/material.dart';

/// Opens the one transactional filter surface used by memory entry points.
class MemoryAuditFilterWidget extends StatelessWidget {
  final MemoryAuditFilter filter;
  final List<AICharacter> characters;
  final Map<String, String> originConversations;
  final MemoryAuditPresenter? presenter;
  final MemoryConversationScope scope;
  final bool showAdvancedControls;
  final bool showNavigationSelectors;
  final ValueChanged<MemoryAuditFilter> onChanged;

  const MemoryAuditFilterWidget({
    super.key,
    required this.filter,
    required this.characters,
    this.originConversations = const {},
    this.presenter,
    this.scope = const MemoryConversationScope.settings(),
    this.showAdvancedControls = true,
    this.showNavigationSelectors = true,
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
    final conditionCount = filter.advancedCriterionCount;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
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
          if (showAdvancedControls) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                MemoryAuditFilterAction(
                  filter: filter,
                  characters: characters,
                  originConversations: originConversations,
                  presenter: _displayPresenter,
                  scope: scope,
                  showNavigationSelectors: showNavigationSelectors,
                  label: '高级筛选',
                  onChanged: onChanged,
                ),
                if (filter.hasAdvancedCriteria)
                  Text(
                    '已设置 $conditionCount 项条件',
                    key: const ValueKey('memory-filter-active-summary'),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                if (filter.hasAdvancedCriteria)
                  TextButton(
                    key: const ValueKey('clear-memory-filter'),
                    onPressed: () => onChanged(filter.clearAdvancedFilters()),
                    child: const Text('清除筛选'),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class MemoryAuditFilterAction extends StatelessWidget {
  static const _narrowBreakpoint = 600.0;

  final MemoryAuditFilter filter;
  final List<AICharacter> characters;
  final Map<String, String> originConversations;
  final MemoryAuditPresenter presenter;
  final MemoryConversationScope scope;
  final bool showNavigationSelectors;
  final String label;
  final ValueChanged<MemoryAuditFilter> onChanged;

  const MemoryAuditFilterAction({
    super.key,
    required this.filter,
    required this.characters,
    required this.originConversations,
    required this.presenter,
    required this.scope,
    this.showNavigationSelectors = true,
    required this.onChanged,
    this.label = '高级筛选',
  });

  @override
  Widget build(BuildContext context) {
    final count = filter.advancedCriterionCount;
    return Badge(
      key: const ValueKey('memory-filter-advanced-badge'),
      isLabelVisible: count > 0,
      label: Text('$count'),
      child: OutlinedButton.icon(
        key: const ValueKey('open-advanced-memory-filter'),
        onPressed: () => _showDialog(context),
        icon: const Icon(Icons.tune_rounded, size: 18),
        label: Text(label),
      ),
    );
  }

  Future<void> _showDialog(BuildContext context) async {
    final isNarrow = MediaQuery.sizeOf(context).width < _narrowBreakpoint;
    final dialog = MemoryAuditFilterDialog(
      filter: filter,
      characters: characters,
      originConversations: originConversations,
      presenter: presenter,
      scope: scope,
      inBottomSheet: isNarrow,
      showNavigationSelectors: showNavigationSelectors,
    );
    final dialogFuture = isNarrow
        ? showModalBottomSheet<MemoryAuditFilter>(
            context: context,
            isScrollControlled: true,
            useSafeArea: true,
            builder: (_) => dialog,
          )
        : showDialog<MemoryAuditFilter>(
            context: context,
            builder: (_) => dialog,
          );
    final next = await dialogFuture;
    if (context.mounted && next != null) onChanged(next);
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

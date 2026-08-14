import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/features/memory/memory_audit_presenter.dart';
import 'package:flutter/material.dart';

class MemoryIdentityHeader extends StatelessWidget {
  final AICharacter? selectedObserver;
  final int filteredCount;
  final List<Widget> actions;
  final bool isDirectScope;
  final bool isGroupScope;

  const MemoryIdentityHeader({
    super.key,
    required this.selectedObserver,
    required this.filteredCount,
    this.actions = const [],
    this.isDirectScope = false,
    this.isGroupScope = false,
  });

  @override
  Widget build(BuildContext context) {
    final selected = selectedObserver;
    final displayName = selected == null
        ? ''
        : MemoryAuditPresenter.safeDisplayName(selected.name, selected.id);
    final title = isGroupScope
        ? selected == null
            ? '群聊记忆'
            : '$displayName 的记忆'
        : selected == null
            ? '全部永久记忆'
            : isDirectScope
                ? '$displayName 对我的记忆'
                : '$displayName 的永久记忆';
    final identity = selected == null
        ? '所有观察 AI · 按观察视角聚合浏览'
        : '${selected.displayGenderLabel} · ${selected.role.trim().isEmpty ? '未设置职业' : selected.role}';
    final avatar = selected == null
        ? 'AI'
        : selected.avatar.trim().isEmpty
            ? (displayName.isEmpty ? 'AI' : displayName.characters.first)
            : selected.avatar;
    final cs = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildTitleArea(context, title, filteredCount, cs),
          const SizedBox(height: 12),
          Row(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: cs.primaryContainer,
                child: Text(
                  avatar,
                  style: TextStyle(color: cs.onPrimaryContainer),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  identity,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: cs.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTitleArea(
    BuildContext context,
    String title,
    int filteredCount,
    ColorScheme colorScheme,
  ) =>
      LayoutBuilder(
        builder: (context, constraints) {
          final titleRow = Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '$filteredCount 条记录',
                style: TextStyle(color: colorScheme.onSurfaceVariant),
              ),
            ],
          );
          if (actions.isEmpty) return titleRow;
          final actionWrap = _buildActionWrap();
          if (constraints.maxWidth < 620) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [titleRow, const SizedBox(height: 12), actionWrap],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: titleRow),
              const SizedBox(width: 16),
              Flexible(child: actionWrap),
            ],
          );
        },
      );

  Widget _buildActionWrap() => Align(
        key: const ValueKey('memory-title-actions'),
        alignment: Alignment.centerRight,
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.end,
          children: actions,
        ),
      );
}

class MemoryEmptyState extends StatelessWidget {
  final bool hasNoCharacters;
  final bool hasNoMemories;
  final bool hasSearch;
  final bool hasFilter;
  final VoidCallback onCreateCharacter;
  final VoidCallback onClearSearch;
  final VoidCallback onClearFilter;
  final VoidCallback onResetAll;
  final VoidCallback onBack;
  final String backLabel;

  const MemoryEmptyState({
    super.key,
    required this.hasNoCharacters,
    required this.hasNoMemories,
    required this.hasSearch,
    required this.hasFilter,
    required this.onCreateCharacter,
    required this.onClearSearch,
    required this.onClearFilter,
    required this.onResetAll,
    required this.onBack,
    this.backLabel = '返回设置',
  });

  @override
  Widget build(BuildContext context) {
    final copy = _copy;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 44, 24, 56),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            hasNoCharacters
                ? Icons.groups_2_outlined
                : Icons.search_off_rounded,
            size: 42,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text(
            copy.$1,
            style: Theme.of(context).textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            copy.$2,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          if (hasNoCharacters)
            FilledButton.icon(
              onPressed: onCreateCharacter,
              icon: const Icon(Icons.person_add_alt_1_rounded),
              label: const Text('去创建 AI'),
            )
          else if (hasSearch)
            TextButton(
              key: const ValueKey('clear-memory-search'),
              onPressed: onClearSearch,
              child: const Text('清除搜索'),
            )
          else if (hasFilter)
            TextButton(
              key: const ValueKey('clear-memory-filter-empty'),
              onPressed: onClearFilter,
              child: const Text('清除筛选'),
            )
          else if (!hasNoMemories)
            TextButton(
              onPressed: onResetAll,
              child: const Text('返回全部记录'),
            )
          else
            TextButton(
              onPressed: onBack,
              child: Text(backLabel),
            ),
        ],
      ),
    );
  }

  (String, String) get _copy => switch ((
        hasNoCharacters,
        hasNoMemories,
        hasSearch,
        hasFilter,
      )) {
        (true, _, _, _) => (
            '暂无可用观察 AI',
            '先创建一个 AI，才能按观察视角浏览永久记忆。',
          ),
        (_, true, _, _) => (
            '还没有永久记忆',
            '记忆会在聊天中自动整理，之后可以在这里搜索和浏览。',
          ),
        (_, _, true, _) => (
            '没有找到匹配的记忆',
            '换个关键词试试，或清除搜索后浏览全部记录。',
          ),
        (_, _, _, true) => (
            '没有符合筛选条件的记忆',
            '可以调整筛选条件，或清除筛选后继续浏览。',
          ),
        _ => (
            '没有可显示的永久记忆',
            '当前观察 AI 或对象下暂时没有记录。',
          ),
      };
}

class MemoryPageAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String? title;
  final List<Widget>? actions;

  const MemoryPageAppBar({super.key, this.title, this.actions});

  @override
  Widget build(BuildContext context) => AppBar(
        title: title == null ? null : Text(title!),
        leading: BackButton(onPressed: () => Navigator.of(context).maybePop()),
        actions: actions,
      );

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);
}

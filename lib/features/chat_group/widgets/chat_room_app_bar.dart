import 'package:chat_group/features/chat_group/widgets/wecom_chat_components.dart';
import 'package:flutter/material.dart';

class ChatRoomAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  final String? subtitle;
  final bool isSearching;
  final TextEditingController searchController;
  final bool hasSearchResults;
  final String searchResultLabel;
  final bool showGroupActions;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onEnterSearch;
  final VoidCallback onPreviousResult;
  final VoidCallback onNextResult;
  final VoidCallback onExitSearch;
  final VoidCallback onExport;
  final VoidCallback onOpenMemory;
  final VoidCallback onOpenRelationship;
  final String relationshipTooltip;
  final IconData webSearchIcon;
  final String webSearchTooltip;
  final VoidCallback onConfigureWebSearch;
  final VoidCallback? onClearConversation;
  final VoidCallback? onOpenMembers;

  const ChatRoomAppBar({
    super.key,
    required this.title,
    required this.subtitle,
    required this.isSearching,
    required this.searchController,
    required this.hasSearchResults,
    required this.searchResultLabel,
    required this.showGroupActions,
    required this.onSearchChanged,
    required this.onEnterSearch,
    required this.onPreviousResult,
    required this.onNextResult,
    required this.onExitSearch,
    required this.onExport,
    required this.onOpenMemory,
    required this.onOpenRelationship,
    required this.relationshipTooltip,
    required this.webSearchIcon,
    required this.webSearchTooltip,
    required this.onConfigureWebSearch,
    this.onClearConversation,
    this.onOpenMembers,
  });

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return AppBar(
      backgroundColor: WeComChatTokens.chatBackground(context),
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      title: isSearching
          ? _SearchField(
              controller: searchController,
              resultLabel: searchResultLabel,
              onChanged: onSearchChanged,
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 18,
                    color: colorScheme.onSurface,
                  ),
                ),
                if (subtitle != null && subtitle!.isNotEmpty)
                  Text(
                    subtitle!,
                    style: TextStyle(
                      fontSize: 12,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
      actions: isSearching
          ? [
              if (hasSearchResults) ...[
                TextButton.icon(
                  onPressed: onPreviousResult,
                  icon: const Icon(Icons.arrow_upward_rounded, size: 18),
                  label: Text(searchResultLabel),
                ),
                IconButton(
                  icon: const Icon(Icons.arrow_downward_rounded, size: 20),
                  onPressed: onNextResult,
                  tooltip: '下一个',
                ),
              ],
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 22),
                onPressed: onExitSearch,
                tooltip: '关闭搜索',
              ),
            ]
          : [
              IconButton(
                icon: const Icon(Icons.search_rounded, size: 22),
                onPressed: onEnterSearch,
                tooltip: '搜索消息',
              ),
              IconButton(
                icon: const Icon(Icons.psychology_alt_outlined, size: 22),
                onPressed: onOpenMemory,
                tooltip: '查看记忆',
              ),
              IconButton(
                icon: const Icon(Icons.favorite_border_rounded, size: 22),
                onPressed: onOpenRelationship,
                tooltip: relationshipTooltip,
              ),
              _MoreActionsButton(
                showGroupActions: showGroupActions,
                webSearchIcon: webSearchIcon,
                webSearchTooltip: webSearchTooltip,
                onConfigureWebSearch: onConfigureWebSearch,
                onClearConversation: onClearConversation,
                onExport: onExport,
                onOpenMembers: onOpenMembers,
              ),
              const SizedBox(width: 8),
            ],
    );
  }
}

enum _ChatRoomMoreAction { webSearch, clearConversation, export, members }

class _MoreActionsButton extends StatelessWidget {
  final bool showGroupActions;
  final IconData webSearchIcon;
  final String webSearchTooltip;
  final VoidCallback onConfigureWebSearch;
  final VoidCallback? onClearConversation;
  final VoidCallback onExport;
  final VoidCallback? onOpenMembers;

  const _MoreActionsButton({
    required this.showGroupActions,
    required this.webSearchIcon,
    required this.webSearchTooltip,
    required this.onConfigureWebSearch,
    required this.onClearConversation,
    required this.onExport,
    required this.onOpenMembers,
  });

  @override
  Widget build(BuildContext context) => PopupMenuButton<_ChatRoomMoreAction>(
        key: const ValueKey('chat-room-more-actions'),
        icon: const Icon(Icons.more_vert_rounded),
        tooltip: '更多操作',
        onSelected: (action) => switch (action) {
          _ChatRoomMoreAction.webSearch => onConfigureWebSearch(),
          _ChatRoomMoreAction.clearConversation => onClearConversation?.call(),
          _ChatRoomMoreAction.export => onExport(),
          _ChatRoomMoreAction.members => onOpenMembers?.call(),
        },
        itemBuilder: (context) => [
          PopupMenuItem(
            value: _ChatRoomMoreAction.webSearch,
            child: _MenuAction(icon: webSearchIcon, label: webSearchTooltip),
          ),
          if (showGroupActions && onOpenMembers != null)
            const PopupMenuItem(
              value: _ChatRoomMoreAction.members,
              child: _MenuAction(
                icon: Icons.group_outlined,
                label: '群成员',
              ),
            ),
          if (showGroupActions)
            const PopupMenuItem(
              value: _ChatRoomMoreAction.export,
              child: _MenuAction(icon: Icons.upload_rounded, label: '导出对话'),
            ),
          if (onClearConversation != null)
            const PopupMenuItem(
              value: _ChatRoomMoreAction.clearConversation,
              child: _MenuAction(
                icon: Icons.delete_sweep_outlined,
                label: '清空对话（保留记忆）',
              ),
            ),
        ],
      );
}

class _MenuAction extends StatelessWidget {
  final IconData icon;
  final String label;

  const _MenuAction({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: 12),
          Text(label),
        ],
      );
}

class _SearchField extends StatelessWidget {
  final TextEditingController controller;
  final String resultLabel;
  final ValueChanged<String> onChanged;

  const _SearchField({
    required this.controller,
    required this.resultLabel,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              hintText: '搜索消息...',
              hintStyle: TextStyle(
                color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
              ),
              border: _border(colorScheme.outlineVariant),
              enabledBorder: _border(colorScheme.outlineVariant),
              focusedBorder: _border(colorScheme.primary, width: 1.5),
              filled: true,
              fillColor: colorScheme.surfaceContainerHighest,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 8,
              ),
              isDense: true,
            ),
            onChanged: onChanged,
          ),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: colorScheme.primaryContainer.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            resultLabel,
            style: TextStyle(
              fontSize: 12,
              color: colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  static OutlineInputBorder _border(Color color, {double width = 1}) {
    return OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: color, width: width),
    );
  }
}

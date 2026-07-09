import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/features/chat_group/group_chat_inbox.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import './providers/chat_group_providers.dart';
import 'chat_group_form_page.dart';
import 'package:chat_group/core/theme/app_theme.dart';
import 'package:chat_group/core/widgets/app_widgets.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:chat_group/services/conversation_presence_service.dart';

class ChatGroupListPage extends ConsumerStatefulWidget {
  const ChatGroupListPage({super.key});

  @override
  ConsumerState<ChatGroupListPage> createState() => _ChatGroupListPageState();
}

class _ChatGroupListPageState extends ConsumerState<ChatGroupListPage> {
  late final DatabaseService _db;

  @override
  void initState() {
    super.initState();
    _db = ref.read(databaseServiceProvider);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final groups = ref.watch(chatGroupsProvider);
    final summaries = GroupChatInbox.buildSummaries(
      groups: groups,
      messages: _db.messageBox.values.toList(),
      readAtByGroup: _db.groupChatReadAtByGroup(),
      pinnedIds: _db.pinnedGroupIds(),
      activeGroupId: ConversationPresenceService.instance.activeConversationId,
    );
    final unreadCount = GroupChatInbox.totalUnread(summaries);

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        backgroundColor: cs.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                gradient: AppTheme.primaryGradient,
                borderRadius: BorderRadius.circular(9),
              ),
              child: const Icon(Icons.group_rounded,
                  size: 18, color: Colors.white),
            ),
            const SizedBox(width: 12),
            Text('群聊',
                style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 22,
                    color: cs.onSurface)),
            if (unreadCount > 0) ...[
              const SizedBox(width: 8),
              Badge(label: Text('$unreadCount')),
            ],
          ],
        ),
      ),
      body: groups.isEmpty
          ? _buildEmptyState(cs)
          : ListView.builder(
              padding: const EdgeInsets.all(20),
              itemCount: summaries.length,
              itemBuilder: (context, index) {
                final summary = summaries[index];
                final group = summary.group;
                return _GroupCard(
                  summary: summary,
                  cs: cs,
                  onTap: () => _openChat(summary),
                  onEdit: () => _editGroup(context, group),
                  onTogglePin: () => _togglePinnedGroup(group.id),
                  onDelete: () => _confirmDelete(context, ref, group),
                );
              },
            ),
      floatingActionButton: AppFab(
        onPressed: () => _addGroup(context),
        icon: Icons.add_rounded,
        label: '创建群聊',
      ),
      bottomNavigationBar: AppBottomNav(currentIndex: 1, cs: cs),
    );
  }

  Widget _buildEmptyState(ColorScheme cs) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              color: cs.primaryContainer.withOpacity(0.5),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.group_add_rounded, size: 44, color: cs.primary),
          ),
          const SizedBox(height: 24),
          Text('还没有群聊',
              style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface)),
          const SizedBox(height: 8),
          Text('点击右下角创建你的第一个 AI 群聊',
              style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant)),
        ],
      ),
    );
  }

  void _addGroup(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (context) => const ChatGroupFormPage()),
    );
  }

  void _editGroup(BuildContext context, ChatGroup group) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (context) => ChatGroupFormPage(group: group)),
    );
  }

  Future<void> _openChat(GroupChatSummary summary) async {
    await _db.markGroupChatRead(
      summary.group.id,
      readAt: _readThrough(summary.lastMessage),
    );
    if (mounted) setState(() {});
    if (!mounted) return;
    await Navigator.of(context).pushNamed('/chat/${summary.group.id}');
    if (mounted) setState(() {});
  }

  Future<void> _togglePinnedGroup(String groupId) async {
    await _db.togglePinnedGroup(groupId);
    if (mounted) setState(() {});
  }

  DateTime _readThrough(Message? lastMessage) {
    if (lastMessage == null) return DateTime.now();
    final readAt = lastMessage.timestamp.add(const Duration(milliseconds: 1));
    final now = DateTime.now();
    return readAt.isAfter(now) ? readAt : now;
  }

  Future<void> _confirmDelete(
      BuildContext context, WidgetRef ref, ChatGroup group) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: Icon(Icons.delete_outline_rounded,
            color: Theme.of(context).colorScheme.error, size: 28),
        title: Text('删除「${group.name}」？'),
        content: const Text('此操作不可撤销，该群聊的所有消息将被删除。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await ref.read(chatGroupsProvider.notifier).deleteGroup(group.id);
      if (mounted) setState(() {});
    }
  }
}

class _GroupCard extends StatelessWidget {
  final GroupChatSummary summary;
  final ColorScheme cs;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onTogglePin;
  final VoidCallback onDelete;

  const _GroupCard({
    required this.summary,
    required this.cs,
    required this.onTap,
    required this.onEdit,
    required this.onTogglePin,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final group = summary.group;
    return Dismissible(
      key: Key(group.id),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => onDelete(),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
            color: cs.errorContainer, borderRadius: BorderRadius.circular(18)),
        child: Icon(Icons.delete_outline_rounded, color: cs.error),
      ),
      child: Card(
        margin: const EdgeInsets.only(bottom: 12),
        elevation: 0,
        color: summary.hasUnread
            ? cs.primaryContainer.withOpacity(0.22)
            : cs.surfaceContainer,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(
            color: summary.hasUnread
                ? cs.primary.withOpacity(0.42)
                : cs.outlineVariant,
            width: summary.hasUnread ? 1.5 : 1,
          ),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    gradient: AppTheme.primaryGradient,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(Icons.group_rounded,
                      size: 24, color: Colors.white),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              group.name,
                              style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: cs.onSurface),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (summary.isPinned) ...[
                            const SizedBox(width: 6),
                            Icon(Icons.push_pin_rounded,
                                size: 14, color: cs.primary),
                          ],
                          if (summary.hasUnread) ...[
                            const SizedBox(width: 6),
                            Badge(label: Text('${summary.unreadCount}')),
                          ],
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        group.theme,
                        style:
                            TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (group.description.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          group.description,
                          style: TextStyle(
                              fontSize: 12,
                              color: cs.onSurfaceVariant.withOpacity(0.7)),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: cs.primaryContainer,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              '${group.aiCharacterIds.length} 个角色',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: cs.onPrimaryContainer,
                                  fontWeight: FontWeight.w500),
                            ),
                          ),
                          if (summary.hasMention)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: cs.tertiaryContainer,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                '@我 ${summary.mentionCount}',
                                style: TextStyle(
                                    fontSize: 12,
                                    color: cs.onTertiaryContainer,
                                    fontWeight: FontWeight.w600),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: Icon(
                        summary.isPinned
                            ? Icons.push_pin_rounded
                            : Icons.push_pin_outlined,
                        size: 20,
                      ),
                      onPressed: onTogglePin,
                      color:
                          summary.isPinned ? cs.primary : cs.onSurfaceVariant,
                      tooltip: summary.isPinned ? '取消置顶' : '置顶',
                    ),
                    IconButton(
                      icon: const Icon(Icons.edit_outlined, size: 20),
                      onPressed: onEdit,
                      color: cs.onSurfaceVariant,
                      tooltip: '编辑',
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline_rounded, size: 20),
                      onPressed: onDelete,
                      color: cs.error,
                      tooltip: '删除',
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

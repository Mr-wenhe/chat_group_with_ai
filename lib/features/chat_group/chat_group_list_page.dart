import 'package:chat_group/core/models/chat_group.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import './providers/chat_group_providers.dart';
import 'chat_group_form_page.dart';

class ChatGroupListPage extends ConsumerWidget {
  const ChatGroupListPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cs = Theme.of(context).colorScheme;
    final groups = ref.watch(chatGroupsProvider);

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
              decoration: BoxDecoration(color: cs.primary, borderRadius: BorderRadius.circular(8)),
              child: Icon(Icons.group_rounded, size: 18, color: cs.onPrimary),
            ),
            const SizedBox(width: 12),
            Text('群聊', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 22, color: cs.onSurface)),
          ],
        ),
      ),
      body: groups.isEmpty
          ? _buildEmptyState(cs)
          : ListView.builder(
              padding: const EdgeInsets.all(20),
              itemCount: groups.length,
              itemBuilder: (context, index) {
                final group = groups[index];
                return _GroupCard(
                  group: group,
                  cs: cs,
                  onTap: () => _openChat(context, group.id),
                  onEdit: () => _editGroup(context, group),
                  onDelete: () => _confirmDelete(context, ref, group),
                );
              },
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addGroup(context),
        backgroundColor: cs.primary,
        foregroundColor: cs.onPrimary,
        icon: const Icon(Icons.add_rounded, size: 22),
        label: const Text('创建群聊', style: TextStyle(fontWeight: FontWeight.w600)),
      ),
      bottomNavigationBar: _buildBottomNav(context, 1),
    );
  }

  Widget _buildBottomNav(BuildContext context, int currentIndex) {
    final cs = Theme.of(context).colorScheme;
    return NavigationBar(
      selectedIndex: currentIndex,
      onDestinationSelected: (i) {
        if (i != currentIndex) {
          if (i == 0) {
            Navigator.of(context).pushReplacementNamed('/');
          } else if (i == 2) {
            Navigator.of(context).pushReplacementNamed('/settings');
          }
        }
      },
      backgroundColor: cs.surface,
      indicatorColor: cs.primaryContainer,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.smart_toy_outlined, size: 22),
          selectedIcon: Icon(Icons.smart_toy_rounded, size: 22),
          label: '角色',
        ),
        NavigationDestination(
          icon: Icon(Icons.group_rounded, size: 22),
          selectedIcon: Icon(Icons.group_rounded, size: 22),
          label: '群聊',
        ),
        NavigationDestination(
          icon: Icon(Icons.settings_outlined, size: 22),
          selectedIcon: Icon(Icons.settings_rounded, size: 22),
          label: '设置',
        ),
      ],
    );
  }

  Widget _buildEmptyState(ColorScheme cs) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.group_add_rounded, size: 64, color: cs.primary.withOpacity(0.3)),
          const SizedBox(height: 24),
          Text('还没有群聊', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: cs.onSurface)),
          const SizedBox(height: 8),
          Text('点击右下角创建你的第一个 AI 群聊', style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant)),
        ],
      ),
    );
  }

  void _addGroup(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute(builder: (context) => const ChatGroupFormPage()));
  }

  void _editGroup(BuildContext context, ChatGroup group) {
    Navigator.of(context).push(MaterialPageRoute(builder: (context) => ChatGroupFormPage(group: group)));
  }

  void _openChat(BuildContext context, String groupId) {
    Navigator.of(context).pushNamed('/chat/$groupId');
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref, ChatGroup group) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: Icon(Icons.delete_outline_rounded, color: Theme.of(context).colorScheme.error, size: 28),
        title: Text('删除「${group.name}」？'),
        content: const Text('此操作不可撤销，该群聊的所有消息将被删除。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await ref.read(chatGroupsProvider.notifier).deleteGroup(group.id);
    }
  }
}

class _GroupCard extends StatelessWidget {
  final ChatGroup group;
  final ColorScheme cs;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _GroupCard({
    required this.group,
    required this.cs,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Dismissible(
      key: Key(group.id),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => onDelete(),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(color: cs.errorContainer, borderRadius: BorderRadius.circular(16)),
        child: Icon(Icons.delete_outline_rounded, color: cs.error),
      ),
      child: Card(
        margin: const EdgeInsets.only(bottom: 12),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: cs.outlineVariant, width: 1),
        ),
        color: cs.surface,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: cs.primaryContainer,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(Icons.group_rounded, size: 24, color: cs.onPrimaryContainer),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(group.name, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: cs.onSurface)),
                      const SizedBox(height: 4),
                      Text(
                        group.theme,
                        style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (group.description.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          group.description,
                          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant.withOpacity(0.7)),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                      const SizedBox(height: 6),
                      Text(
                        '${group.aiCharacterIds.length} 个角色',
                        style: TextStyle(fontSize: 12, color: cs.primary, fontWeight: FontWeight.w500),
                      ),
                    ],
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
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

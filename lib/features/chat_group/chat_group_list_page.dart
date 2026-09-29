import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/database/data_lifecycle_service.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/features/chat_group/group_chat_inbox.dart';
import 'package:chat_group/features/realtime/realtime_protocol.dart';
import 'package:chat_group/features/realtime/realtime_settings.dart';
import 'package:chat_group/features/realtime/widgets/realtime_invite_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import './providers/chat_group_providers.dart';
import 'chat_group_form_page.dart';
import 'package:chat_group/core/theme/app_theme.dart';
import 'package:chat_group/core/widgets/app_widgets.dart';
import 'package:chat_group/core/widgets/data_lifecycle_result_dialog.dart';
import 'package:chat_group/core/widgets/top_toast.dart';
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

  Future<void> _loadSummaries() async {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final groups = ref.watch(chatGroupsProvider);
    final summaries = GroupChatInbox.buildIndexedSummaries(
      groups: groups,
      records: _db.conversationSummaries(),
      messageById: _db.messageBox.get,
      pinnedIds: _db.pinnedGroupIds(),
      activeGroupId: ConversationPresenceService.instance.activeConversationId,
    );
    final unreadCount = GroupChatInbox.totalUnread(summaries);
    GroupChatSummary? firstUnreadSummary;
    for (final summary in summaries) {
      if (summary.hasUnread) {
        firstUnreadSummary = summary;
        break;
      }
    }

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
              InkWell(
                onTap: () {
                  final target = firstUnreadSummary;
                  if (target != null) _openChat(target);
                },
                borderRadius: BorderRadius.circular(12),
                child: Badge(label: Text('$unreadCount')),
              ),
            ],
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.qr_code_rounded, size: 22),
            onPressed: _joinGroup,
            tooltip: '加入群聊',
          ),
          const SizedBox(width: 4),
        ],
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
                  sharedLabel: _sharedLabelFor(group),
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
              color: cs.primaryContainer.withValues(alpha: 0.5),
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
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: _joinGroup,
            icon: const Icon(Icons.qr_code_rounded, size: 18),
            label: const Text('用邀请码加入群聊'),
          ),
        ],
      ),
    );
  }

  /// 已共享的群在列表上标出自己在这段关系里的角色；未共享的群返回 null。
  String? _sharedLabelFor(ChatGroup group) {
    if (!group.isShared) return null;
    return group.isHost(_db.realtimeUserId) ? '主人' : '客人';
  }

  void _addGroup(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (context) => const ChatGroupFormPage()),
    );
  }

  /// 客人凭邀请码加入主人的群。
  ///
  /// 本地不会因为加入而获得任何 AI 角色：客人只负责说话和看，生成发生在主人端。
  Future<void> _joinGroup() async {
    // 读配置本身也可能失败（比如设备上没有可用的安全存储）。这里不接住的话，
    // 表现是按钮点了毫无反应——用户只会以为功能坏了。
    final RealtimeSettings settings;
    try {
      settings = await ref.read(realtimeSettingsProvider.future);
    } on Object {
      if (!mounted) return;
      AppToast.show(context, '读取多人联机配置失败，请到「设置 - 多人联机」检查',
          icon: Icons.error_outline_rounded);
      return;
    }
    if (!mounted) return;
    final registration = await showDialog<RealtimeGroupRegistration>(
      context: context,
      builder: (_) => JoinGroupDialog(
        onSubmit: (code) => ref
            .read(realtimeGroupServiceProvider)
            .resolveInviteCode(settings: settings, inviteCode: code),
      ),
    );
    if (registration == null || !mounted) return;

    // 同一个房间重复加入时直接回到已有群，否则列表里会堆出一串同名群，
    // 而每个群的本地消息都是残缺的一半。
    final groups = ref.read(chatGroupsProvider);
    for (final group in groups) {
      if (group.roomId == registration.roomId) {
        await _openChatById(group.id);
        return;
      }
    }

    final group = ChatGroup(
      name: registration.name,
      theme: '多人联机',
      description: '主人：${registration.hostDisplayName}',
      // 客人本机不持有任何 AI 角色，AI 回复全部由主人端生成后广播过来。
      aiCharacterIds: const <String>[],
      // 这里的 ownerName 仍然是"本机的我"，绝不能写成主人的名字：
      // 它会被当作自己的显示名广播给其他成员，也会参与 @ 提及匹配。
      ownerName: _db.ownerNameFromProfile(),
      hostUserId: registration.hostUserId,
      roomId: registration.roomId,
      inviteCode: registration.inviteCode,
    );
    await ref.read(chatGroupsProvider.notifier).addGroup(group);
    if (!mounted) return;
    await _openChatById(group.id);
  }

  Future<void> _openChatById(String groupId) async {
    await Navigator.of(context).pushNamed('/chat/$groupId');
    await _loadSummaries();
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
    await _loadSummaries();
    if (!mounted) return;
    await Navigator.of(context).pushNamed('/chat/${summary.group.id}');
    await _loadSummaries();
  }

  Future<void> _togglePinnedGroup(String groupId) async {
    await _db.togglePinnedGroup(groupId);
    await _loadSummaries();
  }

  DateTime _readThrough(Message? lastMessage) {
    if (lastMessage == null) return DateTime.now();
    final readAt = lastMessage.timestamp.add(const Duration(milliseconds: 1));
    final now = DateTime.now();
    return readAt.isAfter(now) ? readAt : now;
  }

  Future<void> _confirmDelete(
      BuildContext context, WidgetRef ref, ChatGroup group) async {
    final plan = await DataLifecycleService(db: _db).previewGroup(group.id);
    if (!context.mounted) return;
    var deleteAssociatedPermanentData = false;
    var displayedPlan = plan;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          icon: Icon(Icons.delete_outline_rounded,
              color: Theme.of(context).colorScheme.error, size: 28),
          title: Text('删除「${group.name}」？'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '默认删除：${displayedPlan.count('messages')} 条消息、'
                    '${displayedPlan.count('groupMemories') + displayedPlan.count('characterMemories')} 条场合记忆、'
                    '${displayedPlan.count('relationships')} 条旧关系、'
                    '${displayedPlan.count('tasks')} 个任务、${displayedPlan.count('workspaces')} 条工作区记录。',
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '默认保留：${displayedPlan.retainedCount('permanentMemories')} 条永久记忆、'
                    '${displayedPlan.retainedCount('relationshipEvents')} 条关系事件、'
                    '${displayedPlan.retainedCount('globalRelationshipStates')} 条全局关系快照。',
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '可选关联删除：${displayedPlan.optionalCount('permanentMemories')} 条永久记忆、'
                    '${displayedPlan.optionalCount('relationshipEvents')} 条关系事件。',
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: deleteAssociatedPermanentData,
                    title: const Text('同时删除源自此群的永久记忆和关系事件'),
                    subtitle: const Text('只匹配来源场合 ID，未知来源和其他群/私聊数据不会删除。'),
                    onChanged: (value) async {
                      final nextValue = value ?? false;
                      final nextPlan =
                          await DataLifecycleService(db: _db).previewGroup(
                        group.id,
                        deleteAssociatedPermanentData: nextValue,
                      );
                      if (!dialogContext.mounted) return;
                      setDialogState(() {
                        deleteAssociatedPermanentData = nextValue;
                        displayedPlan = nextPlan;
                      });
                    },
                  ),
                  Text(
                    '会话状态 ${displayedPlan.count('settings')} 项，'
                    '索引 ${displayedPlan.count('sessionIndexes')} 项，'
                    '记忆 pin ${displayedPlan.count('memoryPins')} 个，'
                    '重试记录 ${displayedPlan.count('retryRecords')} 条，'
                    '附件 ${displayedPlan.count('attachments')} 个。'
                    '其中为无其他引用的 APP 附件；此操作不可撤销。',
                  ),
                ],
              ),
            ),
          ),
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
      ),
    );
    if (confirm == true) {
      final result = await ref.read(chatGroupsProvider.notifier).deleteGroup(
            group.id,
            deleteAssociatedPermanentData: deleteAssociatedPermanentData,
          );
      if (!result.isComplete && context.mounted) {
        await showIncompleteDeletionDialog(context, result);
      }
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

  /// 「主人」/「客人」，未共享的群为 null。
  final String? sharedLabel;

  const _GroupCard({
    required this.summary,
    required this.cs,
    required this.onTap,
    required this.onEdit,
    required this.onTogglePin,
    required this.onDelete,
    this.sharedLabel,
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
            ? cs.primaryContainer.withValues(alpha: 0.22)
            : cs.surfaceContainer,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(
            color: summary.hasUnread
                ? cs.primary.withValues(alpha: 0.42)
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
                              color:
                                  cs.onSurfaceVariant.withValues(alpha: 0.7)),
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
                          if (sharedLabel != null)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: cs.secondaryContainer,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.wifi_tethering_rounded,
                                      size: 12, color: cs.onSecondaryContainer),
                                  const SizedBox(width: 4),
                                  Text(
                                    sharedLabel!,
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: cs.onSecondaryContainer,
                                        fontWeight: FontWeight.w600),
                                  ),
                                ],
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

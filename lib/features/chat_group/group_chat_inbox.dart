import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/features/chat_group/chat_activity_policy.dart';
import 'package:chat_group/features/direct_chat/direct_chat_session.dart';

class GroupChatSummary {
  final ChatGroup group;
  final Message? lastMessage;
  final int unreadCount;
  final int mentionCount;
  final bool isPinned;

  const GroupChatSummary({
    required this.group,
    required this.lastMessage,
    required this.unreadCount,
    required this.mentionCount,
    required this.isPinned,
  });

  bool get hasUnread => unreadCount > 0;
  bool get hasMention => mentionCount > 0;
}

class GroupChatInbox {
  static List<GroupChatSummary> buildIndexedSummaries({
    required List<ChatGroup> groups,
    required Map<String, ConversationSummaryRecord> records,
    required Message? Function(String id) messageById,
    required Set<String> pinnedIds,
    String? activeGroupId,
  }) {
    final summaries = groups.map((group) {
      final record = records[group.id];
      final active = activeGroupId == group.id;
      return GroupChatSummary(
        group: group,
        lastMessage: record?.lastMessageId == null
            ? null
            : messageById(record!.lastMessageId!),
        unreadCount: active ? 0 : record?.unreadCount ?? 0,
        mentionCount: active ? 0 : record?.mentionCount ?? 0,
        isPinned: pinnedIds.contains(group.id),
      );
    }).toList();
    summaries.sort((a, b) {
      if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
      final aTime = records[a.group.id]?.timestamp ?? a.group.createdAt;
      final bTime = records[b.group.id]?.timestamp ?? b.group.createdAt;
      return bTime.compareTo(aTime);
    });
    return summaries;
  }

  /// **Stage 16 退役**：此方法不再从 [ChatGroup.ownerName] 读取真人名称，
  /// 改为接收 [userDisplayName] 参数（应来自 [UserProfile.displayName]）。
  /// 保留方法供测试和兼容诊断使用；运行时收件箱走 [buildIndexedSummaries]。
  static List<GroupChatSummary> buildSummaries({
    required List<ChatGroup> groups,
    required List<Message> messages,
    required Map<String, DateTime> readAtByGroup,
    required Set<String> pinnedIds,
    String? activeGroupId,
    String userDisplayName = '我',
  }) {
    final messagesByGroup = <String, List<Message>>{};
    for (final message in messages) {
      if (DirectChatSession.isDirectConversationId(message.groupId)) continue;
      messagesByGroup
          .putIfAbsent(message.groupId, () => <Message>[])
          .add(message);
    }

    final summaries = groups.map((group) {
      final groupMessages = messagesByGroup[group.id] ?? const <Message>[];
      final sortedMessages = groupMessages.toList()
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
      final readAt = readAtByGroup[group.id];
      final unreadMessages = sortedMessages.where((message) {
        if (group.id == activeGroupId) return false;
        if (message.senderType != 'ai') return false;
        if (readAt == null) return true;
        return message.timestamp.isAfter(readAt);
      }).toList();
      final mentionCount = unreadMessages.where((message) {
        return ChatActivityPolicy.contentMentionsUser(
          message.content,
          userDisplayName.trim().isEmpty ? '我' : userDisplayName.trim(),
        );
      }).length;
      return GroupChatSummary(
        group: group,
        lastMessage: sortedMessages.isEmpty ? null : sortedMessages.last,
        unreadCount: unreadMessages.length,
        mentionCount: mentionCount,
        isPinned: pinnedIds.contains(group.id),
      );
    }).toList();

    summaries.sort((a, b) {
      if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
      final aTime = a.lastMessage?.timestamp ?? a.group.createdAt;
      final bTime = b.lastMessage?.timestamp ?? b.group.createdAt;
      return bTime.compareTo(aTime);
    });
    return summaries;
  }

  static int totalUnread(List<GroupChatSummary> summaries) {
    return summaries.fold(0, (total, summary) => total + summary.unreadCount);
  }
}

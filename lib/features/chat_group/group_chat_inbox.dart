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
  static List<GroupChatSummary> buildSummaries({
    required List<ChatGroup> groups,
    required List<Message> messages,
    required Map<String, DateTime> readAtByGroup,
    required Set<String> pinnedIds,
    String? activeGroupId,
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
          group.ownerName.trim().isEmpty ? '我' : group.ownerName.trim(),
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

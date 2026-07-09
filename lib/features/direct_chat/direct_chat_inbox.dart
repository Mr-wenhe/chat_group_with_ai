import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/direct_chat_source.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/features/direct_chat/direct_chat_session.dart';

export 'package:chat_group/core/models/direct_chat_source.dart';

class DirectChatSummary {
  final String conversationId;
  final AICharacter character;
  final Message lastMessage;
  final int unreadCount;
  final DirectChatSource source;
  final bool hasUserMessage;
  final DateTime? lastUserMessageAt;

  const DirectChatSummary({
    required this.conversationId,
    required this.character,
    required this.lastMessage,
    required this.unreadCount,
    required this.source,
    this.hasUserMessage = false,
    this.lastUserMessageAt,
  });

  bool get hasUnread => unreadCount > 0;
}

class DirectChatInbox {
  static List<DirectChatSummary> buildSummaries({
    required List<AICharacter> characters,
    required List<Message> messages,
    required Map<String, DateTime> readAtByConversation,
    required Map<String, DirectChatSource> sourceByConversation,
    String? activeConversationId,
  }) {
    final charactersById = {
      for (final character in characters) character.id: character
    };
    final messagesByConversation = <String, List<Message>>{};

    for (final message in messages) {
      if (!DirectChatSession.isDirectConversationId(message.groupId)) {
        continue;
      }
      final characterId = DirectChatSession.characterIdFrom(message.groupId);
      if (characterId == null || !charactersById.containsKey(characterId)) {
        continue;
      }
      messagesByConversation
          .putIfAbsent(message.groupId, () => <Message>[])
          .add(message);
    }

    final summaries = <DirectChatSummary>[];
    for (final entry in messagesByConversation.entries) {
      final conversationMessages = entry.value
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
      if (conversationMessages.isEmpty) continue;
      final characterId = DirectChatSession.characterIdFrom(entry.key);
      final character =
          characterId == null ? null : charactersById[characterId];
      if (character == null) continue;
      final readAt = readAtByConversation[entry.key];
      final userMessages = conversationMessages
          .where((message) => message.senderType == 'user')
          .toList();
      final lastUserMessageAt =
          userMessages.isEmpty ? null : userMessages.last.timestamp;
      final unreadCount = conversationMessages.where((message) {
        if (entry.key == activeConversationId) return false;
        if (message.senderType != 'ai') return false;
        if (readAt == null) return true;
        return message.timestamp.isAfter(readAt);
      }).length;
      summaries.add(DirectChatSummary(
        conversationId: entry.key,
        character: character,
        lastMessage: conversationMessages.last,
        unreadCount: unreadCount,
        source: sourceByConversation[entry.key] ?? DirectChatSource.direct,
        hasUserMessage: userMessages.isNotEmpty,
        lastUserMessageAt: lastUserMessageAt,
      ));
    }

    summaries.sort(
      (a, b) => b.lastMessage.timestamp.compareTo(a.lastMessage.timestamp),
    );
    return summaries;
  }

  static int totalUnread(List<DirectChatSummary> summaries) {
    return summaries.fold(0, (total, summary) => total + summary.unreadCount);
  }
}

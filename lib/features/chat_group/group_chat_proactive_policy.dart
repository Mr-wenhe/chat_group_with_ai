import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/features/direct_chat/direct_chat_session.dart';

class GroupChatProactiveCandidate {
  final ChatGroup group;
  final AICharacter character;
  final String reason;

  const GroupChatProactiveCandidate({
    required this.group,
    required this.character,
    required this.reason,
  });
}

class GroupChatProactivePolicy {
  static const Duration proactiveCooldown = Duration(minutes: 45);
  static const Duration recentAiQuietPeriod = Duration(minutes: 20);

  static GroupChatProactiveCandidate? selectCandidate({
    required List<ChatGroup> groups,
    required Map<String, AICharacter> charactersById,
    required List<Message> messages,
    required Map<String, DateTime> readAtByGroup,
    required Map<String, DateTime> lastProactiveAtByGroup,
    required DateTime now,
  }) {
    for (final group in groups) {
      final groupMessages = messages
          .where((message) =>
              message.groupId == group.id &&
              !DirectChatSession.isDirectConversationId(message.groupId))
          .toList()
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
      if (_hasUnreadAiMessage(group.id, groupMessages, readAtByGroup)) {
        continue;
      }
      final lastProactiveAt = lastProactiveAtByGroup[group.id];
      if (lastProactiveAt != null &&
          now.difference(lastProactiveAt) < proactiveCooldown) {
        continue;
      }
      if (groupMessages.isNotEmpty) {
        final last = groupMessages.last;
        if (last.senderType == 'ai' &&
            now.difference(last.timestamp) < recentAiQuietPeriod) {
          continue;
        }
      }

      final character = _speakerFor(group, charactersById, groupMessages);
      if (character == null) continue;
      return GroupChatProactiveCandidate(
        group: group,
        character: character,
        reason: groupMessages.isEmpty ? '群聊破冰' : '延续群聊话题',
      );
    }
    return null;
  }

  static bool _hasUnreadAiMessage(
    String groupId,
    List<Message> messages,
    Map<String, DateTime> readAtByGroup,
  ) {
    final readAt = readAtByGroup[groupId];
    return messages.any((message) {
      if (message.senderType != 'ai') return false;
      if (readAt == null) return true;
      return message.timestamp.isAfter(readAt);
    });
  }

  static AICharacter? _speakerFor(
    ChatGroup group,
    Map<String, AICharacter> charactersById,
    List<Message> messages,
  ) {
    final activeCharacters = group.aiCharacterIds
        .map((id) => charactersById[id])
        .whereType<AICharacter>()
        .where((character) => character.isActive)
        .toList();
    if (activeCharacters.isEmpty) return null;

    final lastAiSenderId = messages.reversed
        .where((message) => message.senderType == 'ai')
        .map((message) => message.senderId)
        .firstOrNull;
    return activeCharacters.firstWhere(
      (character) => character.id != lastAiSenderId,
      orElse: () => activeCharacters.first,
    );
  }
}

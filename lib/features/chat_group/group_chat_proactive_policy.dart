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
  static const Duration proactiveCooldown = Duration(minutes: 2);
  static const Duration recentAiQuietPeriod = Duration(seconds: 45);
  static const int maxUnreadBurstMessages = 5;

  static GroupChatProactiveCandidate? selectCandidate({
    required List<ChatGroup> groups,
    required Map<String, AICharacter> charactersById,
    required List<Message> messages,
    required Map<String, DateTime> readAtByGroup,
    required Map<String, DateTime> lastProactiveAtByGroup,
    required DateTime now,
    String? activeGroupId,
    String? preferredGroupId,
  }) {
    final orderedGroups = groups.toList();
    if (preferredGroupId != null) {
      orderedGroups.sort((a, b) {
        if (a.id == preferredGroupId) return -1;
        if (b.id == preferredGroupId) return 1;
        return 0;
      });
    }

    for (final group in orderedGroups) {
      if (group.id == activeGroupId) continue;
      final isPreferred = group.id == preferredGroupId;
      final groupMessages = messages
          .where((message) =>
              message.groupId == group.id &&
              !DirectChatSession.isDirectConversationId(message.groupId))
          .toList()
        ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
      if (_unreadAiCount(group.id, groupMessages, readAtByGroup) >=
          maxUnreadBurstMessages) {
        continue;
      }
      final lastProactiveAt = lastProactiveAtByGroup[group.id];
      final cooldown =
          isPreferred ? _handoffCooldownFor(group) : _cooldownFor(group);
      if (lastProactiveAt != null &&
          now.difference(lastProactiveAt) < cooldown) {
        continue;
      }
      if (groupMessages.isNotEmpty) {
        final last = groupMessages.last;
        final quietPeriod = isPreferred
            ? _handoffQuietPeriodFor(group)
            : _quietPeriodFor(group);
        if (last.senderType == 'ai' &&
            now.difference(last.timestamp) < quietPeriod) {
          continue;
        }
      }

      final character = _speakerFor(group, charactersById, groupMessages);
      if (character == null) continue;
      return GroupChatProactiveCandidate(
        group: group,
        character: character,
        reason: isPreferred
            ? '用户离开后继续推进群聊'
            : groupMessages.isEmpty
                ? '群聊破冰'
                : '延续群聊话题',
      );
    }
    return null;
  }

  static int _unreadAiCount(
    String groupId,
    List<Message> messages,
    Map<String, DateTime> readAtByGroup,
  ) {
    final readAt = readAtByGroup[groupId];
    return messages.where((message) {
      if (message.senderType != 'ai') return false;
      if (readAt == null) return true;
      return message.timestamp.isAfter(readAt);
    }).length;
  }

  static Duration _cooldownFor(ChatGroup group) {
    final seconds = (group.replyIntervalSeconds * 4).clamp(
      proactiveCooldown.inSeconds,
      600,
    );
    return Duration(seconds: seconds);
  }

  static Duration _quietPeriodFor(ChatGroup group) {
    final seconds = group.replyIntervalSeconds.clamp(
      recentAiQuietPeriod.inSeconds,
      300,
    );
    return Duration(seconds: seconds);
  }

  static Duration _handoffCooldownFor(ChatGroup group) {
    final seconds = (group.replyIntervalSeconds * 2).clamp(12, 120);
    return Duration(seconds: seconds);
  }

  static Duration _handoffQuietPeriodFor(ChatGroup group) {
    final seconds = group.replyIntervalSeconds.clamp(5, 60);
    return Duration(seconds: seconds);
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

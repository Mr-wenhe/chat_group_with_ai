import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/features/direct_chat/direct_chat_inbox.dart';

class DirectChatProactiveCandidate {
  final AICharacter character;
  final DirectChatSource source;
  final String reason;

  const DirectChatProactiveCandidate({
    required this.character,
    required this.source,
    required this.reason,
  });
}

class DirectChatProactivePolicy {
  static const Duration directChatStaleAfter = Duration(hours: 6);
  static const Duration proactiveCooldown = Duration(hours: 2);
  static const Duration recentGroupWindow = Duration(hours: 1);

  static DirectChatProactiveCandidate? selectCandidate({
    required List<DirectChatSummary> directSummaries,
    required List<AICharacter> groupCharacters,
    required List<Message> recentGroupMessages,
    required Map<String, DateTime> lastProactiveAtByCharacter,
    required DateTime now,
  }) {
    final staleDirectCandidates = directSummaries.where((summary) {
      if (!_canProactivelySpeak(
        summary.character,
        lastProactiveAtByCharacter,
        now,
      )) {
        return false;
      }
      if (summary.hasUnread) return false;
      if (summary.lastMessage.senderType != 'user') return false;
      return now.difference(summary.lastMessage.timestamp) >=
          directChatStaleAfter;
    }).toList();

    if (staleDirectCandidates.isNotEmpty) {
      staleDirectCandidates.sort(
          (a, b) => a.lastMessage.timestamp.compareTo(b.lastMessage.timestamp));
      final summary = staleDirectCandidates.first;
      return DirectChatProactiveCandidate(
        character: summary.character,
        source: DirectChatSource.direct,
        reason: '延续上次私聊',
      );
    }

    final existingDirectIds =
        directSummaries.map((summary) => summary.character.id).toSet();

    final hasRecentUserGroupMessage = recentGroupMessages.any((message) {
      return message.senderType == 'user' &&
          now.difference(message.timestamp) <= recentGroupWindow;
    });
    if (!hasRecentUserGroupMessage) return null;

    final groupCandidate = groupCharacters.where((character) {
      if (existingDirectIds.contains(character.id)) return false;
      return _canProactivelySpeak(character, lastProactiveAtByCharacter, now);
    }).firstOrNull;

    if (groupCandidate == null) return null;
    return DirectChatProactiveCandidate(
      character: groupCandidate,
      source: DirectChatSource.group,
      reason: '从群聊话题延伸',
    );
  }

  static bool _canProactivelySpeak(
    AICharacter character,
    Map<String, DateTime> lastProactiveAtByCharacter,
    DateTime now,
  ) {
    if (!character.isActive) return false;
    final lastAt = lastProactiveAtByCharacter[character.id];
    if (lastAt == null) return true;
    return now.difference(lastAt) >= proactiveCooldown;
  }
}

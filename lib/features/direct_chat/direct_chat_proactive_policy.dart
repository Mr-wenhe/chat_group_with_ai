import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/features/direct_chat/direct_chat_inbox.dart';

class DirectChatProactiveCandidate {
  final AICharacter character;
  final DirectChatSource source;
  final String reason;
  final String? sourceGroupId;
  final DateTime? sourceUserMessageAt;

  const DirectChatProactiveCandidate({
    required this.character,
    required this.source,
    required this.reason,
    this.sourceGroupId,
    this.sourceUserMessageAt,
  });
}

class DirectChatGroupCandidate {
  final AICharacter character;
  final String groupId;
  final DateTime lastUserMessageAt;

  const DirectChatGroupCandidate({
    required this.character,
    required this.groupId,
    required this.lastUserMessageAt,
  });
}

class DirectChatProactivePolicy {
  static const Duration directChatStaleAfter = Duration(hours: 6);
  static const Duration proactiveCooldown = Duration(hours: 2);
  static const Duration recentGroupWindow = Duration(hours: 1);

  static DirectChatProactiveCandidate? selectCandidate({
    required List<DirectChatSummary> directSummaries,
    required List<DirectChatGroupCandidate> groupCandidates,
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
      if (!summary.hasUserMessage) return false;
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

    final eligibleGroupCandidates = groupCandidates.where((candidate) {
      if (existingDirectIds.contains(candidate.character.id)) return false;
      if (now.difference(candidate.lastUserMessageAt) > recentGroupWindow) {
        return false;
      }
      return _canProactivelySpeak(
        candidate.character,
        lastProactiveAtByCharacter,
        now,
      );
    }).toList()
      ..sort((a, b) => b.lastUserMessageAt.compareTo(a.lastUserMessageAt));

    if (eligibleGroupCandidates.isEmpty) return null;
    final groupCandidate = eligibleGroupCandidates.first;
    return DirectChatProactiveCandidate(
      character: groupCandidate.character,
      source: DirectChatSource.group,
      reason: '从群聊话题延伸',
      sourceGroupId: groupCandidate.groupId,
      sourceUserMessageAt: groupCandidate.lastUserMessageAt,
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

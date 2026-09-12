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

/// Foreground polling cadence shared by the watcher and policy tests.
///
/// Keeping these values in the platform-neutral policy layer makes the same
/// proactive behavior available on Windows, macOS, Linux and mobile.
class ProactiveContactSchedule {
  static const Duration initialDelay = Duration(seconds: 8);
  static const Duration interval = Duration(seconds: 45);
  static const Duration handoffDelay = Duration(seconds: 8);
}

class DirectChatProactivePolicy {
  static const Duration directChatStaleAfter = Duration(hours: 6);
  static const Duration proactiveCooldown = Duration(hours: 2);
  static const Duration unreadFollowUpDelay = Duration(minutes: 8);
  static const Duration handoffFollowUpDelay = Duration(seconds: 20);
  static const Duration recentGroupWindow = Duration(hours: 1);
  static const int maxUnreadBurstMessages = 3;

  static DirectChatProactiveCandidate? selectCandidate({
    required List<DirectChatSummary> directSummaries,
    required List<DirectChatGroupCandidate> groupCandidates,
    List<AICharacter> idleCharacters = const [],
    required Map<String, DateTime> lastProactiveAtByCharacter,
    required DateTime now,
    String? preferredConversationId,
  }) {
    final preferredCandidate = _preferredDirectCandidate(
      directSummaries,
      lastProactiveAtByCharacter,
      now,
      preferredConversationId,
    );
    if (preferredCandidate != null) return preferredCandidate;

    final staleDirectCandidates = directSummaries.where((summary) {
      if (!summary.hasUserMessage) return false;
      if (summary.hasUnread) {
        return _canContinueUnreadBurst(
          summary,
          lastProactiveAtByCharacter,
          now,
        );
      }
      if (!_canProactivelySpeak(
        summary.character,
        lastProactiveAtByCharacter,
        now,
      )) {
        return false;
      }
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

    if (eligibleGroupCandidates.isNotEmpty) {
      final groupCandidate = eligibleGroupCandidates.first;
      return DirectChatProactiveCandidate(
        character: groupCandidate.character,
        source: DirectChatSource.group,
        reason: '从群聊话题延伸',
        sourceGroupId: groupCandidate.groupId,
        sourceUserMessageAt: groupCandidate.lastUserMessageAt,
      );
    }

    // A character without any previous DM/group history may still initiate a
    // first conversation. Once that happens it appears in directSummaries and
    // is governed by the regular stale/unread policies above.
    for (final character in idleCharacters) {
      if (existingDirectIds.contains(character.id)) continue;
      if (!_canProactivelySpeak(
        character,
        lastProactiveAtByCharacter,
        now,
      )) {
        continue;
      }
      return DirectChatProactiveCandidate(
        character: character,
        source: DirectChatSource.direct,
        reason: '主动问候',
      );
    }
    return null;
  }

  static bool _canProactivelySpeak(
    AICharacter character,
    Map<String, DateTime> lastProactiveAtByCharacter,
    DateTime now,
  ) {
    if (!character.isActive || !character.proactiveChatEnabled) return false;
    final lastAt = lastProactiveAtByCharacter[character.id];
    if (lastAt == null) return true;
    return now.difference(lastAt) >= proactiveCooldown;
  }

  static DirectChatProactiveCandidate? _preferredDirectCandidate(
    List<DirectChatSummary> summaries,
    Map<String, DateTime> lastProactiveAtByCharacter,
    DateTime now,
    String? preferredConversationId,
  ) {
    if (preferredConversationId == null) return null;
    final summary = summaries
        .where((item) => item.conversationId == preferredConversationId)
        .firstOrNull;
    if (summary == null) return null;
    if (!summary.hasUserMessage ||
        !summary.character.isActive ||
        !summary.character.proactiveChatEnabled) {
      return null;
    }
    if (summary.unreadCount >= maxUnreadBurstMessages) return null;

    final lastAt = lastProactiveAtByCharacter[summary.character.id];
    if (lastAt != null && now.difference(lastAt) < handoffFollowUpDelay) {
      return null;
    }
    if (summary.lastMessage.senderType == 'ai' &&
        now.difference(summary.lastMessage.timestamp) < handoffFollowUpDelay) {
      return null;
    }

    return DirectChatProactiveCandidate(
      character: summary.character,
      source: DirectChatSource.direct,
      reason: '用户离开后继续私聊',
    );
  }

  static bool _canContinueUnreadBurst(
    DirectChatSummary summary,
    Map<String, DateTime> lastProactiveAtByCharacter,
    DateTime now,
  ) {
    if (!summary.character.isActive || !summary.character.proactiveChatEnabled) {
      return false;
    }
    if (summary.unreadCount >= maxUnreadBurstMessages) return false;
    if (summary.lastMessage.senderType != 'ai') return false;
    if (now.difference(summary.lastMessage.timestamp) < unreadFollowUpDelay) {
      return false;
    }
    final lastAt = lastProactiveAtByCharacter[summary.character.id];
    if (lastAt == null) return true;
    return now.difference(lastAt) >= unreadFollowUpDelay;
  }
}

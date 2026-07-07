import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/message.dart';

/// Pure orchestration helpers for chat room logic.
/// Extracted from _ChatRoomPageState so they can be unit-tested without Flutter.
class ChatOrchestrator {
  static bool isEligibleToReply(AICharacter character) {
    if (!character.isActive) return false;
    if (character.apiKey.isEmpty) return false;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final last = character.lastReplyTimestamp;
    if (last == null) return true;
    final lastDay = DateTime(last.year, last.month, last.day);
    if (lastDay != today) return true;
    final diff = now.difference(last).inMinutes;
    if (diff >= 60) return true;
    return character.hourlyReplyCount < character.hourlyReplyLimit;
  }

  static String? blockReasonFor(AICharacter character) {
    if (!character.isActive) return 'inactive';
    if (character.apiKey.isEmpty) return 'noApiConfig';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final last = character.lastReplyTimestamp;
    if (last == null) return null;
    final lastDay = DateTime(last.year, last.month, last.day);
    if (lastDay != today) return null;
    final diff = now.difference(last).inMinutes;
    if (diff >= 60) return null;
    return character.hourlyReplyCount < character.hourlyReplyLimit
        ? null
        : 'hourlyLimit';
  }

  static void recordReplyUsage(AICharacter character) {
    final now = DateTime.now();
    final last = character.lastReplyTimestamp;
    final sameDay = last != null &&
        last.year == now.year &&
        last.month == now.month &&
        last.day == now.day;
    final withinHour = last != null && now.difference(last).inMinutes < 60;
    if (!sameDay || !withinHour) {
      character.hourlyReplyCount = 1;
    } else {
      character.hourlyReplyCount += 1;
    }
    character.lastReplyTimestamp = now;
  }

  static String extractRecentFocus(List<Message> messages) {
    if (messages.isEmpty) return '';
    final recent = messages.length > 3 ? messages.sublist(messages.length - 3) : messages;
    final joined = recent.map((m) => m.content).join(' → ');
    if (joined.length > 200) {
      return '\n\n【当前对话焦点】最近大家在聊：${joined.substring(0, 200)}...';
    }
    return '\n\n【当前对话焦点】最近大家在聊：$joined';
  }

  static String stripNamePrefix(String content, String characterName) {
    final prefixes = [
      '$characterName：',
      '$characterName:',
      '【$characterName】',
      '[$characterName]',
    ];
    for (final p in prefixes) {
      if (content.startsWith(p)) return content.substring(p.length);
    }
    return content;
  }
}

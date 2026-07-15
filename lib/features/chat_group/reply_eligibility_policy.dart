import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';

enum ReplyBlockReason {
  noApiConfig,
  inactive,
  hourlyLimit,
  alreadyGenerating,
  networkError,
}

typedef ApiConfigResolver = ApiConfig? Function(AICharacter character);

/// Centralizes reply eligibility and usage accounting for every chat entry.
class ReplyEligibilityPolicy {
  final ApiConfigResolver resolveApiConfig;
  final DateTime Function() now;

  ReplyEligibilityPolicy({
    required this.resolveApiConfig,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;

  bool isEligible(AICharacter character) => blockReasonFor(character) == null;

  ReplyBlockReason? blockReasonFor(AICharacter character) {
    if (!character.isActive) return ReplyBlockReason.inactive;
    final config = resolveApiConfig(character);
    if (config == null || !config.hasCredential) {
      return ReplyBlockReason.noApiConfig;
    }

    final current = now();
    final last = character.lastReplyTimestamp;
    if (last == null || !_isSameDay(last, current)) return null;
    if (current.difference(last).inMinutes >= 60) return null;
    return character.hourlyReplyCount < character.hourlyReplyLimit
        ? null
        : ReplyBlockReason.hourlyLimit;
  }

  ReplyBlockReason? firstBlockReason(List<AICharacter> characters) {
    if (characters.isEmpty) return null;
    final reasons = characters
        .map(blockReasonFor)
        .whereType<ReplyBlockReason>()
        .toList(growable: false);
    if (reasons.isEmpty) return null;
    for (final reason in const [
      ReplyBlockReason.noApiConfig,
      ReplyBlockReason.inactive,
      ReplyBlockReason.hourlyLimit,
    ]) {
      if (reasons.every((candidate) => candidate == reason)) return reason;
    }
    return reasons.first;
  }

  void recordReplyUsage(AICharacter character) {
    final current = now();
    final last = character.lastReplyTimestamp;
    final withinHour = last != null && current.difference(last).inMinutes < 60;
    if (last == null || !_isSameDay(last, current) || !withinHour) {
      character.hourlyReplyCount = 1;
    } else {
      character.hourlyReplyCount += 1;
    }
    character.lastReplyTimestamp = current;
  }

  static bool _isSameDay(DateTime first, DateTime second) =>
      first.year == second.year &&
      first.month == second.month &&
      first.day == second.day;
}

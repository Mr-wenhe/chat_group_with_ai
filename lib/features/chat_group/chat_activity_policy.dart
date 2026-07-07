import 'dart:math';

import 'package:chat_group/core/models/ai_character.dart';

class ChatActivityPolicy {
  static const int defaultMaxReplyCount = 2;

  static List<AICharacter> selectUserReplyCharacters({
    required List<AICharacter> characters,
    required List<String> mentionedIds,
    required List<String> pendingMentionedIds,
    required bool Function(AICharacter character) isEligible,
    Random? random,
    int maxReplyCount = defaultMaxReplyCount,
  }) {
    final eligible = characters.where(isEligible).toList();
    if (eligible.isEmpty || maxReplyCount <= 0) return const [];

    final selected = <AICharacter>[];
    void addById(String id) {
      if (selected.length >= maxReplyCount) return;
      for (final character in eligible) {
        if (character.id == id && !selected.any((c) => c.id == id)) {
          selected.add(character);
          return;
        }
      }
    }

    for (final id in mentionedIds) {
      addById(id);
    }
    for (final id in pendingMentionedIds) {
      addById(id);
    }

    final desiredCount = min(maxReplyCount, eligible.length);
    final remaining = _shuffled(
      eligible.where((c) => !selected.any((s) => s.id == c.id)).toList(),
      random ?? Random(),
    );
    for (final character in remaining) {
      if (selected.length >= desiredCount) break;
      selected.add(character);
    }

    return selected;
  }

  static List<AICharacter> selectAutoChatSpeakers({
    required List<AICharacter> characters,
    required bool Function(AICharacter character) isEligible,
    Random? random,
    int maxSpeakerCount = defaultMaxReplyCount,
  }) {
    final eligible = characters.where(isEligible).toList();
    if (eligible.isEmpty || maxSpeakerCount <= 0) return const [];

    final rng = random ?? Random();
    final maxCount = min(maxSpeakerCount, eligible.length);
    final count = maxCount == 1 ? 1 : 1 + rng.nextInt(maxCount);
    return _shuffled(eligible, rng).take(count).toList();
  }

  static String emptyReplyFallback({
    required String characterName,
    required String role,
    required String groupTheme,
    String? userMessage,
    bool isAutoChat = false,
    Random? random,
  }) {
    final rng = random ?? Random();
    final topic = groupTheme.trim().isEmpty ? '这个话题' : groupTheme.trim();
    final hasUserMsg = userMessage != null && userMessage.trim().isNotEmpty;
    final templates = hasUserMsg
        ? [
            '说到$topic，我觉得可以先听听其他人的看法。',
            '这个问题嘛，$topic 其实可以从好几个角度来看。',
            '我接一下，$topic 这个话题挺有意思的，展开聊聊？',
          ]
        : [
            '说到$topic，大家最近有什么新想法吗？',
            '在$topic 这个话题上，我有点不同的看法，想听听你们的。',
            '最近$topic 有什么新鲜事吗？聊两句呗。',
          ];
    return templates[rng.nextInt(templates.length)];
  }

  static List<T> _shuffled<T>(List<T> list, Random random) {
    final copy = List<T>.from(list);
    for (var i = copy.length - 1; i > 0; i--) {
      final j = random.nextInt(i + 1);
      final tmp = copy[i];
      copy[i] = copy[j];
      copy[j] = tmp;
    }
    return copy;
  }
}

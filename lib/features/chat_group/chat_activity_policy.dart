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
    final persona = role.trim().isEmpty ? '群友' : role.trim();
    final addressed = userMessage != null && userMessage.trim().isNotEmpty;
    final templates = addressed
        ? [
            '$characterName：我先接一下，$topic 里我最在意稳定性和响应速度，远程时突然掉线真的很影响节奏。',
            '$characterName：从$persona的角度看，先把连接权限、网络状态和画质模式检查一遍，很多问题都出在这几处。',
            '$characterName：我会先问一句：是在同一网络下慢，还是跨网远控慢？这俩排查方向不太一样。',
          ]
        : [
            '$characterName：我抛个话题，$topic 你们更看重连接速度、画质，还是安全权限？',
            '$characterName：刚想到一个点，远控工具好不好用，很多时候不只看功能，还看关键时刻稳不稳。',
            '$characterName：如果是日常使用，我觉得可以聊聊大家最常用的场景，办公、帮家里人修电脑，还是临时传文件？',
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

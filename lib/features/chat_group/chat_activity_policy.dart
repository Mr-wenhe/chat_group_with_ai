import 'dart:math';

import 'package:chat_group/core/models/ai_character.dart';

class ChatActivityPolicy {
  static const int defaultMaxReplyCount = 2;
  static const int groupAddressedMaxReplyCount = 4;
  static const int minReplyDelayMs = 1200;
  static const int maxReplyDelayMs = 8500;
  static const int replyDelayMsPerCharacter = 45;
  static const int replyDelayJitterMs = 900;

  static bool canStartAutoChat({
    required bool workModeEnabled,
    required bool autoChatEnabled,
    required bool hasCharacters,
    required bool hasApiConfig,
  }) =>
      !workModeEnabled && autoChatEnabled && hasCharacters && hasApiConfig;

  static List<AICharacter> selectUserReplyCharacters({
    required List<AICharacter> characters,
    required List<String> mentionedIds,
    required List<String> pendingMentionedIds,
    required bool Function(AICharacter character) isEligible,
    Random? random,
    int maxReplyCount = defaultMaxReplyCount,
    bool isGroupAddressed = false,
  }) {
    final eligible = characters.where(isEligible).toList();
    if (eligible.isEmpty || maxReplyCount <= 0) return const [];

    final selected = <AICharacter>[];
    final replyCap = isGroupAddressed
        ? max(maxReplyCount, groupAddressedMaxReplyCount)
        : maxReplyCount;
    final effectiveMaxReplyCount =
        min(eligible.length, max(replyCap, mentionedIds.length));
    final eligibleById = {for (final c in eligible) c.id: c};
    final selectedIds = <String>{};
    void addById(String id) {
      if (selected.length >= effectiveMaxReplyCount) return;
      if (!selectedIds.add(id)) return;
      final character = eligibleById[id];
      if (character != null) selected.add(character);
    }

    for (final id in mentionedIds) {
      addById(id);
    }
    for (final id in pendingMentionedIds) {
      addById(id);
    }

    final desiredCount = effectiveMaxReplyCount;
    final remaining = _shuffled(
      eligible.where((c) => !selectedIds.contains(c.id)).toList(),
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

  static Duration replyDelayForContent(String content, {Random? random}) {
    final visibleCharacterCount = content.runes
        .where((r) => String.fromCharCode(r).trim().isNotEmpty)
        .length;
    final calculatedDelay =
        minReplyDelayMs + visibleCharacterCount * replyDelayMsPerCharacter;
    final baseDelay = calculatedDelay.clamp(minReplyDelayMs, maxReplyDelayMs);
    final jitter = random == null ? 0 : random.nextInt(replyDelayJitterMs + 1);
    return Duration(milliseconds: min(maxReplyDelayMs, baseDelay + jitter));
  }

  static bool contentMentionsUser(String content, String ownerName) {
    final tokens = <String>{'我'};
    final trimmedOwnerName = ownerName.trim();
    if (trimmedOwnerName.isNotEmpty) tokens.add(trimmedOwnerName);

    final mentionPattern = RegExp(r'@([^@\s，。！？!?、；;：:,.]+)');
    for (final match in mentionPattern.allMatches(content)) {
      final token = match.group(1)?.trim();
      if (token != null && tokens.contains(token)) return true;
    }
    return false;
  }

  static bool isGroupAddressedMessage(String content) {
    final text = content.replaceAll(RegExp(r'\s+'), '').toLowerCase();
    if (text.isEmpty) return false;

    final mentionPattern = RegExp(r'@([^@\s，。！？!?、；;：:,.]+)');
    if (RegExp(r'@(all|everyone|所有人|全部)').hasMatch(text)) return true;

    final collectiveTokens = [
      '大家',
      '各位',
      '你们',
      '诸位',
      '所有人',
      '每个人',
      '每位',
      '全员',
      '一起',
      '都来',
      '都说',
      '都分享',
    ];
    if (collectiveTokens.any(text.contains)) return true;
    if (mentionPattern.hasMatch(text)) return false;

    final groupInvitationTokens = [
      '分享一下',
      '分享下',
      '说说看',
      '聊聊看',
      '来聊聊',
      '发表一下',
    ];
    return groupInvitationTokens.any(text.contains);
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

import 'dart:math';

import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/character_memory.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/features/chat_group/scene_behavior.dart';
import 'package:chat_group/features/chat_group/user_message_sentiment.dart';

enum ReplyAction {
  answer,
  agree,
  challenge,
  joke,
  askBack,
  topicShift,
  comfort,
  callOut,
}

enum ReplyLengthHint {
  oneLiner,
  short,
  normal,
}

class ReplyIntent {
  final String speakerId;
  final ReplyAction action;
  final String? targetId;
  final ReplyLengthHint lengthHint;
  final String toneHint;
  final String reason;

  const ReplyIntent({
    required this.speakerId,
    required this.action,
    this.targetId,
    required this.lengthHint,
    required this.toneHint,
    required this.reason,
  });
}

class _ScoredIntent {
  final ReplyIntent intent;
  final int score;

  const _ScoredIntent(this.intent, this.score);
}

class HumanizedChatOrchestrator {
  static List<ReplyIntent> selectReplyIntents({
    required List<AICharacter> characters,
    required List<Message> recentMessages,
    required String groupId,
    required String groupTheme,
    required String? userMessage,
    required List<String> mentionedIds,
    required List<CharacterMemory> memories,
    required List<RelationshipState> relationships,
    required bool Function(AICharacter character) isEligible,
    required Random random,
    bool isAutoChat = false,
    UserMessageSentiment? userSentiment,
  }) {
    final eligible = characters.where(isEligible).toList();
    if (eligible.isEmpty) return const [];

    final scored = <_ScoredIntent>[];
    for (final character in eligible) {
      final intent = _intentForCharacter(
        character: character,
        allCharacters: characters,
        recentMessages: recentMessages,
        groupId: groupId,
        groupTheme: groupTheme,
        userMessage: userMessage,
        mentionedIds: mentionedIds,
        memories: memories,
        relationships: relationships,
        random: random,
        isAutoChat: isAutoChat,
        userSentiment: userSentiment,
      );
      if (intent == null) continue;
      scored.add(intent);
    }

    scored.sort((a, b) => b.score.compareTo(a.score));
    final limit = mentionedIds.isNotEmpty ? 2 : (isAutoChat ? 2 : 3);
    return scored.take(limit).map((s) => s.intent).toList();
  }

  static _ScoredIntent? _intentForCharacter({
    required AICharacter character,
    required List<AICharacter> allCharacters,
    required List<Message> recentMessages,
    required String groupId,
    required String groupTheme,
    required String? userMessage,
    required List<String> mentionedIds,
    required List<CharacterMemory> memories,
    required List<RelationshipState> relationships,
    required Random random,
    required bool isAutoChat,
    UserMessageSentiment? userSentiment,
  }) {
    var score = isAutoChat ? 24 : 18;
    final reasons = <String>[];
    ReplyAction action = ReplyAction.answer;
    ReplyLengthHint length = ReplyLengthHint.short;
    var tone = '自然、口语、像群友';
    String? targetId;
    final scene = SceneBehavior.resolve(groupTheme);

    if (mentionedIds.contains(character.id)) {
      score += 100;
      reasons.add('mentioned');
      action = ReplyAction.answer;
      length = ReplyLengthHint.short;
    }

    if (recentMessages.isNotEmpty) {
      final last = recentMessages.last;
      if (last.senderId == character.id) {
        score -= 45;
        reasons.add('recency-cooldown');
      } else if (last.senderType == 'ai') {
        final relation = _relationToward(
          relationships,
          groupId,
          character.id,
          last.senderId,
        );
        if (relation != null) {
          targetId = last.senderId;
          score += relation.familiarity ~/ 4;
          if (relation.friction >= 60 || relation.affinity < -10) {
            score += 36;
            reasons.add('relationship-friction');
            action = ReplyAction.challenge;
            tone = '带刺、别太客气、但别人身攻击';
            length = ReplyLengthHint.oneLiner;
          } else if (relation.affinity >= 50 || relation.trust >= 50) {
            score += 28;
            reasons.add('relationship-warmth');
            action = _comfortingAction(last.content, random);
            tone = '熟人感、轻一点、别端着';
            length = ReplyLengthHint.short;
          }
          if (relation.recentMood == RelationshipMood.awkward ||
              relation.recentMood == RelationshipMood.cold) {
            score -= 12;
            reasons.add('mood-cooldown');
          }
        }
      }
    }

    if (scene.activelyTargetsMembers && mentionedIds.isEmpty) {
      final sceneTarget = _sceneTargetFor(
        character: character,
        allCharacters: allCharacters,
        recentMessages: recentMessages,
        relationships: relationships,
        groupId: groupId,
        random: random,
      );
      if (sceneTarget != null) {
        targetId = sceneTarget;
        score +=
            isAutoChat ? scene.autoTargetScore : scene.userRoundTargetScore;
        action = scene.chooseTargetAction(random);
        length = scene.targetLength;
        tone = scene.targetTone;
        reasons.add(scene.targetReason);
      } else if (isAutoChat) {
        score += scene.autoTargetScore ~/ 2;
        action = scene.fallbackAction;
        length = ReplyLengthHint.short;
        tone = scene.fallbackTone;
        reasons.add(scene.fallbackReason);
      }
    }

    // 关系驱动：用户对角色好感极低或摩擦极高时，角色强制带刺回复。
    // 不沉默——宁可怼人也不让消息石沉大海。
    final userRelation = _relationTowardUser(
        relationships, groupId, character.id);
    if (userRelation != null && !mentionedIds.contains(character.id)) {
      if (userRelation.affinity < -20 && userRelation.friction > 60) {
        // 亲近为负且摩擦很高：强制带刺回复，表达不耐烦。
        score += 20;
        action = ReplyAction.challenge;
        tone = '不耐烦、不想理、但碍于场面说两句';
        length = ReplyLengthHint.oneLiner;
        reasons.add('hostile-response');
      } else if (userRelation.affinity < -10 || userRelation.friction > 70) {
        // 关系紧张但未到破裂：降低回复意愿，语气变冷淡。
        score -= 14;
        reasons.add('tense-relationship');
        if (action == ReplyAction.answer || action == ReplyAction.agree) {
          action = ReplyAction.topicShift;
          tone = '敷衍、不想深入聊、转移话题';
        } else if (action == ReplyAction.answer) {
          tone = '冷淡、简短、不想多聊';
          length = ReplyLengthHint.oneLiner;
        }
      } else if (userRelation.affinity < 0 && userRelation.recentMood == RelationshipMood.cold) {
        // 冷淡情绪下好感为负：降低回复意愿。
        score -= 8;
        reasons.add('cold-mood');
        if (action == ReplyAction.answer) {
          tone = '敷衍、简短';
          length = ReplyLengthHint.oneLiner;
        }
      }
    }

    // 用户当前消息的态度直接影响角色本轮回复意愿。
    if (userSentiment != null && !mentionedIds.contains(character.id)) {
      if (userSentiment.isOffensive) {
        // 冒犯：显著降低回复意愿；如果角色还是决定回复，语气倾向带刺。
        score -= 10 + userSentiment.severity * 6;
        reasons.add('user-offensive');
        if (action == ReplyAction.answer || action == ReplyAction.agree) {
          action = ReplyAction.challenge;
          tone = '被冒犯了、不太想理、但还是回一句';
          length = ReplyLengthHint.oneLiner;
        }
      } else if (userSentiment.isCold) {
        score -= 5;
        reasons.add('user-cold');
        if (action == ReplyAction.answer) {
          tone = '敷衍、简短';
          length = ReplyLengthHint.oneLiner;
        }
      } else if (userSentiment.isRespectful) {
        score += 3;
        reasons.add('user-friendly');
      }
    }

    final topicScore = _topicInterest(character, memories, userMessage);
    if (topicScore > 0) {
      score += topicScore;
      reasons.add('topic-interest');
      if (action == ReplyAction.answer) {
        length = ReplyLengthHint.normal;
      }
    }

    if (mentionedIds.isEmpty && score < 35 && random.nextDouble() < 0.28) {
      reasons.add('silence');
      return null;
    }

    if (action == ReplyAction.answer &&
        isAutoChat &&
        random.nextDouble() < 0.18) {
      action = ReplyAction.topicShift;
      tone = '随口想到、轻微跑题、自然递话';
      reasons.add('auto-topic-shift');
    } else if (action == ReplyAction.answer &&
        mentionedIds.isEmpty &&
        random.nextDouble() < 0.14) {
      action = ReplyAction.joke;
      tone = '接梗、轻松、短';
      length = ReplyLengthHint.oneLiner;
      reasons.add('interrupt-joke');
    }

    score += random.nextInt(8);
    if (reasons.isEmpty) reasons.add('baseline');

    return _ScoredIntent(
      ReplyIntent(
        speakerId: character.id,
        action: action,
        targetId: targetId,
        lengthHint: length,
        toneHint: tone,
        reason: reasons.join(','),
      ),
      score,
    );
  }

  static String? _sceneTargetFor({
    required AICharacter character,
    required List<AICharacter> allCharacters,
    required List<Message> recentMessages,
    required List<RelationshipState> relationships,
    required String groupId,
    required Random random,
  }) {
    for (final message in recentMessages.reversed.take(6)) {
      if (message.senderType == 'ai' && message.senderId != character.id) {
        return message.senderId;
      }
    }

    final related = relationships
        .where((r) =>
            r.groupId == groupId &&
            r.sourceCharacterId == character.id &&
            r.targetType == RelationshipTargetType.ai &&
            r.targetId != character.id)
        .toList()
      ..sort((a, b) => (b.affinity + b.familiarity + b.trust)
          .compareTo(a.affinity + a.familiarity + a.trust));
    if (related.isNotEmpty && random.nextDouble() < 0.74) {
      return related.first.targetId;
    }

    final candidates =
        allCharacters.where((c) => c.id != character.id).toList();
    if (candidates.isEmpty) return null;
    return candidates[random.nextInt(candidates.length)].id;
  }

  static RelationshipState? _relationToward(
    List<RelationshipState> relationships,
    String groupId,
    String sourceId,
    String targetId,
  ) {
    for (final relation in relationships) {
      if (relation.groupId == groupId &&
          relation.sourceCharacterId == sourceId &&
          relation.targetId == targetId) {
        return relation;
      }
    }
    return null;
  }

  /// 查找指定角色对真人用户的关系记录（用于关系驱动的回复意愿判断）。
  static RelationshipState? _relationTowardUser(
      List<RelationshipState> relationships, String groupId, String characterId) {
    for (final relation in relationships) {
      if (relation.groupId == groupId &&
          relation.sourceCharacterId == characterId &&
          relation.targetId == 'user' &&
          relation.targetType == RelationshipTargetType.user) {
        return relation;
      }
    }
    return null;
  }

  static ReplyAction _comfortingAction(String content, Random random) {
    final lower = content.toLowerCase();
    if (content.contains('累') ||
        content.contains('难受') ||
        content.contains('烦') ||
        lower.contains('tired')) {
      return ReplyAction.comfort;
    }
    return random.nextBool() ? ReplyAction.agree : ReplyAction.askBack;
  }

  static int _topicInterest(
    AICharacter character,
    List<CharacterMemory> memories,
    String? userMessage,
  ) {
    final text = userMessage?.toLowerCase() ?? '';
    if (text.isEmpty) return 0;
    final haystack = [
      character.role,
      ...character.personalityTags,
      for (final memory in memories.where((m) => m.characterId == character.id))
        ...memory.personaGrowth,
    ].join(' ').toLowerCase();

    var score = 0;
    for (final token in _tokens(text)) {
      if (token.length < 2) continue;
      if (haystack.contains(token)) score += 18;
    }

    if (_creativeTopic(text) && _creativeRole(haystack)) score += 32;
    if (_technicalTopic(text) && _technicalRole(haystack)) score += 32;
    return score.clamp(0, 48).toInt();
  }

  static Iterable<String> _tokens(String text) sync* {
    for (final part in text.split(RegExp(r'\s+|[，。！？、,.!?]'))) {
      final trimmed = part.trim();
      if (trimmed.isNotEmpty) yield trimmed;
    }
  }

  static bool _creativeTopic(String text) =>
      text.contains('海报') ||
      text.contains('配色') ||
      text.contains('构图') ||
      text.contains('审美') ||
      text.contains('画');

  static bool _creativeRole(String text) =>
      text.contains('插画') ||
      text.contains('设计') ||
      text.contains('审美') ||
      text.contains('配色') ||
      text.contains('构图');

  static bool _technicalTopic(String text) =>
      text.contains('代码') ||
      text.contains('接口') ||
      text.contains('bug') ||
      text.contains('后端') ||
      text.contains('程序');

  static bool _technicalRole(String text) =>
      text.contains('程序') ||
      text.contains('工程') ||
      text.contains('后端') ||
      text.contains('技术');
}

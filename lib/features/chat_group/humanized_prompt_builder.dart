import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/character_memory.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/features/chat_group/fact_discipline_prompt.dart';
import 'package:chat_group/features/chat_group/humanized_chat_orchestrator.dart';
import 'package:chat_group/features/chat_group/scene_behavior.dart';

class HumanizedPromptBuilder {
  static String buildIntentContext({
    required AICharacter character,
    required String groupName,
    required String groupTheme,
    required String ownerName,
    required ReplyIntent intent,
    required CharacterMemory memory,
    required List<RelationshipState> relationships,
    required Map<String, AICharacter> charactersById,
  }) {
    final relevantRelations = _relationLines(
      relationships: relationships,
      character: character,
      targetId: intent.targetId,
      charactersById: charactersById,
    );
    final targetName = intent.targetId == null
        ? '当前话题'
        : charactersById[intent.targetId!]?.name ?? ownerName;
    final scene = SceneBehavior.resolve(groupTheme);

    return [
      '【真人化发言上下文】',
      FactDisciplinePrompt.rules,
      '你是${character.name}，${character.age}岁，身份是${character.role}。',
      '你正在「$groupName」里聊天，群主题是「$groupTheme」，真人用户/群主叫「$ownerName」。',
      if (character.personalityTags.isNotEmpty)
        '你的基础性格标签：${character.personalityTags.join('、')}。',
      if (memory.facts.isNotEmpty) '你记得的事实：${_limit(memory.facts, 4)}',
      if (memory.relationshipNotes.isNotEmpty)
        '你的关系记忆：${_limit(memory.relationshipNotes, 4)}',
      if (memory.personaGrowth.isNotEmpty)
        '你最近形成的表达习惯：${_limit(memory.personaGrowth, 4)}',
      if (relevantRelations.isNotEmpty)
        '你和相关成员的关系：${relevantRelations.join('；')}',
      ..._relationshipBehaviorInstructions(relationships, character),
      '本轮动作：${intent.action.name}，主要对象：$targetName。',
      '本轮语气：${intent.toneHint}。',
      lengthInstruction(intent.lengthHint),
      ...scene.intentInstructions(targetName, intent.targetId != null),
      '你是在群里自然接话，不是在写完整答案。',
      '不要总结全局，不要说自己是 AI，不要替别人发言，不要固定格式，不要带自己的名字前缀。',
    ].join('\n');
  }

  static String lengthInstruction(ReplyLengthHint hint) {
    return switch (hint) {
      ReplyLengthHint.oneLiner => '长度要求：一句话，尽量不超过 25 个字。',
      ReplyLengthHint.short => '长度要求：1-2 句，像群友随手回。',
      ReplyLengthHint.normal => '长度要求：2-4 句，可以稍微展开，但不要写成总结。',
    };
  }

  static String ownerMentionInstruction(String ownerName) {
    final normalizedOwner = ownerName.trim().isEmpty ? '我' : ownerName.trim();
    final ownerMention = normalizedOwner == '我' ? '@我' : '@$normalizedOwner';
    return '这个群里的真人用户/群主叫「$normalizedOwner」；'
        '你可以偶尔自然地用「$ownerMention」向真人用户追问、邀请补充或回应他的观点，但不要每条都@。';
  }

  static String _limit(List<String> values, int count) {
    return values.take(count).join('；');
  }

  static List<String> _relationLines({
    required List<RelationshipState> relationships,
    required AICharacter character,
    required String? targetId,
    required Map<String, AICharacter> charactersById,
  }) {
    final filtered = relationships
        .where((r) => r.sourceCharacterId == character.id)
        .where((r) => targetId == null || r.targetId == targetId)
        .take(4);

    return filtered.map((r) {
      final name = r.targetType == RelationshipTargetType.user
          ? '真人用户'
          : charactersById[r.targetId]?.name ?? '某个群友';
      final mood = r.recentMood.name;
      final note = r.notes.trim().isEmpty ? '没有明确备注' : r.notes.trim();
      return '$name：亲近${r.affinity}，信任${r.trust}，摩擦${r.friction}，最近情绪$mood，$note';
    }).toList();
  }

  /// 根据角色对用户的关系状态，注入行为准则，让角色能够根据关系
  /// 自主决定回复态度（拒绝、敷衍、热情等）。
  static Iterable<String> _relationshipBehaviorInstructions(
      List<RelationshipState> relationships, AICharacter character) sync* {
    RelationshipState? userRel;
    for (final r in relationships) {
      if (r.sourceCharacterId == character.id &&
          r.targetId == 'user' &&
          r.targetType == RelationshipTargetType.user) {
        userRel = r;
        break;
      }
    }
    if (userRel == null) return;

    if (userRel.affinity < -20 && userRel.friction > 60) {
      yield '关系准则：你和用户关系很差（亲近${userRel.affinity}，摩擦${userRel.friction}）。'
          '你会不耐烦，懒得认真回应，语气带刺、想尽快结束对话。';
    } else if (userRel.affinity < 0 || userRel.friction > 50) {
      yield '关系准则：你和用户关系一般（亲近${userRel.affinity}，摩擦${userRel.friction}）。'
          '不用刻意讨好，保持自然距离，但也不要故意激化矛盾。';
    } else if (userRel.affinity >= 50 || userRel.trust >= 40) {
      yield '关系准则：你和用户关系很好（亲近${userRel.affinity}，信任${userRel.trust}）。'
          '可以更自然、更放松，适当关心对方，但不要每条都讨好。';
    }
    // 默认情况（中性关系）：不注入特殊规则，让角色自然回应。
  }
}

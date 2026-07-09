import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/features/agentic/character_skill_resolver.dart';

/// 角色卡片右上角“行动 N”展示的技能总数。
///
/// 由两部分相加：
/// 1. 推断技能数 —— 根据角色文本（名字/身份/标签/系统提示）自动推导，与
///    `agenticEnabled` 开关、工具权限无关，是固定值。
/// 2. 已安装技能数 —— `skillIds`，只有当角色真正安装某个专家技能（在聊天里下载，
///    或在编辑页勾选「可安装专家 Skill」）时才会增长。
int actionSkillCountFor(AICharacter character) {
  final inferred = CharacterSkillResolver.defaultsFor(character).skills.length;
  return inferred + character.skillIds.length;
}

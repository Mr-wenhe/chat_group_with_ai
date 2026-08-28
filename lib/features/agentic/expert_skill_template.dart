import 'package:chat_group/core/models/character_skill.dart';
import 'package:chat_group/core/models/tool_permission.dart';

class ExpertSkillTemplate {
  final String id;
  final String name;
  final String domain;
  final String description;
  final List<String> keywords;
  final List<String> instructions;
  final List<ToolPermission> requiredPermissions;
  final bool appliesToCodingRequests;
  final String source;

  const ExpertSkillTemplate({
    required this.id,
    required this.name,
    required this.domain,
    required this.description,
    required this.keywords,
    required this.instructions,
    required this.requiredPermissions,
    this.appliesToCodingRequests = false,
    this.source = 'built-in-expert-catalog',
  });

  CharacterSkill instantiateFor(String characterId) {
    return CharacterSkill(
      id: id,
      characterId: characterId,
      name: name,
      domain: domain,
      description: '$description\n来源：$source/$id',
      instructions: instructions,
      requiredPermissions: requiredPermissions,
    );
  }
}

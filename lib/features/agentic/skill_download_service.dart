import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/character_skill.dart';
import 'package:chat_group/features/agentic/expert_skill_catalog.dart';

class SkillDownloadService {
  static List<ExpertSkillTemplate> recommendedTemplatesFor(
    AICharacter character,
  ) {
    final text = [
      character.name,
      character.role,
      ...character.personalityTags,
      character.systemPrompt,
    ].join(' ');
    return ExpertSkillCatalog.recommendForText(text);
  }

  static CharacterSkill? instantiateForCharacter({
    required String templateId,
    required AICharacter character,
  }) {
    final template = ExpertSkillCatalog.findById(templateId);
    return template?.instantiateFor(character.id);
  }
}

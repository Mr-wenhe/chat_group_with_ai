import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/character_skill.dart';
import 'package:chat_group/core/models/tool_permission.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('database exposes character skill box name through CRUD helpers', () {
    final skill = CharacterSkill(
      id: 'skill-1',
      characterId: 'c1',
      name: 'Code Review',
      domain: 'coding',
      description: 'Review code changes.',
      instructions: const ['Read diff', 'Find defects', 'Suggest tests'],
      requiredPermissions: const [ToolPermission.workspaceRead],
    );

    expect(DatabaseService.agentSkillBoxName, 'character_skills');
    expect(DatabaseService.agentTaskBoxName, 'agent_tasks');
    expect(skill.id, 'skill-1');
  });
}

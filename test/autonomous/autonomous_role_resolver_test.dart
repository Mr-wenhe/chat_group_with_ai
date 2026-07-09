import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/features/autonomous/autonomous_role_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('selects planner executor and verifier by role', () {
    final product = _character(name: '产品', role: '产品经理');
    final dev = _character(name: '老王', role: 'C++高级工程师');
    final qa = _character(name: '小测', role: '测试工程师');

    final assignment =
        const AutonomousRoleResolver().resolve([dev, qa, product]);

    expect(assignment.planner.id, product.id);
    expect(assignment.executor.id, dev.id);
    expect(assignment.verifier.id, qa.id);
  });
}

AICharacter _character({required String name, required String role}) {
  return AICharacter(
    name: name,
    avatar: name.substring(0, 1),
    age: 30,
    role: role,
    personalityTags: [role],
    systemPrompt: role,
    apiKey: 'k',
    apiProvider: 'deepseek',
  );
}

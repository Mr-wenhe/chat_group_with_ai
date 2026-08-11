import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/features/ai_character/character_gender_migrator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  AICharacter character({
    String name = 'Amy',
    String role = '瑜伽教练',
    String systemPrompt = '温柔地陪伴用户。',
    CharacterGender gender = CharacterGender.female,
  }) {
    return AICharacter(
      id: name,
      name: name,
      avatar: name.substring(0, 1),
      age: 28,
      role: role,
      personalityTags: const [],
      systemPrompt: systemPrompt,
      apiKey: '',
      apiProvider: 'custom',
      gender: gender,
    );
  }

  test('gender is included in the shared role-play identity', () {
    final amy = character();

    expect(amy.promptIdentity, contains('性别女'));
    expect(amy.rolePlaySystemPrompt, contains('角色性别为女'));
    expect(amy.rolePlaySystemPrompt, contains(amy.systemPrompt));
  });

  test('local migration uses explicit identity evidence before name hints', () {
    final result = CharacterGenderMigrator.inferLocally(
      character(
        name: '小明',
        role: '全职妈妈',
        systemPrompt: '我是一个喜欢分享育儿经验的女性。',
      ),
      const ['我作为妈妈更理解这种感受。'],
    );

    expect(result, CharacterGender.female);
  });

  test('local migration falls back to female when evidence is tied', () {
    final result = CharacterGenderMigrator.inferLocally(
      character(name: 'AI-01', role: '助手', systemPrompt: ''),
      const [],
    );

    expect(result, CharacterGender.female);
  });
}

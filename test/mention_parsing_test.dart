import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/features/chat_group/chat_room_page.dart';
import 'package:flutter_test/flutter_test.dart';

AICharacter _character(String id, String name) {
  return AICharacter(
    id: id,
    name: name,
    avatar: name.substring(0, 1),
    age: 20,
    role: '测试角色',
    personalityTags: const ['测试'],
    systemPrompt: '你是测试角色',
    apiKey: 'key',
    apiProvider: 'custom',
    apiConfigId: 'config',
  );
}

void main() {
  final characters = [
    _character('c1', '小胖'),
    _character('c2', 'Alice'),
    _character('c3', '马文杰'),
  ];

  test(
      'parseMentionedCharacterIds parses Chinese and English mentions in order',
      () {
    final result = parseMentionedCharacterIds(
      '请 @小胖 先说，然后 @Alice 补充，最后 @马文杰 总结',
      characters,
    );

    expect(result, ['c1', 'c2', 'c3']);
  });

  test('parseMentionedCharacterIds ignores unknown mentions', () {
    final result = parseMentionedCharacterIds('@不存在 你好 @Alice', characters);

    expect(result, ['c2']);
  });

  test('parseMentionedCharacterIds de-duplicates repeated mentions', () {
    final result = parseMentionedCharacterIds('@小胖 @小胖 @Alice', characters);

    expect(result, ['c1', 'c2']);
  });

  test('parseMentionedCharacterIds trims common punctuation after mentions',
      () {
    final result =
        parseMentionedCharacterIds('小胖怎么看？@小胖，Alice 也说说：@Alice。', characters);

    expect(result, ['c1', 'c2']);
  });
}

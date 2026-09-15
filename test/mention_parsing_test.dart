import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/features/chat_group/chat_room_utils.dart';
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

  test('unknown longer Chinese names remain unknown', () {
    final result = analyzeMentionedCharacterIds(
        '@王明明 出具 Word', [_character('wang', '王明')]);
    expect(result.characterIds, isEmpty);
    expect(result.unknownNames, ['王明明']);
  });

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

  test('parseMentionedCharacterIds accepts a Chinese action after a name', () {
    final result = parseMentionedCharacterIds('@小胖补充建议', characters);

    expect(result, ['c1']);
  });

  test('parseMentionedCharacterIds keeps @all when action follows directly',
      () {
    final result = analyzeMentionedCharacterIds('@all讨论方案', characters);

    expect(result.mentionsAll, isTrue);
    expect(result.characterIds, ['c1', 'c2', 'c3']);
  });

  test('parseMentionedCharacterIds expands @all to every character', () {
    final result = parseMentionedCharacterIds('@all 大家都说说', characters);

    expect(result, ['c1', 'c2', 'c3']);
  });

  test('parseMentionedCharacterIds supports Chinese all aliases', () {
    final result = parseMentionedCharacterIds('@所有人 过来看一下', characters);

    expect(result, ['c1', 'c2', 'c3']);
  });

  test('parseMentionedCharacterIds keeps order and de-duplicates after @all',
      () {
    final result = parseMentionedCharacterIds('@Alice @all @小胖', characters);

    expect(result, ['c2', 'c1', 'c3']);
  });

  test('an email address is not reported as an explicit role mention', () {
    final result = analyzeMentionedCharacterIds(
      '请联系 dev@example.com',
      [...characters, _character('domain', 'example.com')],
    );

    expect(result.hasExplicitMention, isFalse);
    expect(result.unknownNames, isEmpty);
    expect(result.characterIds, isEmpty);
  });

  test('an unknown mention is diagnosable even when there are no characters',
      () {
    final result = analyzeMentionedCharacterIds('@不存在 请处理', const []);

    expect(result.hasExplicitMention, isTrue);
    expect(result.unknownNames, ['不存在']);
  });
}

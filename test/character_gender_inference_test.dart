import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/features/ai_character/character_gender_inference.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  AICharacter character({
    String id = 'amy',
    String name = 'Amy',
    String role = '助手',
    String systemPrompt = '',
  }) =>
      AICharacter(
        id: id,
        name: name,
        avatar: 'A',
        age: 28,
        role: role,
        personalityTags: const [],
        systemPrompt: systemPrompt,
        apiKey: '',
        apiProvider: 'custom',
      );

  Message message({
    required String senderId,
    required String senderType,
    required String content,
    required DateTime timestamp,
  }) =>
      Message(
        id: '$senderId-${timestamp.microsecondsSinceEpoch}-$senderType',
        groupId: 'group',
        senderId: senderId,
        senderType: senderType,
        content: content,
        timestamp: timestamp,
      );

  test('builds bounded evidence from only the character’s recent AI replies',
      () {
    final amy = character(
      name: 'A' * 100,
      role: 'R' * 200,
      systemPrompt: 'P' * 700,
    );
    final base = DateTime(2026);
    final entries = CharacterGenderInference.buildInferenceEntries(
      [amy],
      [
        message(
          senderId: amy.id,
          senderType: 'user',
          content: 'must exclude user',
          timestamp: base.add(const Duration(seconds: 30)),
        ),
        message(
          senderId: 'other',
          senderType: 'ai',
          content: 'must exclude other AI',
          timestamp: base.add(const Duration(seconds: 31)),
        ),
        for (var index = 0; index < 10; index++)
          message(
            senderId: amy.id,
            senderType: 'ai',
            content: '$index-${'x' * 300}',
            timestamp: base.add(Duration(seconds: index)),
          ),
      ],
    );

    final entry = entries.single;
    expect(entry['name'], hasLength(CharacterGenderInference.maxNameLength));
    expect(entry['role'], hasLength(CharacterGenderInference.maxRoleLength));
    expect(
      entry['systemPrompt'],
      hasLength(CharacterGenderInference.maxSystemPromptLength),
    );
    final replies = entry['recentReplies']! as List<String>;
    expect(replies, hasLength(CharacterGenderInference.maxRecentReplies));
    expect(replies.first, startsWith('9-'));
    expect(
        replies.every(
            (reply) => reply.length <= CharacterGenderInference.maxReplyLength),
        isTrue);
    expect(replies.join(), isNot(contains('must exclude')));
  });

  test(
      'parses JSON and fenced JSON while retaining only valid known unique IDs',
      () {
    final ids = {'amy', 'jay'};
    const raw = '''Here is the result:
```json
[
  {"id":"amy","gender":"男"},
  {"id":"amy","gender":"女"},
  {"id":"jay","gender":"女"},
  {"id":"unknown","gender":"男"},
  {"id":"bad","gender":"未知"},
  {"id":"missing"},
  {"gender":"男"}
]
```
Thanks.''';

    expect(
      CharacterGenderInference.parseLlmResult(raw, knownCharacterIds: ids),
      {
        'amy': CharacterGender.male,
        'jay': CharacterGender.female,
      },
    );
    expect(
      CharacterGenderInference.parseLlmResult(
        '[{"id":"amy","gender":"男"}]',
        knownCharacterIds: ids,
      ),
      {'amy': CharacterGender.male},
    );
    expect(
      CharacterGenderInference.parseLlmResult(
        '说明[仅供参考]\n```json\n[{"id":"amy","gender":"女"}]\n```',
        knownCharacterIds: ids,
      ),
      {'amy': CharacterGender.female},
    );
  });

  test('invalid LLM responses safely return no results', () {
    expect(
      CharacterGenderInference.parseLlmResult(
        'not JSON [',
        knownCharacterIds: {'amy'},
      ),
      isEmpty,
    );
  });

  test('local inference prioritizes explicit identity, then name hints', () {
    expect(
      CharacterGenderInference.inferLocally(
        character(name: '小明', systemPrompt: '我是女性。'),
        const [],
      ),
      CharacterGender.female,
    );
    expect(
      CharacterGenderInference.inferLocally(
        character(name: 'Amy', systemPrompt: '我是男性。'),
        const [],
      ),
      CharacterGender.male,
    );
    expect(
      CharacterGenderInference.inferLocally(character(name: '阿杰'), const []),
      CharacterGender.male,
    );
  });

  test('local inference never infers gender from an ordinary occupation alone',
      () {
    expect(
      CharacterGenderInference.inferLocally(
        character(name: 'AI-01', role: '护士', systemPrompt: ''),
        const [],
      ),
      CharacterGender.female,
    );
  });

  test('local inference accepts explicit gendered role titles but not jobs',
      () {
    expect(
      CharacterGenderInference.inferLocally(
        character(name: 'AI-01', role: '全职爸爸'),
        const [],
      ),
      CharacterGender.male,
    );
    expect(
      CharacterGenderInference.inferLocally(
        character(name: 'AI-01', role: '宝妈'),
        const [],
      ),
      CharacterGender.female,
    );
    expect(
      CharacterGenderInference.inferLocally(
        character(name: 'AI-01', role: '男性用户的顾问'),
        const [],
      ),
      CharacterGender.female,
    );
    expect(
      CharacterGenderInference.inferLocally(
        character(
          name: 'AI-01',
          systemPrompt: '你是一名男性用户的顾问。',
        ),
        const [],
      ),
      CharacterGender.female,
    );
  });

  test('local inference handles gendered identity phrases with occupations',
      () {
    expect(
      CharacterGenderInference.inferLocally(
        character(name: 'AI-01', systemPrompt: '你是一名男性医生。'),
        const [],
      ),
      CharacterGender.male,
    );
    expect(
      CharacterGenderInference.inferLocally(
        character(name: 'AI-01', systemPrompt: '我是女性瑜伽教练。'),
        const [],
      ),
      CharacterGender.female,
    );
  });

  test('local inference ignores gendered terms that describe someone else', () {
    expect(
      CharacterGenderInference.inferLocally(
        character(
          name: 'AI-01',
          systemPrompt: '我爸爸是男性，我的妻子是一位女性。',
        ),
        const ['哥哥最近来看我，但这不是我的身份。'],
      ),
      CharacterGender.female,
    );
  });

  test(
      'local inference treats second-person text in AI replies as user evidence',
      () {
    expect(
      CharacterGenderInference.inferLocally(
        character(name: 'AI-01'),
        const ['你是男生，请继续说说你的想法。'],
      ),
      CharacterGender.female,
    );
  });

  test('local inference ignores a bare "作为" in AI replies', () {
    expect(
      CharacterGenderInference.inferLocally(
        character(name: 'AI-01'),
        const ['作为男性用户，你可以继续说。'],
      ),
      CharacterGender.female,
    );
  });

  test('local inference uses only the newest eight replies', () {
    final replies = [
      ...List.filled(8, '我是女性。'),
      ...List.filled(9, '我是男性。'),
    ];

    expect(
      CharacterGenderInference.inferLocally(
        character(name: 'AI-01'),
        replies,
      ),
      CharacterGender.female,
    );
  });

  test('explicit conflict wins over name hints and falls back to female', () {
    expect(
      CharacterGenderInference.inferLocally(
        character(name: '阿杰', systemPrompt: '我是男性。我是女性。'),
        const [],
      ),
      CharacterGender.female,
    );
  });

  test(
      'local inference is deterministic and falls back to female for conflict, tie, and no evidence',
      () {
    final conflicted = character(systemPrompt: '我是男性。作为女性角色。');

    expect(
      CharacterGenderInference.inferLocally(conflicted, const []),
      CharacterGender.female,
    );
    expect(
      CharacterGenderInference.inferLocally(character(), const []),
      CharacterGender.female,
    );
    expect(
      CharacterGenderInference.inferLocally(character(), const []),
      CharacterGenderInference.inferLocally(character(), const []),
    );
  });
}

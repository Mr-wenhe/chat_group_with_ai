import 'package:chat_group/core/images/image_style_presets.dart';
import 'package:chat_group/core/images/ip_image_prompt_builder.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:flutter_test/flutter_test.dart';

AICharacter _character({
  String name = '小美',
  int age = 25,
  String role = '游戏主播',
  List<String> tags = const ['活泼', '开朗'],
  String systemPrompt = '你是一个元气满满的游戏主播。',
  CharacterGender gender = CharacterGender.female,
  bool hasKnownGender = true,
  String voiceId = '',
}) {
  return AICharacter(
    name: name,
    avatar: '美',
    age: age,
    role: role,
    personalityTags: tags,
    systemPrompt: systemPrompt,
    apiKey: '',
    apiProvider: 'custom',
    gender: gender,
    hasKnownGender: hasKnownGender,
    voiceId: voiceId,
  );
}

void main() {
  test('本地回落：人物名词开头 + 性格 + 人设 + 音色', () {
    final prompt = buildIpImagePrompt(
      _character(voiceId: 'zh_female_gaolengyujie_moon_bigtts'),
    );

    expect(prompt, startsWith('a 25-year-old female 游戏主播, 活泼, 开朗.'));
    expect(prompt, contains('Mood reference only'));
    expect(prompt, contains('"你是一个元气满满的游戏主播。"'));
    expect(prompt, contains('Voice temperament hint: "高冷御姐".'));
    expect(prompt, contains('no text, no watermark'));
  });

  test('第一句读作一个人，不是一撮头发', () {
    final prompt = buildIpImagePrompt(
      _character(),
      visualDescription: 'round face, bright amber eyes, long silver hair',
    );

    expect(
      prompt,
      startsWith('a 25-year-old female 游戏主播, round face, bright amber eyes'),
    );
    // 有 LLM 描述时不再回填性格 / 人设 / 音色：那些已折进描述里。
    expect(prompt, isNot(contains('Mood reference only')));
    expect(prompt, isNot(contains('Voice temperament hint')));
    expect(prompt, isNot(contains('活泼')));
  });

  test('不写角色名，也不写 profile picture 这类元描述', () {
    final prompt = buildIpImagePrompt(
      _character(),
      visualDescription: 'round face',
    );

    // 名字不带视觉信息，还会和末尾的 no text 打架；元描述会把画面拽成特写。
    expect(prompt, isNot(contains('小美')));
    expect(prompt, isNot(contains('profile picture')));
    expect(prompt, isNot(contains('Subject:')));
    expect(prompt, isNot(contains('Appearance:')));
  });

  test('正向取景确认收尾，压住外观里的头发词量', () {
    final prompt = buildIpImagePrompt(_character());

    expect(prompt, contains('upper body portrait from the chest up'));
    expect(prompt, contains('facing the viewer'));
    // 末尾权重和开头一样高，取景确认必须是最后一句。
    expect(
      prompt.trim().split('\n').last,
      contains('the face is large, clearly visible and front-facing.'),
    );
  });

  test('视觉描述压空白并剥掉成对引号', () {
    final prompt = buildIpImagePrompt(
      _character(),
      visualDescription: '  “short  silver\nhair”, "amber eyes"  ',
    );

    expect(prompt, contains(', short silver hair, amber eyes.'));
    expect(prompt, isNot(contains('“')));
    expect(prompt, isNot(contains('"amber')));
  });

  test('空白视觉描述视同未提供，回落本地模板', () {
    final prompt = buildIpImagePrompt(_character(), visualDescription: '   ');

    expect(prompt, contains('a 25-year-old female 游戏主播, 活泼, 开朗.'));
    expect(prompt, contains('Mood reference only'));
  });

  test('外观描述按词边界截断，不把词砍成两半', () {
    // 每词 10 字符 + 1 空格，共 100 词 = 1099 字符，超 400 上限。
    final prompt = buildIpImagePrompt(
      _character(),
      visualDescription: List<String>.filled(100, 'silverhair').join(' '),
    );

    final subject = prompt.split('\n').first;
    final appearance = subject.substring(
      'a 25-year-old female 游戏主播, '.length,
      subject.length - 1,
    );
    expect(appearance.length, lessThan(kIpPromptAppearanceMaxChars));
    // 400 上限按词边界回退到 36 词（395 字符），第 37 词只露出一半也整词丢弃。
    final kept = appearance.split(' ');
    expect(kept, hasLength(36));
    expect(kept.every((word) => word == 'silverhair'), isTrue);
  });

  test('画风预设替换默认风格片段', () {
    final prompt = buildIpImagePrompt(
      _character(),
      style: resolveImageStylePreset('watercolor'),
    );

    expect(prompt, contains('Soft watercolor illustration'));
    expect(prompt, isNot(contains('Anime-inspired semi-realistic')));
    // 取景是所有预设共用的，不随画风丢失。
    expect(prompt, contains('upper body portrait'));
    expect(prompt, contains('facing the viewer'));
  });

  test('未知画风 id 回落到自动，不让生成失败', () {
    final prompt = buildIpImagePrompt(
      _character(),
      style: resolveImageStylePreset('nope'),
    );

    expect(prompt, contains('Anime-inspired semi-realistic style'));
  });

  test('缺年龄性别与身份时降级为通用主语，不产生空占位', () {
    final prompt = buildIpImagePrompt(
      _character(name: '小美', role: '', age: 0, hasKnownGender: false),
    );

    expect(prompt, startsWith('an AI companion, 活泼, 开朗.'));
    expect(prompt, isNot(contains('null')));
    expect(prompt, isNot(contains('小美')));
  });

  test('空性格标签时主语句只剩人物名词', () {
    final prompt = buildIpImagePrompt(
      _character(tags: const [], systemPrompt: '   '),
    );

    expect(prompt, startsWith('a 25-year-old female 游戏主播.'));
    expect(prompt, isNot(contains('Mood reference only')));
    expect(prompt, isNot(contains('Voice temperament hint')));
  });

  test('空人设时省略情绪参考整句', () {
    final prompt = buildIpImagePrompt(_character(systemPrompt: '   '));

    expect(prompt, isNot(contains('Mood reference only')));
    // 性格标签仍在，只是人设那一段省掉。
    expect(prompt, contains('活泼, 开朗.'));
  });

  test('人设压空白并截断到上限，且保留引号包裹', () {
    final long = 'A' * (kIpPromptPersonaMaxChars + 50);
    final prompt = buildIpImagePrompt(
      _character(systemPrompt: '第一行\n第二行   $long'),
    );

    expect(prompt, contains('"第一行 第二行 '));
    // 截断后的人设片段长度受上限约束（外层还有引号与英文标签）。
    final start = prompt.indexOf('inside: "') + 'inside: "'.length;
    final end = prompt.indexOf('"', start);
    expect(end - start, kIpPromptPersonaMaxChars);
  });

  test('hasKnownGender=false 时省略性别词', () {
    final prompt = buildIpImagePrompt(
      _character(hasKnownGender: false, age: 0),
    );

    expect(prompt, isNot(contains('female')));
    expect(prompt, isNot(contains('male')));
    expect(prompt, isNot(contains('year-old')));
    expect(prompt, startsWith('an AI 游戏主播'));
  });

  test('男性角色写出 male', () {
    final prompt = buildIpImagePrompt(
      _character(gender: CharacterGender.male, hasKnownGender: true),
    );

    expect(prompt, startsWith('a 25-year-old male 游戏主播'));
    expect(prompt, isNot(contains('female')));
  });
}

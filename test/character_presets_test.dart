import 'package:chat_group/core/models/character_presets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CharacterPreset', () {
    test('包含基础人设与可执行能力预设', () {
      expect(CharacterPreset.presets.length, greaterThanOrEqualTo(14));
      final names = CharacterPreset.presets.map((p) => p.name);
      expect(names, containsAll(['代码大神', 'Bug 修复师', '产品参谋', '网页研究员']));
    });

    test('每个预设的关键字段均非空且年龄合法', () {
      for (final p in CharacterPreset.presets) {
        expect(p.name.isNotEmpty, isTrue, reason: 'name empty');
        expect(p.avatar.isNotEmpty, isTrue, reason: 'avatar empty: ${p.name}');
        expect(p.role.isNotEmpty, isTrue, reason: 'role empty: ${p.name}');
        expect(p.systemPrompt.isNotEmpty, isTrue,
            reason: 'systemPrompt empty: ${p.name}');
        expect(p.personalityTags.isNotEmpty, isTrue,
            reason: 'tags empty: ${p.name}');
        expect(p.age, greaterThan(0), reason: 'age invalid: ${p.name}');
      }
    });

    test('预设名称不重复', () {
      final names = CharacterPreset.presets.map((p) => p.name).toSet();
      expect(names.length, CharacterPreset.presets.length);
    });

    test('toFormFields 映射正确且不含密钥字段', () {
      final p = CharacterPreset.presets.first;
      final fields = p.toFormFields();
      expect(fields['name'], p.name);
      expect(fields['avatar'], p.avatar);
      expect(fields['age'], p.age.toString());
      expect(fields['role'], p.role);
      expect(fields['personality'], p.personalityTags.join(', '));
      expect(fields['systemPrompt'], p.systemPrompt);
      // 安全红线：绝不返回 apiKey / apiProvider / apiConfigId
      expect(fields.containsKey('apiKey'), isFalse);
      expect(fields.containsKey('apiProvider'), isFalse);
      expect(fields.containsKey('apiConfigId'), isFalse);
    });
  });
}

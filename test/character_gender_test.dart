import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/tool_permission.dart';
import 'package:chat_group/features/ai_character/character_gender_migrator.dart';
import 'package:chat_group/features/ai_character/providers/ai_character_providers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

void main() {
  AICharacter character({
    String? id,
    String name = 'Amy',
    String role = '瑜伽教练',
    String systemPrompt = '温柔地陪伴用户。',
    CharacterGender gender = CharacterGender.female,
  }) {
    return AICharacter(
      id: id ?? name,
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

  test('gender has exactly two stable persisted values and Chinese labels', () {
    expect(
        CharacterGender.values, [CharacterGender.male, CharacterGender.female]);
    expect(CharacterGender.male.label, '男');
    expect(CharacterGender.female.label, '女');
  });

  test(
      'legacy binary character without field 21 reads with compatibility default',
      () {
    final decoded = AICharacterAdapter().read(
      _LegacyCharacterReader(character()),
    );

    expect(decoded.gender, CharacterGender.female);
  });

  test('notifier saves a selected gender for a new character', () async {
    final fixture = await _CharacterHiveFixture.open();
    addTearDown(fixture.close);
    final notifier = AICharactersNotifier(DatabaseService());
    final male = character(name: '阿杰', gender: CharacterGender.male);

    await notifier.addCharacter(male);

    expect(fixture.box.get(male.id)!.gender, CharacterGender.male);
  });

  test('notifier preserves gender while updating other editable fields',
      () async {
    final fixture = await _CharacterHiveFixture.open();
    addTearDown(fixture.close);
    final notifier = AICharactersNotifier(DatabaseService());
    final original = character(name: '阿杰', gender: CharacterGender.male);
    await notifier.addCharacter(original);
    final edited = character(
      id: original.id,
      name: '阿杰（新版）',
      role: '播客主持人',
      gender: CharacterGender.female,
    );
    await notifier.updateCharacter(edited);

    final saved = fixture.box.get(original.id)!;
    expect(saved.gender, CharacterGender.male);
    expect(saved.name, '阿杰（新版）');
    expect(saved.role, '播客主持人');
  });
}

class _LegacyCharacterReader extends BinaryReader {
  _LegacyCharacterReader(AICharacter character)
      : _values = [
          21,
          0,
          character.id,
          1,
          character.name,
          2,
          character.avatar,
          3,
          character.age,
          4,
          character.role,
          5,
          character.personalityTags,
          6,
          character.systemPrompt,
          7,
          character.memorySummary,
          8,
          character.apiKey,
          9,
          character.apiProvider,
          10,
          character.modelName,
          11,
          character.customBaseUrl,
          12,
          character.hourlyReplyLimit,
          13,
          character.hourlyReplyCount,
          14,
          character.lastReplyTimestamp,
          15,
          character.isActive,
          16,
          character.createdAt,
          17,
          character.apiConfigId,
          18,
          character.agenticEnabled,
          19,
          character.skillIds,
          20,
          character.toolPermissions,
        ];

  final List<dynamic> _values;

  @override
  int readByte() => _values.removeAt(0) as int;

  @override
  dynamic read([int? typeId]) => _values.removeAt(0);

  @override
  int get availableBytes => _values.length;

  @override
  int get usedBytes => 0;

  @override
  Uint8List peekBytes(int bytes) => throw UnimplementedError();

  @override
  bool readBool() => throw UnimplementedError();

  @override
  Uint8List readByteList([int? length]) => throw UnimplementedError();

  @override
  List<bool> readBoolList([int? length]) => throw UnimplementedError();

  @override
  double readDouble() => throw UnimplementedError();

  @override
  List<double> readDoubleList([int? length]) => throw UnimplementedError();

  @override
  int readInt() => throw UnimplementedError();

  @override
  int readInt32() => throw UnimplementedError();

  @override
  List<int> readIntList([int? length]) => throw UnimplementedError();

  @override
  List readList([int? length]) => throw UnimplementedError();

  @override
  Map readMap([int? length]) => throw UnimplementedError();

  @override
  String readString([
    int? byteCount,
    Converter<List<int>, String> decoder = BinaryReader.utf8Decoder,
  ]) =>
      throw UnimplementedError();

  @override
  List<String> readStringList([
    int? length,
    Converter<List<int>, String> decoder = BinaryReader.utf8Decoder,
  ]) =>
      throw UnimplementedError();

  @override
  int readUint32() => throw UnimplementedError();

  @override
  int readWord() => throw UnimplementedError();

  @override
  HiveList readHiveList([int? length]) => throw UnimplementedError();

  @override
  void skip(int bytes) => throw UnimplementedError();

  @override
  Uint8List viewBytes(int bytes) => throw UnimplementedError();
}

class _CharacterHiveFixture {
  _CharacterHiveFixture._(this.directory);

  final Directory directory;

  static Future<_CharacterHiveFixture> open() async {
    final fixture = _CharacterHiveFixture._(
      await Directory.systemTemp.createTemp('character_gender_test_'),
    );
    Hive.init(fixture.directory.path);
    if (!Hive.isAdapterRegistered(0)) {
      Hive.registerAdapter(AICharacterAdapter());
    }
    if (!Hive.isAdapterRegistered(10)) {
      Hive.registerAdapter(ToolPermissionAdapter());
    }
    if (!Hive.isAdapterRegistered(24)) {
      Hive.registerAdapter(CharacterGenderAdapter());
    }
    await Hive.openBox<AICharacter>('ai_characters');
    return fixture;
  }

  Box<AICharacter> get box => Hive.box<AICharacter>('ai_characters');

  Future<void> close() async {
    await Hive.close();
    await directory.delete(recursive: true);
  }
}

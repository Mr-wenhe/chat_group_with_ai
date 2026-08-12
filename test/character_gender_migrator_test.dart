import 'dart:convert';
import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/features/ai_character/character_gender_migrator.dart';
import 'package:chat_group/services/chat_api_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'helpers/lifecycle_hive.dart';

class _FakeCredentials implements ApiCredentialResolver {
  final Map<String, String?> values;
  final requestedConfigIds = <String>[];

  _FakeCredentials(this.values);

  @override
  Future<String?> resolve(ApiConfig config) async {
    requestedConfigIds.add(config.id);
    return values[config.id];
  }
}

class _FakeChatApiService extends ChatApiService {
  final Map<String, Map<String, dynamic>> responsesByModel;
  final Map<String, Duration> delaysByModel;
  final Map<String, Object> errorsByModel;
  final calls = <({String model, List<Map<String, dynamic>> messages})>[];

  _FakeChatApiService({
    this.responsesByModel = const {},
    this.delaysByModel = const {},
    this.errorsByModel = const {},
  });

  @override
  Future<Map<String, dynamic>> sendChatMessage({
    required String apiKey,
    required ApiProvider provider,
    String? customBaseUrl,
    required String model,
    required List<Map<String, dynamic>> messages,
    double temperature = 0.85,
    int maxTokens = 1024,
    Duration? receiveTimeout,
    int maxRetries = 3,
    CancelToken? cancelToken,
  }) async {
    calls.add((model: model, messages: messages));
    final delay = delaysByModel[model];
    if (delay != null) await Future<void>.delayed(delay);
    final error = errorsByModel[model];
    if (error != null) throw error;
    return responsesByModel[model] ??
        const <String, dynamic>{'success': true, 'message': '[]'};
  }
}

ApiConfig apiConfig(String id, {bool hasCredential = true}) => ApiConfig(
      id: id,
      name: id,
      provider: 'custom',
      modelName: 'model-$id',
      customBaseUrl: 'https://example.invalid',
      hasCredential: hasCredential,
      credentialId: hasCredential ? 'credential-$id' : '',
    );

void main() {
  AICharacter character({
    String id = 'amy',
    String name = 'Amy',
    String role = '助手',
    String systemPrompt = '',
    String apiConfigId = '',
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
        apiConfigId: apiConfigId,
      );

  group('migration orchestration', () {
    late Directory directory;
    late DatabaseService db;

    setUp(() async {
      directory = await openLifecycleHive();
      db = DatabaseService();
    });

    tearDown(() => closeLifecycleHive(directory, db));

    test('writes completion for an empty database without calling the LLM',
        () async {
      final api = _FakeChatApiService();

      final migrated = await CharacterGenderMigrator(
        db,
        api: api,
        credentials: _FakeCredentials({}),
      ).migrate();

      expect(migrated, 0);
      expect(api.calls, isEmpty);
      expect(db.appSettingsBox.get(CharacterGenderMigrator.migrationKey), true);
    });

    test('batches characters by their configured API before saving genders',
        () async {
      await db.apiConfigBox.putAll({
        'config-a': apiConfig('config-a'),
        'config-b': apiConfig('config-b'),
      });
      await db.aiCharacterBox.putAll({
        'c1': character(id: 'c1', apiConfigId: 'config-a'),
        'c2': character(id: 'c2', apiConfigId: 'config-a'),
        'c3': character(id: 'c3', apiConfigId: 'config-b'),
      });
      final api = _FakeChatApiService(
        responsesByModel: {
          'model-config-a': _responseFor(
            {'c1': '男', 'c2': '男'},
          ),
          'model-config-b': _responseFor({'c3': '女'}),
        },
      );

      await CharacterGenderMigrator(
        db,
        api: api,
        credentials: _FakeCredentials({
          'config-a': 'key-a',
          'config-b': 'key-b',
        }),
      ).migrate();

      expect(api.calls, hasLength(2));
      expect(
        _requestIds(
            api.calls.singleWhere((call) => call.model == 'model-config-a')),
        {'c1', 'c2'},
      );
      expect(
        _requestIds(
            api.calls.singleWhere((call) => call.model == 'model-config-b')),
        {'c3'},
      );
      expect(db.aiCharacterBox.get('c1')!.gender, CharacterGender.male);
      expect(db.aiCharacterBox.get('c2')!.gender, CharacterGender.male);
      expect(db.aiCharacterBox.get('c3')!.gender, CharacterGender.female);
    });

    test(
        'uses local rules for missing config, credentials, failures, empty data, and timeout',
        () async {
      await db.apiConfigBox.putAll({
        'no-credential': apiConfig('no-credential', hasCredential: false),
        'throws': apiConfig('throws'),
        'empty': apiConfig('empty'),
        'slow': apiConfig('slow'),
      });
      await db.aiCharacterBox.putAll({
        'no-config': character(
          id: 'no-config',
          systemPrompt: '我是男性。',
        ),
        'no-credential': character(
          id: 'no-credential',
          apiConfigId: 'no-credential',
          systemPrompt: '我是女性。',
        ),
        'throws': character(id: 'throws', apiConfigId: 'throws', name: '阿杰'),
        'empty': character(id: 'empty', apiConfigId: 'empty'),
        'slow': character(id: 'slow', apiConfigId: 'slow', name: '阿杰'),
      });
      final api = _FakeChatApiService(
        errorsByModel: {'model-throws': StateError('TOP_SECRET_API_ERROR')},
        delaysByModel: {'model-slow': const Duration(milliseconds: 100)},
        responsesByModel: {
          'model-empty': const <String, dynamic>{
            'success': true,
            'message': '',
          },
        },
      );

      await CharacterGenderMigrator(
        db,
        api: api,
        credentials: _FakeCredentials({
          'throws': 'key-throws',
          'empty': 'key-empty',
          'slow': 'key-slow',
        }),
        llmPhaseTimeout: const Duration(milliseconds: 15),
      ).migrate();

      expect(db.aiCharacterBox.get('no-config')!.gender, CharacterGender.male);
      expect(
        db.aiCharacterBox.get('no-credential')!.gender,
        CharacterGender.female,
      );
      expect(db.aiCharacterBox.get('throws')!.gender, CharacterGender.male);
      expect(db.aiCharacterBox.get('empty')!.gender, CharacterGender.female);
      expect(db.aiCharacterBox.get('slow')!.gender, CharacterGender.male);
      expect(
        api.calls.map((call) => call.model),
        isNot(contains('model-no-credential')),
      );
    });

    test('uses local rules for characters missing from a partial LLM response',
        () async {
      await db.apiConfigBox.put('config-a', apiConfig('config-a'));
      await db.aiCharacterBox.putAll({
        'c1': character(id: 'c1', apiConfigId: 'config-a'),
        'c2': character(
          id: 'c2',
          apiConfigId: 'config-a',
          name: '阿杰',
        ),
      });
      final api = _FakeChatApiService(
        responsesByModel: {
          'model-config-a': _responseFor({'c1': '女'}),
        },
      );

      await CharacterGenderMigrator(
        db,
        api: api,
        credentials: _FakeCredentials({'config-a': 'key-a'}),
      ).migrate();

      expect(db.aiCharacterBox.get('c1')!.gender, CharacterGender.female);
      expect(db.aiCharacterBox.get('c2')!.gender, CharacterGender.male);
    });

    test('persists each decision and resumes only unfinished characters',
        () async {
      await db.apiConfigBox.put('config-a', apiConfig('config-a'));
      await db.aiCharacterBox.putAll({
        'c1': character(id: 'c1', apiConfigId: 'config-a'),
        'c2': character(id: 'c2', apiConfigId: 'config-a'),
      });
      final firstApi = _FakeChatApiService(
        responsesByModel: {
          'model-config-a': _responseFor({'c1': '男', 'c2': '男'}),
        },
      );
      var failC2 = true;
      Future<void> saveCharacter(AICharacter value) async {
        if (value.id == 'c2' && failC2) {
          failC2 = false;
          throw StateError('simulated save failure');
        }
        await db.aiCharacterBox.put(value.id, value);
      }

      final firstCount = await CharacterGenderMigrator(
        db,
        api: firstApi,
        credentials: _FakeCredentials({'config-a': 'key-a'}),
        saveCharacter: saveCharacter,
      ).migrate();

      expect(firstCount, 1);
      expect(db.aiCharacterBox.get('c1')!.gender, CharacterGender.male);
      expect(
        db.aiCharacterBox.get('c2')!.gender,
        CharacterGender.male,
        reason: '本次会话必须使用已决定的最终回退值，即使持久化失败',
      );

      final secondApi = _FakeChatApiService(
        errorsByModel: {'model-config-a': StateError('must not re-infer')},
      );
      final secondCount = await CharacterGenderMigrator(
        db,
        api: secondApi,
        credentials: _FakeCredentials({'config-a': 'key-a'}),
      ).migrate();

      expect(secondCount, 1);
      expect(db.aiCharacterBox.get('c2')!.gender, CharacterGender.male);
      expect(secondApi.calls, isEmpty);
      expect(db.appSettingsBox.get(CharacterGenderMigrator.migrationKey), true);
    });

    test('applies local fallback in memory when state storage fails', () async {
      final c1 = character(
        id: 'c1',
        systemPrompt: '我是男性。',
      );
      await db.aiCharacterBox.put('c1', c1);
      await db.appSettingsBox.close();

      await CharacterGenderMigrator(
        db,
        api: _FakeChatApiService(),
        credentials: _FakeCredentials({}),
      ).migrate();

      expect(c1.gender, CharacterGender.male);
      expect(db.aiCharacterBox.get('c1')!.gender, CharacterGender.male);
    });

    test('records a safe diagnostic after a top-level storage exception',
        () async {
      final c1 = character(
        id: 'c1',
        systemPrompt: '我是男性。',
      );
      await db.aiCharacterBox.put('c1', c1);
      await db.apiConfigBox.close();

      await CharacterGenderMigrator(
        db,
        api: _FakeChatApiService(),
        credentials: _FakeCredentials({}),
      ).migrate();

      expect(c1.gender, CharacterGender.male);
      final diagnosticMap = db.appSettingsBox
          .get(CharacterGenderMigrator.diagnosticKey) as Map<dynamic, dynamic>;
      expect(diagnosticMap['status'], 'completed');
      expect(diagnosticMap['saved'], 1);
      expect(diagnosticMap['saveFailures'], 0);
      final diagnostic = jsonEncode(
        diagnosticMap,
      );
      expect(diagnostic, contains('storage_failure'));
      expect(diagnostic, isNot(contains('我是男性')));

      await Hive.close();
      await reopenLifecycleHive(directory);
      final reopenedDb = DatabaseService();
      expect(
        reopenedDb.aiCharacterBox.get('c1')!.gender,
        CharacterGender.male,
      );
    });

    test('completion marker permanently locks the result', () async {
      await db.apiConfigBox.put('config-a', apiConfig('config-a'));
      await db.aiCharacterBox.put(
        'c1',
        character(id: 'c1', apiConfigId: 'config-a'),
      );
      final firstApi = _FakeChatApiService(
        responsesByModel: {
          'model-config-a': _responseFor({'c1': '男'}),
        },
      );
      final migrator = CharacterGenderMigrator(
        db,
        api: firstApi,
        credentials: _FakeCredentials({'config-a': 'key-a'}),
      );
      await migrator.migrate();

      db.aiCharacterBox.get('c1')!.name = '另一个角色';
      final secondApi = _FakeChatApiService(
        errorsByModel: {'model-config-a': StateError('must not call')},
      );
      await CharacterGenderMigrator(
        db,
        api: secondApi,
        credentials: _FakeCredentials({'config-a': 'key-a'}),
      ).migrate();

      expect(db.aiCharacterBox.get('c1')!.gender, CharacterGender.male);
      expect(secondApi.calls, isEmpty);
    });

    test('characters created after migration begins are not legacy candidates',
        () async {
      await db.apiConfigBox.put('config-a', apiConfig('config-a'));
      await db.aiCharacterBox.put(
        'old',
        character(id: 'old', apiConfigId: 'config-a'),
      );
      var failSave = true;
      Future<void> failFirstSave(AICharacter value) async {
        if (failSave) {
          failSave = false;
          throw StateError('pause migration');
        }
        await db.aiCharacterBox.put(value.id, value);
      }

      final api = _FakeChatApiService(
        responsesByModel: {
          'model-config-a': _responseFor({'old': '男'}),
        },
      );
      await CharacterGenderMigrator(
        db,
        api: api,
        credentials: _FakeCredentials({'config-a': 'key-a'}),
        saveCharacter: failFirstSave,
      ).migrate();
      await db.aiCharacterBox.put('new', character(id: 'new'));

      final restartApi = _FakeChatApiService(
        responsesByModel: {
          'model-config-a': _responseFor({'old': '男'}),
        },
      );
      await CharacterGenderMigrator(
        db,
        api: restartApi,
        credentials: _FakeCredentials({'config-a': 'key-a'}),
      ).migrate();

      expect(restartApi.calls, isEmpty);
      expect(db.aiCharacterBox.get('old')!.gender, CharacterGender.male);
      expect(db.aiCharacterBox.get('new')!.gender, CharacterGender.female);
    });

    test('records only safe diagnostic categories after an LLM failure',
        () async {
      await db.apiConfigBox.put('config-a', apiConfig('config-a'));
      await db.aiCharacterBox.put(
        'c1',
        character(id: 'c1', apiConfigId: 'config-a'),
      );
      final api = _FakeChatApiService(
        errorsByModel: {'model-config-a': StateError('TOP_SECRET_PROMPT')},
      );

      await CharacterGenderMigrator(
        db,
        api: api,
        credentials: _FakeCredentials({'config-a': 'key-a'}),
      ).migrate();

      final diagnostic = jsonEncode(
        db.appSettingsBox.get(CharacterGenderMigrator.diagnosticKey),
      );
      expect(diagnostic, contains('request_failed'));
      expect(diagnostic, isNot(contains('TOP_SECRET_PROMPT')));
      expect(diagnostic, isNot(contains('我是')));
    });
  });
}

Map<String, dynamic> _responseFor(Map<String, String> genders) => {
      'success': true,
      'message': jsonEncode([
        for (final entry in genders.entries)
          {'id': entry.key, 'gender': entry.value},
      ]),
    };

Set<String> _requestIds(
  ({String model, List<Map<String, dynamic>> messages}) call,
) {
  final entries = jsonDecode(call.messages.last['content']! as String) as List;
  return entries.map((entry) => (entry as Map)['id'] as String).toSet();
}

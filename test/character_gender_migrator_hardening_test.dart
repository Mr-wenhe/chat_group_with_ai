import 'dart:convert';
import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/features/ai_character/character_gender_migrator.dart';
import 'package:chat_group/features/ai_character/character_gender_llm_inference.dart';
import 'package:chat_group/services/chat_api_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'helpers/lifecycle_hive.dart';
import 'helpers/fault_injecting_box.dart';

class _FakeCredentials implements ApiCredentialResolver {
  final Map<String, String?> values;

  _FakeCredentials(this.values);

  @override
  Future<String?> resolve(ApiConfig config) async => values[config.id];
}

class _FakeChatApiService extends ChatApiService {
  final Map<String, Map<String, dynamic>> responsesByModel;
  final Map<String, Duration> delaysByModel;
  final calls = <({String model, List<Map<String, dynamic>> messages})>[];
  int activeCalls = 0;
  int maxConcurrentCalls = 0;

  _FakeChatApiService({
    this.responsesByModel = const {},
    this.delaysByModel = const {},
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
    activeCalls++;
    if (activeCalls > maxConcurrentCalls) {
      maxConcurrentCalls = activeCalls;
    }
    try {
      final delay = delaysByModel[model];
      if (delay != null) {
        final delayFuture = Future<void>.delayed(delay);
        if (cancelToken == null) {
          await delayFuture;
        } else {
          await Future.any<void>([
            delayFuture,
            cancelToken.whenCancel.then<void>((_) {}),
          ]);
        }
      }
      if (cancelToken?.isCancelled == true) {
        return const <String, dynamic>{
          'success': false,
          'message': 'cancelled',
        };
      }
      return responsesByModel[model] ??
          const <String, dynamic>{'success': true, 'message': '[]'};
    } finally {
      activeCalls--;
    }
  }
}

AICharacter character({
  required String id,
  String name = 'Amy',
  String systemPrompt = '',
  String apiConfigId = '',
}) =>
    AICharacter(
      id: id,
      name: name,
      avatar: 'A',
      age: 28,
      role: '助手',
      personalityTags: const [],
      systemPrompt: systemPrompt,
      apiKey: '',
      apiProvider: 'custom',
      apiConfigId: apiConfigId,
    );

ApiConfig apiConfig(String id) => ApiConfig(
      id: id,
      name: id,
      provider: 'custom',
      modelName: 'model-$id',
      customBaseUrl: 'https://example.invalid',
      hasCredential: true,
      credentialId: 'credential-$id',
    );

void main() {
  late Directory directory;
  late DatabaseService db;

  setUp(() async {
    directory = await openLifecycleHive();
    db = DatabaseService();
  });

  tearDown(() => closeLifecycleHive(directory, db));

  test('splits large groups and limits remote request concurrency', () async {
    await db.apiConfigBox.put('config-a', apiConfig('config-a'));
    await db.aiCharacterBox.putAll({
      for (var index = 0; index < 9; index++)
        'c$index': character(id: 'c$index', apiConfigId: 'config-a'),
    });
    final api = _FakeChatApiService(
      delaysByModel: {'model-config-a': const Duration(milliseconds: 10)},
      responsesByModel: {
        'model-config-a': _responseFor({
          for (var index = 0; index < 9; index++) 'c$index': '男',
        }),
      },
    );

    await CharacterGenderMigrator(
      db,
      api: api,
      credentials: _FakeCredentials({'config-a': 'key-a'}),
    ).migrate();

    expect(api.calls, hasLength(3));
    expect(api.maxConcurrentCalls, lessThanOrEqualTo(2));
    expect(
      api.calls.every((call) => _requestIds(call).length <= 4),
      isTrue,
    );
    expect(
      db.aiCharacterBox.values.every(
        (character) => character.gender == CharacterGender.male,
      ),
      isTrue,
    );
  });

  test('restored progress protects fallback after a later session failure',
      () async {
    final completed = character(id: 'completed', name: '阿杰');
    final recovered = character(
      id: 'recovered',
      systemPrompt: '我是男性。',
    );
    completed.gender = CharacterGender.female;
    recovered.gender = CharacterGender.female;
    await db.aiCharacterBox.putAll({
      completed.id: completed,
      recovered.id: recovered,
    });
    await db.appSettingsBox.put(
      CharacterGenderMigrator.stateKey,
      {
        'candidateIds': ['completed', 'recovered'],
        'completedIds': ['completed'],
        'decisions': {'recovered': 'female'},
      },
    );
    await db.apiConfigBox.close();

    await CharacterGenderMigrator(
      db,
      api: _FakeChatApiService(),
      credentials: _FakeCredentials({}),
    ).migrate();

    expect(completed.gender, CharacterGender.female);
    expect(recovered.gender, CharacterGender.female);
  });

  test('top-level fallback completes the durable migration lock', () async {
    await db.apiConfigBox.put('config-a', apiConfig('config-a'));
    await db.aiCharacterBox.put(
      'c1',
      character(
        id: 'c1',
        apiConfigId: 'config-a',
        systemPrompt: '我是男性。',
      ),
    );
    await db.apiConfigBox.close();

    await CharacterGenderMigrator(
      db,
      api: _FakeChatApiService(),
      credentials: _FakeCredentials({'config-a': 'key-a'}),
    ).migrate();

    final diagnostic = db.appSettingsBox
        .get(CharacterGenderMigrator.diagnosticKey) as Map<dynamic, dynamic>;
    expect(diagnostic['status'], 'completed');
    expect(diagnostic['saved'], 1);
    expect(diagnostic['saveFailures'], 0);

    await Hive.close();
    await reopenLifecycleHive(directory);
    final reopenedDb = DatabaseService();
    final secondApi = _FakeChatApiService(
      responsesByModel: {
        'model-config-a': _responseFor({'c1': '女'}),
      },
    );

    await CharacterGenderMigrator(
      reopenedDb,
      api: secondApi,
      credentials: _FakeCredentials({'config-a': 'key-a'}),
    ).migrate();

    expect(secondApi.calls, isEmpty);
    expect(
      reopenedDb.aiCharacterBox.get('c1')!.gender,
      CharacterGender.male,
    );
    expect(
      reopenedDb.appSettingsBox.get(CharacterGenderMigrator.migrationKey),
      true,
    );
  });

  test('late completion cleanup failure preserves this run saved count',
      () async {
    await db.apiConfigBox.put('config-a', apiConfig('config-a'));
    await db.aiCharacterBox.put(
      'c1',
      character(id: 'c1', apiConfigId: 'config-a'),
    );
    final appSettings = FaultInjectingBox(
      db.appSettingsBox,
      failStateDelete: true,
    );
    final api = _FakeChatApiService(
      responsesByModel: {
        'model-config-a': _responseFor({'c1': '男'}),
      },
    );

    await CharacterGenderMigrator(
      TestDatabaseService(appSettings),
      api: api,
      credentials: _FakeCredentials({'config-a': 'key-a'}),
    ).migrate();

    final diagnostic = appSettings.get(CharacterGenderMigrator.diagnosticKey)
        as Map<dynamic, dynamic>;
    expect(diagnostic['status'], 'completed');
    expect(diagnostic['saved'], 1);
    expect(diagnostic['saveFailures'], 0);
    expect(appSettings.get(CharacterGenderMigrator.migrationKey), true);
  });

  test('progress write failure does not become a character save failure',
      () async {
    await db.apiConfigBox.put('config-a', apiConfig('config-a'));
    await db.aiCharacterBox.put(
      'c1',
      character(id: 'c1', apiConfigId: 'config-a'),
    );
    final appSettings = FaultInjectingBox(
      db.appSettingsBox,
      failStatePutAt: 4,
    );
    final api = _FakeChatApiService(
      responsesByModel: {
        'model-config-a': _responseFor({'c1': '男'}),
      },
    );

    await CharacterGenderMigrator(
      TestDatabaseService(appSettings),
      api: api,
      credentials: _FakeCredentials({'config-a': 'key-a'}),
    ).migrate();

    final diagnostic = appSettings.get(CharacterGenderMigrator.diagnosticKey)
        as Map<dynamic, dynamic>;
    expect(diagnostic['status'], 'completed');
    expect(diagnostic['saved'], 1);
    expect(diagnostic['saveFailures'], 0);
    expect(diagnostic['stateSaveFailures'], 1);
  });

  test('LLM timeout covers all request waves', () async {
    await db.apiConfigBox.put('config-a', apiConfig('config-a'));
    await db.aiCharacterBox.putAll({
      for (var index = 0; index < 9; index++)
        'c$index': character(id: 'c$index', apiConfigId: 'config-a'),
    });
    final api = _FakeChatApiService(
      delaysByModel: {'model-config-a': const Duration(milliseconds: 100)},
      responsesByModel: {
        'model-config-a': _responseFor({
          for (var index = 0; index < 9; index++) 'c$index': '男',
        }),
      },
    );
    final inference = CharacterGenderLlmInference(
      api: api,
      credentials: _FakeCredentials({'config-a': 'key-a'}),
      phaseTimeout: const Duration(milliseconds: 150),
    );
    final stopwatch = Stopwatch()..start();

    final report = await inference.infer(
      db.aiCharacterBox.values.toList(growable: false),
      const {},
      configs: db.apiConfigBox.values,
      cancellation: null,
      isCancelled: () => false,
    );
    stopwatch.stop();

    expect(api.calls, hasLength(3));
    expect(report.reasonCodes, contains('timeout'));
    expect(
      stopwatch.elapsed,
      lessThan(const Duration(milliseconds: 250)),
    );
  });

  test('rebuilds an invalid migration state from the current snapshot',
      () async {
    await db.apiConfigBox.put('config-a', apiConfig('config-a'));
    await db.aiCharacterBox.put(
      'c1',
      character(id: 'c1', apiConfigId: 'config-a'),
    );
    await db.appSettingsBox.put(
      CharacterGenderMigrator.stateKey,
      {
        'candidateIds': 'c1',
        'completedIds': ['c1'],
        'decisions': <String, String>{},
      },
    );
    final api = _FakeChatApiService(
      responsesByModel: {
        'model-config-a': _responseFor({'c1': '男'})
      },
    );

    await CharacterGenderMigrator(
      db,
      api: api,
      credentials: _FakeCredentials({'config-a': 'key-a'}),
    ).migrate();

    expect(api.calls, hasLength(1));
    expect(db.aiCharacterBox.get('c1')!.gender, CharacterGender.male);
    expect(
      jsonEncode(db.appSettingsBox.get(CharacterGenderMigrator.diagnosticKey)),
      contains('state_rebuilt'),
    );
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

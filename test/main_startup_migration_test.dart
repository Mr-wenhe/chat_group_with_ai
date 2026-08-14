import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/features/ai_character/character_gender_migrator.dart';
import 'package:chat_group/features/memory/memory_migrator.dart';
import 'package:chat_group/services/chat_api_service.dart';
import 'package:chat_group/main.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/lifecycle_hive.dart';

class _FakeCredentials implements ApiCredentialResolver {
  @override
  Future<String?> resolve(ApiConfig config) async => 'fake-key';
}

class _CancelableDelayedChatApiService extends ChatApiService {
  final Duration delay;
  int calls = 0;
  bool cancellationObserved = false;

  _CancelableDelayedChatApiService(this.delay);

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
    calls++;
    final delayFuture = Future<void>.delayed(delay);
    if (cancelToken == null) {
      await delayFuture;
    } else {
      await Future.any<void>([
        delayFuture,
        cancelToken.whenCancel.then<void>((_) {
          cancellationObserved = true;
        }),
      ]);
    }
    if (cancelToken?.isCancelled == true) {
      return const {'success': false, 'message': 'cancelled'};
    }
    return {
      'success': true,
      'message': jsonEncode([
        {'id': 'old-male', 'gender': '女'},
        {'id': 'old-female', 'gender': '男'},
      ]),
    };
  }
}

class _HangingGenderMigrator extends CharacterGenderMigrator {
  bool cancelled = false;

  _HangingGenderMigrator(super.db);

  @override
  Future<int> migrate() => Completer<int>().future;

  @override
  void cancel() => cancelled = true;
}

class _HangingMemoryMigrator extends MemoryMigrator {
  _HangingMemoryMigrator(super.db);

  @override
  Future<MemoryMigrationReport> migrate({bool force = false}) =>
      Completer<MemoryMigrationReport>().future;
}

AICharacter _character({
  required String id,
  String systemPrompt = '',
}) =>
    AICharacter(
      id: id,
      name: id,
      avatar: 'A',
      age: 28,
      role: '助手',
      personalityTags: const [],
      systemPrompt: systemPrompt,
      apiKey: '',
      apiProvider: 'custom',
      apiConfigId: 'config-a',
      hasKnownGender: false,
    );

ApiConfig _config() => ApiConfig(
      id: 'config-a',
      name: 'config-a',
      provider: 'custom',
      modelName: 'model-a',
      customBaseUrl: 'https://example.invalid',
      hasCredential: true,
      credentialId: 'credential-a',
    );

void main() {
  late Directory directory;
  late DatabaseService db;

  setUp(() async {
    directory = await openLifecycleHive();
    db = DatabaseService();
  });

  tearDown(() => closeLifecycleHive(directory, db));

  test('timeout finishes local migration before helper returns', () async {
    await db.apiConfigBox.put('config-a', _config());
    await db.aiCharacterBox.putAll({
      'old-male': _character(id: 'old-male', systemPrompt: '我是男性。'),
      'old-female': _character(id: 'old-female'),
    });
    final api = _CancelableDelayedChatApiService(
      const Duration(seconds: 1),
    );
    var writes = 0;

    await runCharacterGenderMigration(
      db,
      migrator: CharacterGenderMigrator(
        db,
        api: api,
        credentials: _FakeCredentials(),
        llmPhaseTimeout: const Duration(seconds: 5),
        saveCharacter: (character) async {
          writes++;
          await db.aiCharacterBox.put(character.id, character);
        },
      ),
      timeout: const Duration(milliseconds: 10),
    );

    expect(api.calls, 1);
    expect(api.cancellationObserved, isTrue);
    expect(writes, 2);
    expect(
      db.aiCharacterBox.get('old-male')!.gender,
      CharacterGender.male,
    );
    expect(
      db.aiCharacterBox.get('old-female')!.gender,
      CharacterGender.female,
    );
    expect(db.appSettingsBox.get(CharacterGenderMigrator.migrationKey), true);

    final writesWhenReturned = writes;
    final edited = db.aiCharacterBox.get('old-male')!;
    edited.name = '用户刚编辑的角色';
    await db.aiCharacterBox.put(edited.id, edited);
    await db.aiCharacterBox.delete('old-female');
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(writes, writesWhenReturned);
    expect(db.aiCharacterBox.get('old-male')!.name, '用户刚编辑的角色');
    expect(db.aiCharacterBox.get('old-female'), isNull);
    final diagnostic = jsonEncode(
      db.appSettingsBox.get(CharacterGenderMigrator.diagnosticKey),
    );
    expect(diagnostic, contains('cancelled'));
    expect(diagnostic, isNot(contains('fake-key')));
    expect(diagnostic, isNot(contains('我是')));
  });

  test('timeout does not wait forever for the cancelled migration', () async {
    final migrator = _HangingGenderMigrator(db);

    await runCharacterGenderMigration(
      db,
      migrator: migrator,
      timeout: const Duration(milliseconds: 5),
    ).timeout(const Duration(seconds: 1));

    expect(migrator.cancelled, isTrue);
  });

  test('memory startup migration timeout does not block startup forever',
      () async {
    final migrator = _HangingMemoryMigrator(db);

    await runMemoryMigration(
      db,
      migrator: migrator,
      timeout: const Duration(milliseconds: 5),
    ).timeout(const Duration(seconds: 1));
  });

  test('top-level migration failure keeps a final session gender', () async {
    final character = _character(
      id: 'old-male',
      systemPrompt: '我是男性。',
    );
    await db.aiCharacterBox.put(character.id, character);
    await db.apiConfigBox.close();
    final api = _CancelableDelayedChatApiService(Duration.zero);

    await runCharacterGenderMigration(
      db,
      migrator: CharacterGenderMigrator(
        db,
        api: api,
        credentials: _FakeCredentials(),
      ),
      timeout: const Duration(milliseconds: 100),
    );

    expect(api.calls, isZero);
    expect(db.aiCharacterBox.get(character.id)!.gender, CharacterGender.male);
    final diagnostic = jsonEncode(
      db.appSettingsBox.get(CharacterGenderMigrator.diagnosticKey),
    );
    expect(diagnostic, contains('storage_failure'));
    expect(diagnostic, isNot(contains('fake-key')));
    expect(diagnostic, isNot(contains('我是男性')));
  });
}

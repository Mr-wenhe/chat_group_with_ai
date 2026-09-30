import 'dart:io';

import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/tool_permission.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/core/storage/credential_repository.dart';
import 'package:chat_group/core/storage/debug_credential_cache.dart';
import 'package:chat_group/core/storage/legacy_api_credential_migrator.dart';
import 'package:chat_group/core/storage/secure_storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

class _MemoryCredentialStore implements CredentialStore {
  final values = <String, String>{};
  bool failWrites = false;

  /// 安全存储读取次数。macOS 上每次读取都可能触发一次钥匙串密码框，
  /// 启动路径的读取次数因此是可直接断言的用户可见行为。
  int readCount = 0;

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async {
    readCount++;
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (failWrites) throw StateError('write failed');
    values[key] = value;
  }
}

class _NoopLegacyStorage extends SecureStorageService {
  @override
  Future<bool> saveApiConfigKey(String configId, String apiKey) async => true;

  @override
  Future<String?> getApiConfigKey(String configId) async => null;

  @override
  Future<void> deleteApiConfigKey(String configId) async {}
}

class _MigrationHarness {
  final _MemoryCredentialStore store;
  final Map<String, ApiConfig> configs;
  final List<AICharacter> characters;
  late final CredentialRepository repository;

  _MigrationHarness({
    required this.store,
    required Iterable<ApiConfig> configs,
    required this.characters,
  }) : configs = {for (final config in configs) config.id: config} {
    repository = CredentialRepository(
      store: store,
      legacyStorage: _NoopLegacyStorage(),
      secureStorageAvailable: true,
    );
  }

  Future<void> migrate() => LegacyApiCredentialMigrator(repository).migrate(
        configs: configs.values,
        characters: characters,
        saveConfig: (config) async => configs[config.id] = config,
        saveCharacter: (_) async {},
      );
}

AICharacter _character(String id, String apiKey) => AICharacter(
      id: id,
      name: '角色$id',
      avatar: 'A',
      age: 28,
      role: 'tester',
      personalityTags: const ['stable'],
      systemPrompt: 'stay in character',
      memorySummary: 'memory',
      apiKey: apiKey,
      apiProvider: 'deepseek',
      modelName: 'deepseek-chat',
      customBaseUrl: 'https://example.invalid/v1',
      hourlyReplyLimit: 7,
      isActive: true,
      createdAt: DateTime.utc(2026, 1, 2),
    );

/// 与 [_character] 的 provider/model/baseUrl 对齐，便于构造「可被旧角色复用」的配置。
ApiConfig _migratedConfig(CredentialRepository repository, String id) =>
    ApiConfig(
      id: id,
      name: id,
      provider: 'deepseek',
      modelName: 'deepseek-chat',
      customBaseUrl: 'https://example.invalid/v1',
      credentialId: repository.credentialIdFor(id),
      hasCredential: true,
    );

CredentialRepository _repositoryFor(_MemoryCredentialStore store) =>
    CredentialRepository(
      store: store,
      legacyStorage: _NoopLegacyStorage(),
      secureStorageAvailable: true,
    );

void main() {
  setUp(CredentialRepository.clearCache);

  test('migrates a legacy ApiConfig key after secure readback', () async {
    final config = ApiConfig(
      id: 'legacy-config',
      name: 'legacy',
      provider: 'deepseek',
      apiKey: 'secret',
    );
    final harness = _MigrationHarness(
      store: _MemoryCredentialStore(),
      configs: [config],
      characters: [],
    );

    await harness.migrate();

    expect(config.legacyApiKeyForMigration, isEmpty);
    expect(config.hasCredential, isTrue);
    expect(config.credentialId, harness.repository.credentialIdFor(config.id));
    expect((await harness.repository.read(config.id)).value, 'secret');
  });

  test('keeps every legacy field when secure storage write fails', () async {
    final store = _MemoryCredentialStore()..failWrites = true;
    final config = ApiConfig(
      id: 'legacy-config',
      name: 'legacy',
      provider: 'deepseek',
      apiKey: 'config-secret',
    );
    final character = _character('a', 'character-secret');
    final harness = _MigrationHarness(
      store: store,
      configs: [config],
      characters: [character],
    );

    await harness.migrate();

    expect(config.legacyApiKeyForMigration, 'config-secret');
    expect(config.hasCredential, isFalse);
    expect(character.apiKey, 'character-secret');
    expect(character.apiConfigId, isEmpty);
  });

  test('repeated migration does not create duplicate configs', () async {
    final character = _character('a', 'shared-secret');
    final harness = _MigrationHarness(
      store: _MemoryCredentialStore(),
      configs: [],
      characters: [character],
    );

    await harness.migrate();
    final firstConfigId = character.apiConfigId;
    await harness.migrate();

    expect(harness.configs, hasLength(1));
    expect(character.apiConfigId, firstConfigId);
    expect(character.apiKey, isEmpty);
  });

  test('multiple characters with one legacy key reuse one config', () async {
    final first = _character('a', 'shared-secret');
    final second = _character('b', 'shared-secret');
    final harness = _MigrationHarness(
      store: _MemoryCredentialStore(),
      configs: [],
      characters: [second, first],
    );

    await harness.migrate();

    expect(harness.configs, hasLength(1));
    expect(first.apiConfigId, second.apiConfigId);
    expect(first.apiKey, isEmpty);
    expect(second.apiKey, isEmpty);
  });

  test('failed legacy character key cannot be resolved for a request',
      () async {
    final store = _MemoryCredentialStore()..failWrites = true;
    final character = _character('a', 'must-not-be-used');
    final harness = _MigrationHarness(
      store: store,
      configs: [],
      characters: [character],
    );

    await harness.migrate();
    final unmigrated = ApiConfig(
      id: 'unmigrated',
      name: 'unmigrated',
      provider: character.apiProvider,
      apiKey: character.apiKey,
      hasCredential: true,
    );

    expect(character.apiConfigId, isEmpty);
    expect(
      await SecureApiCredentialResolver(harness.repository).resolve(unmigrated),
      isNull,
    );
  });

  test('migration preserves group, message, and other character fields',
      () async {
    final character = _character('a', 'secret');
    final group = ChatGroup(
      id: 'group',
      name: 'unchanged group',
      theme: 'theme',
      aiCharacterIds: [character.id],
    );
    final message = Message(
      id: 'message',
      groupId: group.id,
      senderId: 'user',
      senderType: 'user',
      content: 'unchanged message',
    );
    final harness = _MigrationHarness(
      store: _MemoryCredentialStore(),
      configs: [],
      characters: [character],
    );

    await harness.migrate();

    expect(group.name, 'unchanged group');
    expect(group.aiCharacterIds, ['a']);
    expect(message.content, 'unchanged message');
    expect(character.name, '角色a');
    expect(character.personalityTags, ['stable']);
    expect(character.memorySummary, 'memory');
    expect(character.hourlyReplyLimit, 7);
  });

  test('migrates and reopens an isolated legacy Hive fixture with rollback',
      () async {
    final root = await Directory.systemTemp.createTemp('credential-migration-');
    final active = await Directory('${root.path}/active').create();
    final rollback = await Directory('${root.path}/rollback').create();
    addTearDown(() async {
      await Hive.close();
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    });

    Hive.init(active.path);
    if (!Hive.isAdapterRegistered(0)) {
      Hive.registerAdapter(AICharacterAdapter());
    }
    if (!Hive.isAdapterRegistered(24)) {
      Hive.registerAdapter(CharacterGenderAdapter());
    }
    if (!Hive.isAdapterRegistered(1)) {
      Hive.registerAdapter(ChatGroupAdapter());
    }
    if (!Hive.isAdapterRegistered(2)) {
      Hive.registerAdapter(MessageAdapter());
    }
    if (!Hive.isAdapterRegistered(4)) {
      Hive.registerAdapter(ApiConfigAdapter());
    }
    if (!Hive.isAdapterRegistered(10)) {
      Hive.registerAdapter(ToolPermissionAdapter());
    }
    var configs = await Hive.openBox<ApiConfig>('api_configs');
    var characters = await Hive.openBox<AICharacter>('ai_characters');
    var groups = await Hive.openBox<ChatGroup>('chat_groups');
    var messages = await Hive.openBox<Message>('messages');
    final first = _character('a', 'shared-secret');
    final second = _character('b', 'shared-secret');
    await configs.put(
      'legacy-config',
      ApiConfig(
        id: 'legacy-config',
        name: 'legacy',
        provider: 'deepseek',
        apiKey: 'config-secret',
      ),
    );
    await characters.putAll({'a': first, 'b': second});
    await groups.put(
      'group',
      ChatGroup(
        id: 'group',
        name: 'unchanged group',
        theme: 'theme',
        aiCharacterIds: const ['a', 'b'],
      ),
    );
    await messages.put(
      'message',
      Message(
        id: 'message',
        groupId: 'group',
        senderId: 'user',
        senderType: 'user',
        content: 'unchanged message',
      ),
    );
    await Hive.close();
    for (final file in active.listSync().whereType<File>()) {
      await file.copy('${rollback.path}/${file.uri.pathSegments.last}');
    }

    Hive.init(active.path);
    configs = await Hive.openBox<ApiConfig>('api_configs');
    characters = await Hive.openBox<AICharacter>('ai_characters');
    groups = await Hive.openBox<ChatGroup>('chat_groups');
    messages = await Hive.openBox<Message>('messages');
    final repository = CredentialRepository(
      store: _MemoryCredentialStore(),
      legacyStorage: _NoopLegacyStorage(),
      secureStorageAvailable: true,
    );
    Future<void> migrate() => LegacyApiCredentialMigrator(repository).migrate(
          configs: configs.values,
          characters: characters.values,
          saveConfig: (config) => configs.put(config.id, config),
          saveCharacter: (character) => characters.put(character.id, character),
        );

    await migrate();
    await Hive.close();
    Hive.init(active.path);
    configs = await Hive.openBox<ApiConfig>('api_configs');
    characters = await Hive.openBox<AICharacter>('ai_characters');
    groups = await Hive.openBox<ChatGroup>('chat_groups');
    messages = await Hive.openBox<Message>('messages');
    await migrate();

    expect(configs, hasLength(2));
    expect(
      configs.get('legacy-config')!.legacyApiKeyForMigration,
      isEmpty,
    );
    expect(characters.get('a')!.apiKey, isEmpty);
    expect(characters.get('a')!.apiConfigId, characters.get('b')!.apiConfigId);
    expect(groups.get('group')!.name, 'unchanged group');
    expect(messages.get('message')!.content, 'unchanged message');

    await Hive.close();
    Hive.init(rollback.path);
    configs = await Hive.openBox<ApiConfig>('api_configs');
    characters = await Hive.openBox<AICharacter>('ai_characters');
    groups = await Hive.openBox<ChatGroup>('chat_groups');
    messages = await Hive.openBox<Message>('messages');
    expect(
      configs.get('legacy-config')!.legacyApiKeyForMigration,
      'config-secret',
    );
    expect(characters.get('a')!.apiKey, 'shared-secret');
    expect(groups.get('group')!.name, 'unchanged group');
    expect(messages.get('message')!.content, 'unchanged message');
  });

  test('already-migrated configs cost no secure storage read at startup',
      () async {
    final store = _MemoryCredentialStore();
    final repository = _repositoryFor(store);
    final ids = ['a1', 'a2', 'a3', 'a4'];
    for (final id in ids) {
      store.values[repository.credentialIdFor(id)] = 'secret-$id';
    }
    final harness = _MigrationHarness(
      store: store,
      configs: [for (final id in ids) _migratedConfig(repository, id)],
      characters: [],
    );

    await harness.migrate();

    // 每个已迁移配置在 macOS 上都会触发一次钥匙串授权弹窗，启动路径必须为零。
    expect(store.readCount, 0);
  });

  test('a config with a pending legacy key is still read and migrated',
      () async {
    final config = ApiConfig(
      id: 'pending',
      name: 'pending',
      provider: 'deepseek',
      apiKey: 'pending-secret',
    );
    final harness = _MigrationHarness(
      store: _MemoryCredentialStore(),
      configs: [config],
      characters: [],
    );

    await harness.migrate();

    expect(harness.store.readCount, greaterThan(0));
    expect(config.legacyApiKeyForMigration, isEmpty);
    expect(config.hasCredential, isTrue);
    expect(config.credentialId, harness.repository.credentialIdFor(config.id));
  });

  test('a legacy character still reuses a matching migrated config', () async {
    final store = _MemoryCredentialStore();
    final repository = _repositoryFor(store);
    final config = _migratedConfig(repository, 'shared-config');
    store.values[repository.credentialIdFor(config.id)] = 'shared-secret';
    final character = _character('a', 'shared-secret');
    final harness = _MigrationHarness(
      store: store,
      configs: [config],
      characters: [character],
    );

    await harness.migrate();

    // 旧角色必须挂到已有配置上；跳过该配置的读取会让它退化成重复配置。
    expect(harness.configs, hasLength(1));
    expect(character.apiConfigId, 'shared-config');
    expect(character.apiKey, isEmpty);
  });

  group('调试镜像', () {
    late Directory directory;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('migrator_mirror_');
      Hive.init(directory.path);
      await Hive.openBox<dynamic>(DebugCredentialCache.boxName);
    });

    tearDown(() async {
      DebugCredentialCache.bind(null);
      await Hive.close();
      await directory.delete(recursive: true);
    });

    test('旧明文密钥在迁移读取之前就已镜像', () async {
      // 迁移会先读一次安全存储；macOS 上那次读取就是一次钥匙串密码框。
      // 明文就在记录里，镜像后那次读取不必再问钥匙串。
      final repository = CredentialRepository();
      final config = ApiConfig(
        id: 'pending-mirror',
        name: 'pending',
        provider: 'custom',
        apiKey: 'pending-secret',
      );
      final migrator = LegacyApiCredentialMigrator(repository);

      await migrator.seedDevelopmentCredentialCache([config]);

      expect(
        await DebugCredentialCache.read(
          repository.credentialIdFor(config.id),
          () async => fail('迁移前那次读取落到了钥匙串，会弹密码框'),
        ),
        'pending-secret',
      );
    });

    test('开发回退配置在无钥匙串的环境里也能完成迁移', () async {
      // 测试环境没有钥匙串插件，任何真正走到平台的调用都会抛
      // MissingPluginException。因此「迁移成功」本身就等价于「一次也没问过
      // 钥匙串」——这正是 macOS ad-hoc 签名下最想要的结果。
      final repository = CredentialRepository();
      final config = ApiConfig(
        id: 'dev-fallback',
        name: 'dev',
        provider: 'custom',
        apiKey: 'dev-secret',
        credentialId: CredentialRepository.developmentHiveCredentialId,
        hasCredential: true,
      );
      final configs = {config.id: config};

      await LegacyApiCredentialMigrator(repository).migrate(
        configs: configs.values,
        characters: const [],
        saveConfig: (value) async => configs[value.id] = value,
        saveCharacter: (_) async {},
      );

      expect(config.legacyApiKeyForMigration, isEmpty);
      expect(config.hasCredential, isTrue);
      expect(config.credentialId, repository.credentialIdFor(config.id));
      expect((await repository.read(config.id)).value, 'dev-secret');
    });
  });
}

import 'package:flutter/foundation.dart';

import '../models/ai_character.dart';
import '../models/api_config.dart';
import 'credential_repository.dart';
import 'debug_credential_cache.dart';

typedef SaveApiConfig = Future<void> Function(ApiConfig config);
typedef SaveAiCharacter = Future<void> Function(AICharacter character);

/// Migrates legacy Hive secrets record-by-record without clearing any box.
class LegacyApiCredentialMigrator {
  final CredentialRepository credentials;

  const LegacyApiCredentialMigrator(this.credentials);

  Future<void> migrate({
    required Iterable<ApiConfig> configs,
    required Iterable<AICharacter> characters,
    required SaveApiConfig saveConfig,
    required SaveAiCharacter saveCharacter,
  }) async {
    if (!credentials.secureStorageAvailable) return;

    final configList = configs.toList(growable: false);
    final characterList = characters.toList(growable: false);
    final configsById = {for (final config in configList) config.id: config};

    await seedDevelopmentCredentialCache(configList);

    // 旧角色明文密钥先分组：这一步只读内存，不触碰安全存储。
    final legacyGroups = <_CredentialFingerprint, List<AICharacter>>{};
    for (final character in characterList) {
      if (character.apiKey.isEmpty) continue;
      legacyGroups
          .putIfAbsent(_fingerprintForCharacter(character), () => [])
          .add(character);
    }

    // 只有 provider/model/baseUrl 与某个待迁移角色相同的配置，才可能被它复用为
    // ApiConfig。其余配置即便读出密钥，也只是往 reusable 里塞一条无人查询的记录。
    final reusableTriples = {
      for (final fingerprint in legacyGroups.keys)
        (fingerprint.provider, fingerprint.model, fingerprint.baseUrl),
    };

    final reusable = <_CredentialFingerprint, ApiConfig>{};

    for (final config in configList) {
      final mayBeReused = reusableTriples.contains(
        (config.provider, config.modelName, config.customBaseUrl),
      );
      // 已迁移完成的配置没有可写字段，跳过即可省掉一次安全存储读取。macOS 上
      // 每次读取都可能弹出一次钥匙串密码框，而这段代码每次启动都会执行。
      if (!mayBeReused && _isFullyMigrated(config)) continue;
      final secret = await _migrateConfig(config, saveConfig);
      if (secret != null) {
        reusable[_fingerprintForConfig(config, secret)] = config;
      }
    }

    for (final entry in legacyGroups.entries) {
      final group = entry.value..sort((a, b) => a.id.compareTo(b.id));
      final config = reusable[entry.key] ??
          await _createConfig(
              group.first, entry.key.secret, configsById, saveConfig);
      if (config == null) continue;
      reusable[entry.key] = config;
      configsById[config.id] = config;
      for (final character in group) {
        await _linkAndClearCharacter(character, config, saveCharacter);
      }
    }
  }

  /// 把记录里现成的旧明文密钥灌进调试镜像，必须在任何读取之前执行。
  ///
  /// [_migrateConfig] 会先读一次安全存储再写；macOS 上那次读取就是一次钥匙串
  /// 密码框，而这段代码每次启动都会跑。待迁移配置的明文就在自己的
  /// `_legacyApiKey` 里，先镜像一次就能让那次读取落在 Hive 上，弹窗归零。
  ///
  /// 镜像不可用时 [DebugCredentialCache.mirror] 返回 false，流程照旧退化到
  /// 钥匙串，不会丢值。
  @visibleForTesting
  Future<void> seedDevelopmentCredentialCache(
    Iterable<ApiConfig> configs,
  ) async {
    if (!DebugCredentialCache.enabled) return;
    for (final config in configs) {
      final legacy = config.legacyApiKeyForMigration ?? '';
      if (legacy.isEmpty) continue;
      await DebugCredentialCache.mirror(
        credentials.credentialIdFor(config.id),
        legacy,
      );
    }
  }

  /// 记录已指向安全存储、且没有待迁移的旧明文密钥——迁移对它无事可做。
  ///
  /// 判据与 [_migrateConfig] 的快速返回保持一致：旧明文密钥非 null 时只要为空即可
  /// （读取后必然走快速返回），为 null 时才需要复核 `hasCredential` 与
  /// `credentialId`。判据偏严只会多读一次安全存储，偏松则会漏掉迁移。
  bool _isFullyMigrated(ApiConfig config) {
    final legacy = config.legacyApiKeyForMigration;
    if (legacy != null) return legacy.isEmpty;
    return config.hasCredential &&
        config.credentialId == credentials.credentialIdFor(config.id);
  }

  Future<String?> _migrateConfig(
    ApiConfig config,
    SaveApiConfig saveConfig,
  ) async {
    final legacySecret = config.legacyApiKeyForMigration ?? '';
    var secret = (await credentials.read(config.id)).value;
    if (legacySecret.isNotEmpty) {
      final write = await credentials.save(config.id, legacySecret);
      if (!write.isSuccess) return null;
      secret = (await credentials.read(config.id)).value;
      if (secret != legacySecret) return null;
    }
    if (secret == null || secret.isEmpty) return null;
    final credentialId = credentials.credentialIdFor(config.id);
    if (config.legacyApiKeyForMigration?.isEmpty ??
        true && config.hasCredential && config.credentialId == credentialId) {
      return secret;
    }

    final oldLegacy = config.legacyApiKeyForMigration ?? '';
    final oldCredentialId = config.credentialId;
    final oldHasCredential = config.hasCredential;
    config
      ..setLegacyApiKeyForMigration('')
      ..credentialId = credentialId
      ..hasCredential = true;
    try {
      await saveConfig(config);
      return secret;
    } catch (_) {
      config
        ..setLegacyApiKeyForMigration(oldLegacy)
        ..credentialId = oldCredentialId
        ..hasCredential = oldHasCredential;
      return null;
    }
  }

  Future<ApiConfig?> _createConfig(
    AICharacter source,
    String secret,
    Map<String, ApiConfig> configsById,
    SaveApiConfig saveConfig,
  ) async {
    final id = 'legacy-character-${source.id}';
    if (configsById.containsKey(id)) return null;
    final write = await credentials.save(id, secret);
    if (!write.isSuccess || (await credentials.read(id)).value != secret) {
      return null;
    }
    final config = ApiConfig(
      id: id,
      name: '迁移自旧角色配置',
      provider: source.apiProvider,
      modelName: source.modelName,
      customBaseUrl: source.customBaseUrl,
      createdAt: source.createdAt,
      credentialId: credentials.credentialIdFor(id),
      hasCredential: true,
    );
    try {
      await saveConfig(config);
      return config;
    } catch (_) {
      return null;
    }
  }

  Future<void> _linkAndClearCharacter(
    AICharacter character,
    ApiConfig config,
    SaveAiCharacter saveCharacter,
  ) async {
    final oldConfigId = character.apiConfigId;
    final legacySecret = character.apiKey;
    try {
      if (character.apiConfigId != config.id) {
        character.apiConfigId = config.id;
        await saveCharacter(character);
      }
      character.apiKey = '';
      await saveCharacter(character);
    } catch (_) {
      character
        ..apiConfigId = oldConfigId
        ..apiKey = legacySecret;
      try {
        await saveCharacter(character);
      } catch (_) {}
    }
  }

  _CredentialFingerprint _fingerprintForConfig(
    ApiConfig config,
    String secret,
  ) =>
      _CredentialFingerprint(
        config.provider,
        config.modelName,
        config.customBaseUrl,
        secret,
      );

  _CredentialFingerprint _fingerprintForCharacter(AICharacter character) =>
      _CredentialFingerprint(
        character.apiProvider,
        character.modelName,
        character.customBaseUrl,
        character.apiKey,
      );
}

class _CredentialFingerprint {
  final String provider;
  final String model;
  final String baseUrl;
  final String secret;

  const _CredentialFingerprint(
    this.provider,
    this.model,
    this.baseUrl,
    this.secret,
  );

  @override
  bool operator ==(Object other) =>
      other is _CredentialFingerprint &&
      provider == other.provider &&
      model == other.model &&
      baseUrl == other.baseUrl &&
      secret == other.secret;

  @override
  int get hashCode => Object.hash(provider, model, baseUrl, secret);
}

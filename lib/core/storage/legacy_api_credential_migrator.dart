import '../models/ai_character.dart';
import '../models/api_config.dart';
import 'credential_repository.dart';

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
    final reusable = <_CredentialFingerprint, ApiConfig>{};

    for (final config in configList) {
      final secret = await _migrateConfig(config, saveConfig);
      if (secret != null) {
        reusable[_fingerprintForConfig(config, secret)] = config;
      }
    }

    final legacyGroups = <_CredentialFingerprint, List<AICharacter>>{};
    for (final character in characterList) {
      if (character.apiKey.isEmpty) continue;
      legacyGroups
          .putIfAbsent(_fingerprintForCharacter(character), () => [])
          .add(character);
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

  Future<String?> _migrateConfig(
    ApiConfig config,
    SaveApiConfig saveConfig,
  ) async {
    final legacySecret = config.legacyApiKey;
    var secret = (await credentials.read(config.id)).value;
    if (legacySecret.isNotEmpty) {
      final write = await credentials.save(config.id, legacySecret);
      if (!write.isSuccess) return null;
      secret = (await credentials.read(config.id)).value;
      if (secret != legacySecret) return null;
    }
    if (secret == null || secret.isEmpty) return null;
    final credentialId = credentials.credentialIdFor(config.id);
    if (config.legacyApiKey.isEmpty &&
        config.hasCredential &&
        config.credentialId == credentialId) {
      return secret;
    }

    final oldLegacy = config.legacyApiKey;
    final oldCredentialId = config.credentialId;
    final oldHasCredential = config.hasCredential;
    config
      ..legacyApiKey = ''
      ..credentialId = credentialId
      ..hasCredential = true;
    try {
      await saveConfig(config);
      return secret;
    } catch (_) {
      config
        ..legacyApiKey = oldLegacy
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

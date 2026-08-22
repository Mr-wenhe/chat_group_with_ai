import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/storage/credential_repository.dart';
import '../models/search_provider_config.dart';
import '../security/search_endpoint_validator.dart';
import 'search_credential_repository.dart';

class SearchProviderConfigSaveResult {
  final SearchProviderConfig? config;
  final CredentialFailure? credentialFailure;
  final String? errorMessage;
  final bool usedDevelopmentFallback;

  const SearchProviderConfigSaveResult.success(
    this.config, {
    this.usedDevelopmentFallback = false,
  })  : credentialFailure = null,
        errorMessage = null;

  const SearchProviderConfigSaveResult.failure({
    this.credentialFailure,
    this.errorMessage,
  })  : config = null,
        usedDevelopmentFallback = false;

  bool get isSuccess => config != null && credentialFailure == null;
}

class SearchProviderConfigDeleteResult {
  final CredentialFailure? failure;

  const SearchProviderConfigDeleteResult.success() : failure = null;
  const SearchProviderConfigDeleteResult.failure(this.failure);

  bool get isSuccess => failure == null;
}

class _SearchSettingsSnapshot {
  final bool hadConfigs;
  final Object? configs;
  final bool hadDefaultProvider;
  final Object? defaultProvider;

  const _SearchSettingsSnapshot({
    required this.hadConfigs,
    required this.configs,
    required this.hadDefaultProvider,
    required this.defaultProvider,
  });
}

/// Stores search provider metadata in `app_settings`; no Hive adapter or new
/// HiveType is involved.
class SearchProviderConfigStore {
  static const String configsKey = 'web_search_provider_configs_v1';
  static const String defaultProviderKey = 'web_search_default_provider_id_v1';
  static const String runtimeSettingsKey = 'web_search_runtime_settings_v2';

  final Box<dynamic> box;
  final SearchCredentialRepository credentials;
  final bool isRelease;
  final bool _allowDevelopmentFallback;

  SearchProviderConfigStore({
    Box<dynamic>? box,
    DatabaseService? db,
    SearchCredentialRepository? credentials,
    bool? isRelease,
    bool? allowDevelopmentFallback,
  })  : assert(box != null || db != null),
        box = box ?? db!.appSettingsBox,
        credentials = credentials ?? SearchCredentialRepository(),
        isRelease = isRelease ?? kReleaseMode,
        _allowDevelopmentFallback = allowDevelopmentFallback ??
            ((isRelease ?? kReleaseMode) == false &&
                !kIsWeb &&
                defaultTargetPlatform == TargetPlatform.macOS);

  bool get allowLocalDevelopmentGateway =>
      _allowDevelopmentFallback && !isRelease;

  List<SearchProviderConfig> get configs {
    final raw = box.get(configsKey);
    if (raw is! List) return const [];
    final requestedDefaultId = box.get(defaultProviderKey)?.toString().trim();
    final result = <SearchProviderConfig>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final config = SearchProviderConfig.fromMap(
        item,
        allowDevelopmentFallback: _allowDevelopmentFallback && !isRelease,
      );
      if (config.id.trim().isEmpty) continue;
      final releaseSafeConfig = isRelease &&
              config.credentialId ==
                  SearchCredentialRepository.developmentHiveCredentialId
          ? config.copyWith(
              credentialId: '',
              hasCredential: false,
              clearDevelopmentLegacyApiKey: true,
            )
          : config;
      result.add(releaseSafeConfig);
    }
    if (result.isEmpty) return const [];

    String? fallbackDefaultId;
    for (final config in result) {
      if (config.isDefault) {
        fallbackDefaultId = config.id;
        break;
      }
    }
    final defaultId = requestedDefaultId != null &&
            requestedDefaultId.isNotEmpty &&
            result.any((config) => config.id == requestedDefaultId)
        ? requestedDefaultId
        : fallbackDefaultId;
    var defaultAssigned = false;
    return List.unmodifiable(
      result.map((config) {
        final shouldBeDefault =
            defaultId != null && config.id == defaultId && !defaultAssigned;
        if (shouldBeDefault) defaultAssigned = true;
        return config.copyWith(isDefault: shouldBeDefault);
      }),
    );
  }

  SearchProviderConfig? findById(String id) {
    for (final config in configs) {
      if (config.id == id) return config;
    }
    return null;
  }

  Future<SearchProviderConfigSaveResult> save(
    SearchProviderConfig draft, {
    String enteredCredential = '',
  }) async {
    final endpoint = SearchEndpointValidator.validate(
      draft.baseUrl,
      isRelease: isRelease,
      allowLocalDevelopmentGateway: allowLocalDevelopmentGateway,
    );
    if (!endpoint.isValid) {
      return SearchProviderConfigSaveResult.failure(
        errorMessage: endpoint.message,
      );
    }

    final existing = findById(draft.id);
    final entered = enteredCredential.trim();
    CredentialReadResult? previousCredential;
    if (entered.isNotEmpty &&
        existing != null &&
        existing.hasCredential &&
        existing.credentialId == credentials.credentialIdFor(existing.id)) {
      previousCredential = await credentials.read(existing.id);
      if (!previousCredential.isAvailable &&
          previousCredential.failure != null) {
        return SearchProviderConfigSaveResult.failure(
          credentialFailure: previousCredential.failure,
          errorMessage: '现有搜索凭据不可读取，未覆盖配置',
        );
      }
    }
    var next = draft.copyWith(baseUrl: endpoint.uri!.toString());
    var usedFallback = false;

    if (entered.isNotEmpty) {
      final result = await credentials.save(draft.id, entered);
      if (result.isSuccess) {
        next = next.copyWith(
          credentialId: credentials.credentialIdFor(draft.id),
          hasCredential: true,
          clearDevelopmentLegacyApiKey: true,
        );
      } else if (_canUseDevelopmentFallback(result.failure)) {
        next = next.copyWith(
          credentialId: SearchCredentialRepository.developmentHiveCredentialId,
          hasCredential: true,
          developmentLegacyApiKey: entered,
        );
        usedFallback = true;
      } else {
        return SearchProviderConfigSaveResult.failure(
          credentialFailure: result.failure,
        );
      }
    } else if (existing != null) {
      // Empty input means preserve the existing binding; it never triggers a
      // write and does not silently erase a credential.
      next = next.copyWith(
        credentialId: existing.credentialId,
        hasCredential: existing.hasCredential,
        developmentLegacyApiKey: existing.developmentLegacyApiKey,
      );
    } else {
      next = next.copyWith(
        credentialId: '',
        hasCredential: false,
        clearDevelopmentLegacyApiKey: true,
      );
    }

    try {
      await _putConfig(next, includeDevelopmentFallback: usedFallback);
      return SearchProviderConfigSaveResult.success(
        next,
        usedDevelopmentFallback: usedFallback,
      );
    } on Object {
      // Metadata and secure storage are separate systems. If metadata fails
      // after a credential rotation, restore the old value rather than
      // deleting the only known credential. No secret enters diagnostics.
      if (!usedFallback && entered.isNotEmpty) {
        if (previousCredential?.isAvailable == true) {
          final restored = await credentials.save(
            draft.id,
            previousCredential!.value!,
          );
          if (!restored.isSuccess) await credentials.delete(draft.id);
        } else {
          await credentials.delete(draft.id);
        }
      }
      return const SearchProviderConfigSaveResult.failure(
        credentialFailure: CredentialFailure.systemError,
        errorMessage: '搜索配置保存失败',
      );
    }
  }

  Future<SearchProviderConfigDeleteResult> delete(String id) async {
    final existing = findById(id);
    if (existing == null) {
      return const SearchProviderConfigDeleteResult.success();
    }
    final secureCredentialBound = existing.credentialId !=
            SearchCredentialRepository.developmentHiveCredentialId &&
        existing.hasCredential;
    final snapshot = _captureSettings();
    try {
      final remaining = configs.where((item) => item.id != id).toList();
      await _writeConfigs(remaining);
      if (box.get(defaultProviderKey)?.toString() == id) {
        await box.delete(defaultProviderKey);
      }
    } on Object {
      await _restoreSettings(snapshot);
      return const SearchProviderConfigDeleteResult.failure(
        CredentialFailure.systemError,
      );
    }

    if (secureCredentialBound) {
      final result = await credentials.delete(id);
      if (!result.isSuccess) {
        await _restoreSettings(snapshot);
        return SearchProviderConfigDeleteResult.failure(result.failure);
      }
    }
    return const SearchProviderConfigDeleteResult.success();
  }

  Future<void> _putConfig(
    SearchProviderConfig config, {
    required bool includeDevelopmentFallback,
  }) async {
    final snapshot = _captureSettings();
    try {
      final next = configs
          .where((item) => item.id != config.id)
          .map((item) =>
              config.isDefault ? item.copyWith(isDefault: false) : item)
          .toList();
      next.add(config);
      await _writeConfigs(
        next,
        includeDevelopmentFallbackFor:
            includeDevelopmentFallback ? config.id : null,
      );
      if (config.isDefault) {
        await box.put(defaultProviderKey, config.id);
      } else if (box.get(defaultProviderKey)?.toString() == config.id) {
        await box.delete(defaultProviderKey);
      }
    } on Object {
      await _restoreSettings(snapshot);
      rethrow;
    }
  }

  bool _canUseDevelopmentFallback(CredentialFailure? failure) =>
      !isRelease && _allowDevelopmentFallback && failure != null;

  _SearchSettingsSnapshot _captureSettings() => _SearchSettingsSnapshot(
        hadConfigs: box.containsKey(configsKey),
        configs: box.get(configsKey),
        hadDefaultProvider: box.containsKey(defaultProviderKey),
        defaultProvider: box.get(defaultProviderKey),
      );

  Future<void> _writeConfigs(
    List<SearchProviderConfig> configs, {
    String? includeDevelopmentFallbackFor,
  }) async {
    if (configs.isEmpty) {
      await box.delete(configsKey);
      return;
    }
    await box.put(
      configsKey,
      configs
          .map((item) => item.toMap(
                includeDevelopmentFallback: (!isRelease &&
                        _allowDevelopmentFallback &&
                        item.credentialId ==
                            SearchCredentialRepository
                                .developmentHiveCredentialId) ||
                    (includeDevelopmentFallbackFor == item.id),
              ))
          .toList(growable: false),
    );
  }

  Future<void> _restoreSettings(_SearchSettingsSnapshot snapshot) async {
    try {
      if (snapshot.hadConfigs) {
        await box.put(configsKey, snapshot.configs);
      } else {
        await box.delete(configsKey);
      }
    } catch (_) {
      // Keep attempting the independent default-key restoration.
    }
    try {
      if (snapshot.hadDefaultProvider) {
        await box.put(defaultProviderKey, snapshot.defaultProvider);
      } else {
        await box.delete(defaultProviderKey);
      }
    } catch (_) {
      // The original operation's typed failure is more useful to callers.
    }
  }

  /// Converts persisted config maps to backup metadata without reading a
  /// plaintext legacy key. Only allowlisted fields are copied.
  static List<Map<String, dynamic>> backupValue(Object? raw) {
    if (raw is! List) return const [];
    return raw.whereType<Map>().map((item) {
      final map = <String, dynamic>{
        'id': item['id']?.toString() ?? '',
        'name': item['name']?.toString() ?? '',
        'provider': item['provider']?.toString() ?? '',
        'baseUrl': SearchEndpointValidator.sanitizeForBackup(
          item['baseUrl']?.toString() ?? '',
        ),
        'enabled': item['enabled'] != false,
        'isDefault': item['isDefault'] == true,
        'credentialRequired': item['hasCredential'] == true ||
            (item['credentialId']?.toString().isNotEmpty ?? false),
      };
      return map;
    }).toList(growable: false);
  }

  /// Restored configs are deliberately unbound, even if a backup was
  /// produced by a development build containing a fallback marker.
  static List<Map<String, dynamic>> restoreValue(Object? raw) {
    final values = backupValue(raw);
    return values
        .map((item) => {
              ...item,
              'credentialRequired': item['credentialRequired'] == true,
              'credentialId': '',
              'hasCredential': false,
            }..remove('credentialRequired'))
        .toList(growable: false);
  }

  /// Normalizes records already present on the device before a merge restore
  /// writes the whole list back. Secure credential bindings are retained, but
  /// release builds never copy a legacy Hive plaintext field.
  static List<Map<String, dynamic>> normalizeExistingValue(Object? raw) {
    if (raw is! List) return const [];
    final allowDevelopmentFallback = !kReleaseMode &&
        !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.macOS;
    return raw.whereType<Map>().map((item) {
      var config = SearchProviderConfig.fromMap(
        item,
        allowDevelopmentFallback: allowDevelopmentFallback,
      );
      if (kReleaseMode &&
          config.credentialId ==
              SearchCredentialRepository.developmentHiveCredentialId) {
        config = config.copyWith(
          credentialId: '',
          hasCredential: false,
          clearDevelopmentLegacyApiKey: true,
        );
      }
      return config.toMap(
        includeDevelopmentFallback: allowDevelopmentFallback,
      );
    }).toList(growable: false);
  }
}

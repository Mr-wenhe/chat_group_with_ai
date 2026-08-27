import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import 'package:chat_group/core/database/database_mutation_gate.dart';
import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/storage/credential_repository.dart';
import '../models/search_provider_config.dart';
import '../models/search_models.dart';
import '../models/search_runtime_settings.dart';
import '../security/search_endpoint_validator.dart';
import '../security/search_credential_validator.dart';
import 'search_credential_repository.dart';
import 'search_provider_config_backup_codec.dart';
import 'search_provider_config_results.dart';

export 'search_provider_config_results.dart';

part 'search_settings_store_credentials.dart';
part 'search_settings_store_transactions.dart';
part 'search_settings_store_transaction_helpers.dart';

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

class _CredentialRepairState {
  final Map<String, dynamic> repairs;
  final bool malformed;
  final List<String> visibleIds;

  const _CredentialRepairState({
    this.repairs = const {},
    this.malformed = false,
    this.visibleIds = const [],
  });
}

/// Stores search provider metadata in `app_settings`; no Hive adapter or new
/// HiveType is involved.
class SearchProviderConfigStore {
  static const String configsKey = 'web_search_provider_configs_v1';
  static const String defaultProviderKey = 'web_search_default_provider_id_v1';
  static const String runtimeSettingsKey = 'web_search_runtime_settings_v2';
  static const String resultCacheKey = 'web_search_result_cache_v1';
  static const String credentialRepairKey = 'web_search_credential_repairs_v1';

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

  /// Browser transports buffer XHR responses before application-level limits
  /// can run, and browsers do not provide the native DNS pinning/credential
  /// boundary used by this feature. Keep every Web build offline until a
  /// streaming Fetch adapter and an equivalent secure credential design exist.
  bool get isWebUnsupported => kIsWeb;

  /// Compatibility alias for older callers. Web is unsupported in both debug
  /// and release builds now, so callers must not key behavior off build mode.
  bool get isWebReleaseUnsupported => isWebUnsupported;

  bool _hasAmbiguousProviderIds() {
    final raw = box.get(configsKey);
    if (raw is! List) return false;
    final seen = <String>{};
    for (final item in raw) {
      if (item is! Map || !item.containsKey('id')) return true;
      final rawId = item['id'];
      if (rawId is! String) return true;
      final canonical = SearchProviderConfig.canonicalizeId(rawId);
      if (canonical == null || !seen.add(canonical)) return true;
    }
    return false;
  }

  List<SearchProviderConfig> get configs {
    final raw = box.get(configsKey);
    if (raw is! List) return const [];
    final requestedDefaultId = box.get(defaultProviderKey)?.toString().trim();
    final result = <SearchProviderConfig>[];
    final seenIds = <String>{};
    for (final item in raw) {
      if (item is! Map) continue;
      final config = SearchProviderConfig.fromMap(
        item,
        allowDevelopmentFallback: _allowDevelopmentFallback && !isRelease,
      );
      if (config.id.trim().isEmpty) continue;
      // A malformed ID must never be normalized into the same secure-storage
      // key as a valid record, and duplicate canonical IDs are ambiguous.
      if (!seenIds.add(config.id)) continue;
      final requiresCredential = searchProviderRequiresCredential(
        config.provider,
        isRelease: isRelease,
      );
      final keylessRequiredProvider = requiresCredential &&
          (!config.hasCredential || config.credentialId.isEmpty);
      final normalizedConfig = config.copyWith(
        credentialRequired: config.credentialRequired || requiresCredential,
        requiresAttention: config.requiresAttention || keylessRequiredProvider,
      );
      final releaseSafeConfig = isRelease &&
              normalizedConfig.credentialId ==
                  SearchCredentialRepository.developmentHiveCredentialId
          ? normalizedConfig.copyWith(
              credentialId: '',
              hasCredential: false,
              clearDevelopmentLegacyApiKey: true,
            )
          : normalizedConfig;
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

  SearchRuntimeSettings get runtimeSettings =>
      SearchRuntimeSettings.fromMap(box.get(runtimeSettingsKey));

  Future<void> saveRuntimeSettings(SearchRuntimeSettings settings) =>
      _runSerialized(() => box.put(runtimeSettingsKey, settings.toMap()));

  Future<void> clearRuntimeSettings() =>
      _runSerialized(() => box.delete(runtimeSettingsKey));

  Future<void> setRequiresAttention(String id, bool value) => _runSerialized(
        () async {
          final current = configs;
          if (!current.any((config) => config.id == id)) return;
          await _writeConfigs(
            current
                .map(
                  (config) => config.id == id
                      ? config.copyWith(requiresAttention: value)
                      : config,
                )
                .toList(growable: false),
          );
        },
      );

  /// Serializes every metadata mutation, including the read-modify-write
  /// snapshot. The gate is shared with data-lifecycle operations, so a clear
  /// cannot plan against one config list and delete against another.
  Future<T> _runSerialized<T>(Future<T> Function() operation) {
    return DatabaseMutationGate.forBox(box).run(operation);
  }

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

  Future<bool> _restoreSettings(_SearchSettingsSnapshot snapshot) async {
    var restored = true;
    try {
      if (snapshot.hadConfigs) {
        await box.put(configsKey, snapshot.configs);
      } else {
        await box.delete(configsKey);
      }
    } catch (_) {
      restored = false;
    }
    try {
      if (snapshot.hadDefaultProvider) {
        await box.put(defaultProviderKey, snapshot.defaultProvider);
      } else {
        await box.delete(defaultProviderKey);
      }
    } catch (_) {
      restored = false;
    }
    return restored;
  }

  bool _hasUnknownCredentialBinding(SearchProviderConfig config) =>
      config.invalidCredentialBinding ||
      (config.hasCredential && config.credentialId.isEmpty) ||
      (config.credentialId.isNotEmpty &&
          config.credentialId != credentials.credentialIdFor(config.id) &&
          config.credentialId !=
              SearchCredentialRepository.developmentHiveCredentialId);

  _CredentialRepairState _readCredentialRepairState() {
    final raw = box.get(credentialRepairKey);
    if (raw == null) return const _CredentialRepairState();
    if (raw is! Map) {
      // Keep the raw value untouched and expose only a safe diagnostic.
      return const _CredentialRepairState(malformed: true);
    }
    final repairs = <String, dynamic>{};
    final visibleIds = <String>[];
    var malformed = false;
    for (final entry in raw.entries) {
      if (entry.key is String && (entry.key as String).isNotEmpty) {
        visibleIds.add(entry.key as String);
      } else {
        malformed = true;
      }
      if (entry.key is! String || entry.value is! Map) {
        malformed = true;
        continue;
      }
      final repair = <String, dynamic>{};
      for (final item in (entry.value as Map).entries) {
        if (item.key is! String) {
          malformed = true;
          continue;
        }
        repair[item.key as String] = item.value;
      }
      repairs[entry.key as String] = repair;
    }
    return _CredentialRepairState(
      repairs: repairs,
      malformed: malformed,
      visibleIds: visibleIds,
    );
  }

  Map<String, dynamic> _pendingCredentialRepairs() =>
      _readCredentialRepairState().repairs;

  bool get hasMalformedCredentialRepairState =>
      _readCredentialRepairState().malformed;

  void _ensureRepairStateWritable(_CredentialRepairState state) {
    if (state.malformed) {
      throw StateError('search credential repair state is malformed');
    }
  }

  Map<String, dynamic>? _pendingCredentialRepair(String configId) {
    final raw = _pendingCredentialRepairs()[configId];
    if (raw is! Map) return null;
    return {
      for (final entry in raw.entries)
        if (entry.key is String) entry.key as String: entry.value,
    };
  }

  /// Stable, non-secret identifiers for repair operations that survived a
  /// metadata rollback or restore without their provider config.
  List<String> get pendingCredentialRepairIds {
    final ids = _readCredentialRepairState().visibleIds.toList();
    return List.unmodifiable(ids..sort());
  }

  Future<void> _markCredentialRepair({
    required String configId,
    required String credentialId,
    String operation = 'delete',
    String phase = 'cleanup',
  }) async {
    if (!credentials.canDeleteBinding(credentialId)) {
      throw StateError('search credential binding is not repairable');
    }
    final state = _readCredentialRepairState();
    _ensureRepairStateWritable(state);
    final previous = state.repairs[configId];
    if (previous is Map &&
        previous['operation']?.toString() == 'credential_recovery' &&
        operation != 'credential_recovery') {
      // Recovery is a terminal safety state until the bound key has been
      // removed successfully. A later transaction must never downgrade it to
      // a normal rotation or cleanup intent.
      throw StateError('search credential recovery is still pending');
    }
    final repairs = Map<String, dynamic>.from(state.repairs);
    repairs[configId] = {
      'configId': configId,
      'credentialId': credentialId,
      'operation': operation,
      'phase': phase,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
    };
    await box.put(credentialRepairKey, repairs);
  }

  Future<void> _clearCredentialRepair(String configId) async {
    final state = _readCredentialRepairState();
    _ensureRepairStateWritable(state);
    final repairs = Map<String, dynamic>.from(state.repairs);
    if (!repairs.containsKey(configId)) return;
    repairs.remove(configId);
    if (repairs.isEmpty) {
      await box.delete(credentialRepairKey);
    } else {
      await box.put(credentialRepairKey, repairs);
    }
  }

  /// Converts persisted config maps to backup metadata without reading a
  /// plaintext legacy key. Only allowlisted fields are copied.
  static List<Map<String, dynamic>> backupValue(Object? raw) {
    return SearchProviderConfigBackupCodec.backupValue(raw);
  }

  /// Restored configs are deliberately unbound, even if a backup was
  /// produced by a development build containing a fallback marker.
  static List<Map<String, dynamic>> restoreValue(Object? raw) {
    return SearchProviderConfigBackupCodec.restoreValue(raw);
  }

  /// Normalizes records already present on the device before a merge restore
  /// writes the whole list back. Secure credential bindings are retained, but
  /// release builds never copy a legacy Hive plaintext field.
  static List<Map<String, dynamic>> normalizeExistingValue(
    Object? raw, {
    bool? isRelease,
  }) {
    return SearchProviderConfigBackupCodec.normalizeExistingValue(
      raw,
      isRelease: isRelease,
    );
  }
}

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import 'package:chat_group/core/database/database_mutation_gate.dart';
import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/storage/credential_repository.dart';
import '../security/search_credential_validator.dart';
import 'search_credential_repository.dart';

/// Metadata for the one native search credential used by the application.
///
/// The key itself is always held by [SearchCredentialRepository]. The app
/// settings box stores only this marker (and, on the macOS debug fallback,
/// the explicitly allowed development value), so backup/export code can omit
/// this key entirely without losing the runtime binding contract.
class ZhipuNativeSearchCredentialStore {
  static const settingsKey = 'zhipu_native_search_credential_v1';
  static const credentialConfigId = 'zhipu-native-search';

  final Box<dynamic> box;
  final SearchCredentialRepository credentials;
  final bool isRelease;
  final bool allowDevelopmentFallback;

  ZhipuNativeSearchCredentialStore({
    Box<dynamic>? box,
    DatabaseService? db,
    SearchCredentialRepository? credentials,
    bool? isRelease,
    bool? allowDevelopmentFallback,
  })  : assert(box != null || db != null),
        box = box ?? db!.appSettingsBox,
        credentials = credentials ?? SearchCredentialRepository(),
        isRelease = isRelease ?? kReleaseMode,
        allowDevelopmentFallback = allowDevelopmentFallback ??
            ((isRelease ?? kReleaseMode) == false &&
                !kIsWeb &&
                defaultTargetPlatform == TargetPlatform.macOS);

  String get secureCredentialId =>
      credentials.credentialIdFor(credentialConfigId);

  /// Reads metadata only. This is intentionally synchronous so route
  /// construction never needs to read a secret or perform platform I/O.
  bool get hasConfiguredCredential {
    final metadata = _metadata;
    if (metadata == null || metadata['hasCredential'] != true) return false;
    final id = metadata['credentialId']?.toString() ?? '';
    if (id == SearchCredentialRepository.developmentHiveCredentialId) {
      return !isRelease &&
          allowDevelopmentFallback &&
          metadata['legacyApiKey'] is String &&
          (metadata['legacyApiKey'] as String).isNotEmpty;
    }
    return id == secureCredentialId;
  }

  /// Monotonic-enough metadata used to rebuild an idle room after rotation.
  String get credentialRevision =>
      _metadata?['credentialRevision']?.toString() ?? '';

  Future<String?> resolve() async {
    final metadata = _metadata;
    if (metadata == null || metadata['hasCredential'] != true) return null;
    final id = metadata['credentialId']?.toString() ?? '';
    if (id == SearchCredentialRepository.developmentHiveCredentialId) {
      if (isRelease || !allowDevelopmentFallback) return null;
      final fallback = metadata['legacyApiKey'];
      return fallback is String && fallback.isNotEmpty ? fallback : null;
    }
    if (id != secureCredentialId) return null;
    final result = await credentials.read(credentialConfigId);
    return result.isAvailable ? result.value : null;
  }

  Future<ZhipuNativeSearchCredentialState> state() async {
    final metadata = _metadata;
    if (!hasConfiguredCredential) {
      return const ZhipuNativeSearchCredentialState();
    }
    // A secure marker can outlive a failed Keychain read; report that state
    // explicitly so the settings page does not imply a usable credential.
    final value = await resolve();
    return ZhipuNativeSearchCredentialState(
      hasCredential: value != null,
      credentialRevision: metadata?['credentialRevision']?.toString() ?? '',
    );
  }

  Future<ZhipuNativeSearchCredentialWriteResult> save(String secret) {
    return DatabaseMutationGate.forBox(box).run(() async {
      final normalized = secret.trim();
      final validation = SearchCredentialValidator.validate(normalized);
      if (normalized.isEmpty || validation != null) {
        return ZhipuNativeSearchCredentialWriteResult.invalid(
          validation ?? '请输入智谱 AI API Key',
        );
      }

      final secureResult = await credentials.save(
        credentialConfigId,
        normalized,
      );
      if (!secureResult.isSuccess) {
        if (!secureResult.canUseDevelopmentFallback ||
            !allowDevelopmentFallback ||
            isRelease) {
          return ZhipuNativeSearchCredentialWriteResult.failed(
            secureResult.failure ?? CredentialFailure.systemError,
            requiresRecovery: secureResult.requiresRecovery,
          );
        }
        await box.put(settingsKey, {
          'credentialId':
              SearchCredentialRepository.developmentHiveCredentialId,
          'hasCredential': true,
          'credentialRevision': _nextRevision,
          'legacyApiKey': normalized,
        });
        return const ZhipuNativeSearchCredentialWriteResult.success(
          usedDevelopmentFallback: true,
        );
      }

      try {
        await box.put(settingsKey, {
          'credentialId': secureCredentialId,
          'hasCredential': true,
          'credentialRevision': _nextRevision,
        });
      } catch (_) {
        // Do not leave an untracked secure key if the metadata write fails.
        final cleanup = await credentials.delete(credentialConfigId);
        return ZhipuNativeSearchCredentialWriteResult.failed(
          CredentialFailure.systemError,
          requiresRecovery: !cleanup.isSuccess,
        );
      }
      return const ZhipuNativeSearchCredentialWriteResult.success();
    });
  }

  Future<ZhipuNativeSearchCredentialWriteResult> clear() {
    return DatabaseMutationGate.forBox(box).run(() async {
      final metadata = _metadata;
      final id = metadata?['credentialId']?.toString() ?? '';
      if (id.isEmpty) {
        return const ZhipuNativeSearchCredentialWriteResult.success();
      }
      if (id == SearchCredentialRepository.developmentHiveCredentialId) {
        await box.delete(settingsKey);
        return const ZhipuNativeSearchCredentialWriteResult.success();
      }
      if (id != secureCredentialId) {
        return const ZhipuNativeSearchCredentialWriteResult.failed(
          CredentialFailure.systemError,
        );
      }
      final result = await credentials.delete(credentialConfigId);
      if (!result.isSuccess) {
        return ZhipuNativeSearchCredentialWriteResult.failed(
          result.failure ?? CredentialFailure.systemError,
        );
      }
      await box.delete(settingsKey);
      return const ZhipuNativeSearchCredentialWriteResult.success();
    });
  }

  Map<dynamic, dynamic>? get _metadata {
    final raw = box.get(settingsKey);
    return raw is Map ? raw : null;
  }

  String get _nextRevision {
    final now = DateTime.now().toUtc().microsecondsSinceEpoch.toString();
    final previous = credentialRevision;
    return now.compareTo(previous) > 0 ? now : '$now-1';
  }
}

class ZhipuNativeSearchCredentialState {
  final bool hasCredential;
  final String credentialRevision;

  const ZhipuNativeSearchCredentialState({
    this.hasCredential = false,
    this.credentialRevision = '',
  });
}

class ZhipuNativeSearchCredentialWriteResult {
  final CredentialFailure? failure;
  final String? message;
  final bool usedDevelopmentFallback;
  final bool requiresRecovery;

  const ZhipuNativeSearchCredentialWriteResult.success({
    this.usedDevelopmentFallback = false,
  })  : failure = null,
        message = null,
        requiresRecovery = false;

  const ZhipuNativeSearchCredentialWriteResult.invalid(this.message)
      : failure = CredentialFailure.systemError,
        usedDevelopmentFallback = false,
        requiresRecovery = false;

  const ZhipuNativeSearchCredentialWriteResult.failed(
    this.failure, {
    this.requiresRecovery = false,
  })  : message = null,
        usedDevelopmentFallback = false;

  bool get isSuccess => failure == null;
}

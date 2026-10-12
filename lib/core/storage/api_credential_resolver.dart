import 'package:flutter/foundation.dart';

import '../models/api_config.dart';
import 'credential_repository.dart';

/// Resolves a configuration secret immediately before an API request.
///
/// 凭据真源始终为安全存储（[CredentialRepository]）。旧 Hive 字段只供迁移，
/// 本 resolver 不读取它，避免迁移失败或删除配置后静默复活旧密钥。
abstract interface class ApiCredentialResolver {
  Future<String?> resolve(ApiConfig config);
}

class SecureApiCredentialResolver implements ApiCredentialResolver {
  final CredentialRepository _credentials;

  SecureApiCredentialResolver([CredentialRepository? credentials])
      : _credentials = credentials ?? CredentialRepository();

  @override
  Future<String?> resolve(ApiConfig config) async {
    if (!config.hasCredential) return null;
    if (config.credentialId ==
        CredentialRepository.developmentHiveCredentialId) {
      // 非 release 下安全写入失败时留下的开发回退（见 DatabaseService.saveApiConfig）。
      // Release 里必须先有安全凭据才允许绑定，所以这条分支刻意关掉。
      // macOS 本身已不再使用钥匙串（凭据直接落本地 Hive 库），走的是下面的常规路径。
      return !kReleaseMode &&
              (config.legacyApiKeyForMigration?.isNotEmpty ?? false)
          ? (config.legacyApiKeyForMigration ?? '')
          : null;
    }
    if (config.credentialId != _credentials.credentialIdFor(config.id)) {
      return null;
    }
    final result = await _credentials.read(config.id);
    return result.isAvailable ? result.value : null;
  }
}

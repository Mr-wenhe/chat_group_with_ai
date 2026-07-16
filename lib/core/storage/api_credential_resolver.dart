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
    if (!config.hasCredential || config.credentialId.isEmpty) return null;
    final result = await _credentials.read(config.id);
    return result.isAvailable ? result.value : null;
  }
}

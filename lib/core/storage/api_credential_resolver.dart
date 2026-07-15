import '../models/api_config.dart';
import 'credential_repository.dart';

/// Resolves a configuration secret immediately before an API request.
///
/// 原生平台：凭据真源为安全存储（[CredentialRepository]），[legacyApiKey] 仅为
/// 过渡期明文副本，本 resolver 不直接读取，避免静默复活已删密钥。
///
/// 无安全存储平台（Web 等）：[ApiConfig.credentialId] 为空即代表此情况，凭据
/// 真源只能是 Hive 明文 [ApiConfig.legacyApiKey]，此时回退读取该字段。
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
    // 无安全存储平台（credentialId 为空）：回退到 Hive 明文 legacyApiKey。
    if (config.credentialId.isEmpty) return config.legacyApiKey;
    final result = await _credentials.read(config.id);
    return result.isAvailable ? result.value : null;
  }
}

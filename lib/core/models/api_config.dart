import 'package:hive/hive.dart';
import 'package:uuid/uuid.dart';
import 'api_provider.dart';
import '../storage/credential_repository.dart';

part 'api_config.g.dart';

@HiveType(typeId: 4)
class ApiConfig extends HiveObject {
  @HiveField(0)
  String id;

  @HiveField(1, defaultValue: '')
  String name;

  @HiveField(2, defaultValue: '')
  String provider;

  @HiveField(3, defaultValue: '')
  String modelName;

  @HiveField(4, defaultValue: '')
  String? _legacyApiKey;

  @HiveField(5, defaultValue: '')
  String customBaseUrl;

  @HiveField(6)
  final DateTime createdAt;

  @HiveField(7, defaultValue: '')
  String credentialId;

  @HiveField(8, defaultValue: false)
  bool hasCredential;

  /// Runtime-only compatibility accessor. It never exposes the legacy Hive key.
  String get apiKey => CredentialRepository.cached(id) ?? '';

  /// Returns true when a non-empty credential is configured.
  bool get hasApiKey =>
      (CredentialRepository.cached(id) ?? _legacyApiKey ?? '').isNotEmpty;

  /// Explicit migration/development fallback boundary for the legacy Hive key.
  String? get legacyApiKeyForMigration => _legacyApiKey;
  void setLegacyApiKeyForMigration(String? value) => _legacyApiKey = value;

  set apiKey(String value) {
    // 写入 Hive 字段以兼容迁移流程；运行时通过 CredentialRepository
    // 读取时优先走安全存储。
    _legacyApiKey = value;
  }

  ApiConfig({
    String? id,
    required this.name,
    required this.provider,
    String? modelName,
    String apiKey = '',
    this.customBaseUrl = '',
    DateTime? createdAt,
    this.credentialId = '',
    this.hasCredential = false,
  })  : id = id ?? const Uuid().v4(),
        _legacyApiKey = apiKey,
        modelName = modelName ?? ApiProvider.defaultModels[provider] ?? '',
        createdAt = createdAt ?? DateTime.now();
}

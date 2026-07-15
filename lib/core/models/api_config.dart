import 'package:hive/hive.dart';
import 'package:uuid/uuid.dart';
import 'api_provider.dart';
import '../storage/credential_repository.dart';

part 'api_config.g.dart';

@HiveType(typeId: 4)
class ApiConfig extends HiveObject {
  @HiveField(0)
  String id;

  @HiveField(1)
  String name;

  @HiveField(2)
  String provider;

  @HiveField(3)
  String modelName;

  @HiveField(4)
  String legacyApiKey;

  @HiveField(5)
  String customBaseUrl;

  @HiveField(6)
  final DateTime createdAt;

  @HiveField(7, defaultValue: '')
  String credentialId;

  @HiveField(8, defaultValue: false)
  bool hasCredential;

  /// Runtime-only: Hive serializes [legacyApiKey], never the cached secret.
  String get apiKey => CredentialRepository.cached(id) ?? legacyApiKey;
  set apiKey(String value) => legacyApiKey = value;

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
        legacyApiKey = apiKey,
        modelName = modelName ?? ApiProvider.defaultModels[provider] ?? '',
        createdAt = createdAt ?? DateTime.now();
}

import 'package:hive/hive.dart';
import 'package:uuid/uuid.dart';
import 'api_provider.dart';

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
  String apiKey;

  @HiveField(5)
  String customBaseUrl;

  @HiveField(6)
  final DateTime createdAt;

  ApiConfig({
    String? id,
    required this.name,
    required this.provider,
    String? modelName,
    required this.apiKey,
    this.customBaseUrl = '',
    DateTime? createdAt,
  })  : id = id ?? const Uuid().v4(),
        modelName = modelName ?? ApiProvider.defaultModels[provider] ?? '',
        createdAt = createdAt ?? DateTime.now();
}

import 'package:hive/hive.dart';
import 'package:uuid/uuid.dart';
import 'api_provider.dart';

part 'ai_character.g.dart';

@HiveType(typeId: 0)
class AICharacter extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  String name;

  @HiveField(2)
  String avatar;

  @HiveField(3)
  int age;

  @HiveField(4)
  String role;

  @HiveField(5)
  List<String> personalityTags;

  @HiveField(6)
  String systemPrompt;

  @HiveField(7)
  String memorySummary;

  @HiveField(8)
  String apiKey;

  @HiveField(9)
  String apiProvider;

  @HiveField(10)
  String modelName;

  @HiveField(11)
  String customBaseUrl;

  @HiveField(12)
  int hourlyReplyLimit;

  @HiveField(13)
  int hourlyReplyCount;

  @HiveField(14)
  DateTime? lastReplyTimestamp;

  @HiveField(15)
  bool isActive;

  @HiveField(16)
  final DateTime createdAt;

  @HiveField(17)
  String apiConfigId;

  AICharacter({
    String? id,
    required this.name,
    required this.avatar,
    required this.age,
    required this.role,
    required this.personalityTags,
    required this.systemPrompt,
    this.memorySummary = '',
    required this.apiKey,
    required this.apiProvider,
    String? modelName,
    this.customBaseUrl = '',
    this.hourlyReplyLimit = 5,
    this.hourlyReplyCount = 0,
    this.lastReplyTimestamp,
    this.isActive = true,
    DateTime? createdAt,
    this.apiConfigId = '',
  })  : id = id ?? const Uuid().v4(),
        modelName = modelName ?? ApiProvider.defaultModels[apiProvider] ?? '',
        createdAt = createdAt ?? DateTime.now();
}

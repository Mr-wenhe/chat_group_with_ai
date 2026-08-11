import 'package:hive/hive.dart';
import 'package:uuid/uuid.dart';
import 'api_provider.dart';
import 'tool_permission.dart';

part 'ai_character.g.dart';

@HiveType(typeId: 24)
enum CharacterGender {
  @HiveField(0)
  male,

  @HiveField(1)
  female;

  String get label => this == CharacterGender.male ? '男' : '女';
}

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

  @HiveField(18, defaultValue: true)
  bool agenticEnabled;

  @HiveField(19, defaultValue: [])
  List<String> skillIds;

  @HiveField(20, defaultValue: [
    ToolPermission.skillCreate,
    ToolPermission.skillDownload,
  ])
  List<ToolPermission> toolPermissions;

  /// 创建后不可变。缺少该字段的旧记录兼容读取为女；迁移是否完成必须
  /// 由版本化迁移状态判断，不能由这个兼容默认值推断。
  @HiveField(21, defaultValue: CharacterGender.female)
  CharacterGender gender;

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
    this.hourlyReplyLimit = 60,
    this.hourlyReplyCount = 0,
    this.lastReplyTimestamp,
    this.isActive = true,
    DateTime? createdAt,
    String? apiConfigId,
    this.agenticEnabled = true,
    List<String>? skillIds,
    List<ToolPermission>? toolPermissions,
    this.gender = CharacterGender.female,
  })  : id = id ?? const Uuid().v4(),
        modelName = modelName ?? ApiProvider.defaultModels[apiProvider] ?? '',
        createdAt = createdAt ?? DateTime.now(),
        apiConfigId = apiConfigId ?? '',
        skillIds = skillIds ?? const [],
        toolPermissions = toolPermissions ??
            const [ToolPermission.skillCreate, ToolPermission.skillDownload];

  String get promptIdentity => '$name，$age岁，性别${gender.label}，身份是$role';

  String get rolePlaySystemPrompt {
    final prompt = systemPrompt.trim();
    final genderRule = '角色性别为${gender.label}，请保持称谓和角色表现与该设定一致。';
    return prompt.isEmpty ? genderRule : '$genderRule\n$prompt';
  }
}

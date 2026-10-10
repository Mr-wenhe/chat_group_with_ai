import 'package:hive/hive.dart';

import 'ai_character.dart';

part 'user_profile.g.dart';

/// 全局唯一真人信息卡。
///
/// 固定使用单例 key `me`。首次启动时从第一个非空的 ChatGroup.ownerName
/// 迁移 displayName；若没有则使用"我"。
@HiveType(typeId: 22)
class UserProfile extends HiveObject {
  @HiveField(0)
  final String id;

  /// 用户显示名称；所有群聊 ownerName 的最终替代值。
  @HiveField(1)
  String displayName;

  /// AI 对用户的默认称呼。
  @HiveField(2)
  String preferredAddress;

  @HiveField(3)
  String avatar;

  /// 可为空，不强制二元性别。
  @HiveField(4)
  String pronouns;

  @HiveField(5)
  int? age;

  @HiveField(6)
  String bio;

  @HiveField(7)
  List<String> personality;

  @HiveField(8)
  List<String> interests;

  @HiveField(9)
  List<String> importantBackground;

  @HiveField(10)
  DateTime updatedAt;

  @HiveField(11)
  final DateTime createdAt;

  /// IP 提示词用的性别。null = 未选择，提示词里整段省略性别。
  ///
  /// 与 [pronouns] 并存不冲突：称谓/代词喂聊天上下文（可写「TA」这类非二元
  /// 表达），本字段只喂生图提示词，是二选一的下拉。
  @HiveField(12)
  CharacterGender? gender;

  /// IP 形象的受管相对路径；'' = 未生成。
  @HiveField(13, defaultValue: '')
  String ipImageRelPath;

  /// 「设为头像」开关。生成 ≠ 设为头像，与 AI 角色语义一致。
  @HiveField(14, defaultValue: false)
  bool avatarFromIpImage;

  /// 画风 preset id（`image_style_presets.dart`）；'' = auto。
  @HiveField(15, defaultValue: '')
  String ipImageStyle;

  /// 外观改写所用的聊天 `ApiConfig` id；'' = 不改写，直接走本地模板。
  ///
  /// 备份会带本字段（与 `AICharacter.apiConfigId` 同构），还原后需重新绑定 Key；
  /// 凭据本身绝不入档。
  @HiveField(16, defaultValue: '')
  String apiConfigId;

  UserProfile({
    String? id,
    required this.displayName,
    required this.preferredAddress,
    required this.avatar,
    this.pronouns = '',
    this.age,
    required this.bio,
    List<String>? personality,
    List<String>? interests,
    List<String>? importantBackground,
    DateTime? updatedAt,
    DateTime? createdAt,
    this.gender,
    this.ipImageRelPath = '',
    this.avatarFromIpImage = false,
    this.ipImageStyle = '',
    this.apiConfigId = '',
  })  : id = id ?? 'me',
        personality = personality ?? const [],
        interests = interests ?? const [],
        importantBackground = importantBackground ?? const [],
        updatedAt = updatedAt ?? DateTime.now(),
        createdAt = createdAt ?? DateTime.now();
}

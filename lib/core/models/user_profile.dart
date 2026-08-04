import 'package:hive/hive.dart';

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
  })  : id = id ?? 'me',
        personality = personality ?? const [],
        interests = interests ?? const [],
        importantBackground = importantBackground ?? const [],
        updatedAt = updatedAt ?? DateTime.now(),
        createdAt = createdAt ?? DateTime.now();
}

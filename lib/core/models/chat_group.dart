import 'package:hive/hive.dart';
import 'package:uuid/uuid.dart';

part 'chat_group.g.dart';

@HiveType(typeId: 1)
class ChatGroup extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  String name;

  @HiveField(2)
  String theme;

  @HiveField(3)
  String description;

  @HiveField(4)
  List<String> aiCharacterIds;

  @HiveField(5)
  final DateTime createdAt;

  /// 群主名称（本应用为唯一的真人用户，默认「我」）。
  @HiveField(6)
  String ownerName;

  /// 群公告，会展示在群聊顶部并注入 AI 上下文。
  @HiveField(7)
  String announcement;

  /// 自动聊天基础间隔（秒）。页面会在此基础上增加少量随机抖动。
  @HiveField(8)
  int replyIntervalSeconds;

  /// 共享群的主人用户标识；`null` 表示这个群从未共享过，只存在于本机。
  ///
  /// 这是整个多人群聊功能的**向后兼容开关**：老数据读出来是 null，
  /// 一切行为与加入实时功能之前完全一致。非 null 时才需要连服务端。
  @HiveField(9)
  String? hostUserId;

  /// 服务端分配的房间标识，客人加入后与本机群记录绑定。未共享时为 null。
  @HiveField(10)
  String? roomId;

  /// 邀请码（短、可口头转述）。主人重复打开邀请面板时复用同一个码，
  /// 不会每次生成新群。未共享时为 null。
  @HiveField(11)
  String? inviteCode;

  /// 已见到的真人成员：用户标识 -> 昵称。仅用于成员列表展示，
  /// 消息自己的昵称快照在 `Message.senderName` 上。
  @HiveField(12, defaultValue: <String, String>{})
  Map<String, String> humanMemberNames;

  ChatGroup({
    String? id,
    required this.name,
    required this.theme,
    this.description = '',
    required this.aiCharacterIds,
    DateTime? createdAt,
    String? ownerName,
    String? announcement,
    int? replyIntervalSeconds,
    this.hostUserId,
    this.roomId,
    this.inviteCode,
    Map<String, String>? humanMemberNames,
  })  : id = id ?? const Uuid().v4(),
        createdAt = createdAt ?? DateTime.now(),
        ownerName = ownerName ?? '我',
        announcement = announcement ?? '',
        replyIntervalSeconds = replyIntervalSeconds ?? 12,
        humanMemberNames = humanMemberNames ?? <String, String>{};

  /// 是否已经共享到实时服务，即需要建立长连接、可能有真人成员进出。
  bool get isShared => hostUserId != null && roomId != null;

  /// [userId] 是否是这个群的主人。未共享的群恒为 true（创建者即主人）。
  bool isHost(String userId) => hostUserId == null || hostUserId == userId;
}

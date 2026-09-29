import 'package:hive/hive.dart';
import 'package:uuid/uuid.dart';

import 'package:chat_group/core/models/media_attachment.dart';

part 'message.g.dart';

@HiveType(typeId: 2)
class Message extends HiveObject {
  /// 本机用户自己发出的消息。历史数据全部使用这个值，不要改动。
  static const String senderTypeUser = 'user';

  /// AI 角色消息，`senderId` 为 `AICharacter.id`。
  static const String senderTypeAi = 'ai';

  /// 系统提示（入群、清空会话等），不是任何人的发言。
  static const String senderTypeSystem = 'system';

  /// 多人实时群聊中「别人」发出的消息，`senderId` 为对方的用户标识。
  ///
  /// 刻意不复用 [senderTypeUser]：界面上 `senderType == senderTypeUser`
  /// 一律等价于「我发的、右对齐、不显示头像和昵称」，把客人塞进这个分支
  /// 会让他们看起来像本人。新增类型则让所有既有判断保持原意。
  static const String senderTypeMember = 'member';

  @HiveField(0)
  final String id;

  @HiveField(1)
  final String groupId;

  @HiveField(2)
  final String senderId;

  @HiveField(3)
  final String senderType;

  @HiveField(4)
  String content;

  @HiveField(5)
  final DateTime timestamp;

  @HiveField(6)
  String? replyToMessageId;

  @HiveField(7)
  bool isMention;

  @HiveField(8)
  List<String> mentionedAiIds;

  /// 媒体附件（图片 / 视频）。旧消息为 null，渲染时按空处理，保持向后兼容。
  @HiveField(9)
  List<MediaAttachment>? media;

  /// 消息发送时在场可见的 AI 角色 ID 快照；旧消息为空列表。
  @HiveField(10, defaultValue: <String>[])
  List<String> visibleToCharacterIds;

  /// Normalized, secret-free web-search evidence used by this AI reply.
  /// Keeping it on the message preserves source panels and regeneration after
  /// an app restart without introducing a separate lifecycle relation.
  @HiveField(11)
  Map<dynamic, dynamic>? webSearchSnapshot;

  /// 远端真人消息的发送者昵称快照，仅 [senderTypeMember] 消息会有值。
  ///
  /// 刻意冗余存一份而不是每次渲染去群里查成员表：成员退群或改名之后，
  /// 历史消息仍应显示"当时是谁说的"。旧消息与 AI/本人消息为 null。
  @HiveField(12)
  String? senderName;

  /// 服务端为该条远端消息分配的顺序号，仅 [senderTypeMember] 消息会有值。
  ///
  /// 断线重连后服务端会重放最近的若干条消息，靠这个号可以精确跳过已经存过的，
  /// 而不是拿「同一人 + 同一时刻 + 同一内容」去猜。同时它也是排查消息顺序
  /// 问题时唯一可信的依据——本机时钟与服务端时钟并不可比。
  @HiveField(13)
  int? remoteSeq;

  Message({
    String? id,
    required this.groupId,
    required this.senderId,
    required this.senderType,
    required this.content,
    DateTime? timestamp,
    this.replyToMessageId,
    this.isMention = false,
    List<String>? mentionedAiIds,
    this.media,
    List<String>? visibleToCharacterIds,
    this.webSearchSnapshot,
    this.senderName,
    this.remoteSeq,
  })  : id = id ?? const Uuid().v4(),
        timestamp = timestamp ?? DateTime.now(),
        mentionedAiIds = mentionedAiIds ?? const [],
        visibleToCharacterIds = visibleToCharacterIds ?? const [];
}

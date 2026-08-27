import 'package:hive/hive.dart';
import 'package:uuid/uuid.dart';

import 'package:chat_group/core/models/media_attachment.dart';

part 'message.g.dart';

@HiveType(typeId: 2)
class Message extends HiveObject {
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
  })  : id = id ?? const Uuid().v4(),
        timestamp = timestamp ?? DateTime.now(),
        mentionedAiIds = mentionedAiIds ?? const [],
        visibleToCharacterIds = visibleToCharacterIds ?? const [];
}

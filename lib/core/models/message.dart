import 'package:hive/hive.dart';
import 'package:uuid/uuid.dart';

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
  })  : id = id ?? const Uuid().v4(),
        timestamp = timestamp ?? DateTime.now(),
        mentionedAiIds = mentionedAiIds ?? [];
}

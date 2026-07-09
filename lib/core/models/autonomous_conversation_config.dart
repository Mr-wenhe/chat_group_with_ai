import 'package:hive/hive.dart';
import 'package:uuid/uuid.dart';

part 'autonomous_conversation_config.g.dart';

@HiveType(typeId: 16)
class AutonomousConversationConfig extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final String conversationId;

  @HiveField(2)
  final String conversationType;

  @HiveField(3)
  bool enabled;

  @HiveField(4)
  String workDirPath;

  @HiveField(5)
  String? authorizedProjectPath;

  @HiveField(6)
  bool sourceWriteAuthorized;

  @HiveField(7)
  DateTime? authorizedAt;

  @HiveField(8)
  DateTime updatedAt;

  AutonomousConversationConfig({
    String? id,
    required this.conversationId,
    required this.conversationType,
    this.enabled = false,
    this.workDirPath = '',
    this.authorizedProjectPath,
    this.sourceWriteAuthorized = false,
    this.authorizedAt,
    DateTime? updatedAt,
  })  : id = id ?? const Uuid().v4(),
        updatedAt = updatedAt ?? DateTime.now();
}

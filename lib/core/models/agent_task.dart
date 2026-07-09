import 'package:hive/hive.dart';
import 'package:uuid/uuid.dart';

import 'tool_permission.dart';

part 'agent_task.g.dart';

@HiveType(typeId: 12)
enum AgentTaskStatus {
  @HiveField(0)
  planning,
  @HiveField(1)
  waitingForApproval,
  @HiveField(2)
  runningTool,
  @HiveField(3)
  completed,
  @HiveField(4)
  failed,
  @HiveField(5)
  cancelled,
}

@HiveType(typeId: 13)
class AgentTask extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final String groupId;

  @HiveField(2)
  final String characterId;

  @HiveField(3)
  String userRequest;

  @HiveField(4)
  AgentTaskStatus status;

  @HiveField(5)
  List<ToolPermission> requestedPermissions;

  @HiveField(6)
  String plan;

  @HiveField(7)
  String resultSummary;

  @HiveField(8)
  DateTime createdAt;

  AgentTask({
    String? id,
    required this.groupId,
    required this.characterId,
    required this.userRequest,
    this.status = AgentTaskStatus.planning,
    List<ToolPermission>? requestedPermissions,
    this.plan = '',
    this.resultSummary = '',
    DateTime? createdAt,
  })  : id = id ?? const Uuid().v4(),
        requestedPermissions = requestedPermissions ?? const [],
        createdAt = createdAt ?? DateTime.now();
}

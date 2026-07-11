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
  @HiveField(6)
  partiallyCompleted,
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

  @HiveField(9, defaultValue: 0)
  int currentStep;

  @HiveField(10, defaultValue: <String>[])
  List<String> completedOperations;

  @HiveField(11, defaultValue: '')
  String pendingToolRequestJson;

  @HiveField(12)
  DateTime? updatedAt;

  @HiveField(13, defaultValue: '')
  String lastError;

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
    this.currentStep = 0,
    List<String>? completedOperations,
    this.pendingToolRequestJson = '',
    DateTime? updatedAt,
    this.lastError = '',
  })  : id = id ?? const Uuid().v4(),
        requestedPermissions = requestedPermissions ?? const [],
        completedOperations = completedOperations ?? [],
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  bool get canResume =>
      status != AgentTaskStatus.completed &&
      status != AgentTaskStatus.cancelled;

  /// 每个工具步骤完成后刷新可恢复检查点。
  void markProgress({
    required int step,
    required List<String> operations,
    String pendingToolJson = '',
  }) {
    currentStep = step;
    completedOperations = List<String>.from(operations);
    pendingToolRequestJson = pendingToolJson;
    status = pendingToolJson.isEmpty
        ? AgentTaskStatus.runningTool
        : AgentTaskStatus.waitingForApproval;
    updatedAt = DateTime.now();
  }

  void markPartiallyCompleted(String error) {
    status = AgentTaskStatus.partiallyCompleted;
    lastError = error;
    resultSummary = '已完成 ${completedOperations.length} 个工具操作；$error';
    updatedAt = DateTime.now();
  }
}

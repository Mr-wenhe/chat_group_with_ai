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
  @HiveField(7)
  queued,
  @HiveField(8)
  paused,
  @HiveField(9)
  interrupted,
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

  @HiveField(14, defaultValue: false)
  final bool workModeTask;

  @HiveField(15, defaultValue: <String>[])
  List<String> queuedUserRequests;

  @HiveField(16, defaultValue: '')
  String contextSummary;

  @HiveField(17, defaultValue: <String>[])
  List<String> assignedCharacterIds;

  @HiveField(18)
  DateTime? startedAt;

  @HiveField(19, defaultValue: 0)
  int actionCount;

  @HiveField(20, defaultValue: false)
  bool softLimitReached;

  @HiveField(21, defaultValue: false)
  bool resumeRequired;

  @HiveField(22, defaultValue: '')
  String executionStateJson;

  @HiveField(23, defaultValue: <String>[])
  List<String> lastArtifactPaths;

  @HiveField(24, defaultValue: defaultActionLimit)
  int actionLimit;

  @HiveField(25, defaultValue: defaultSoftTimeLimitMinutes)
  int softTimeLimitMinutes;

  /// Whether one or more public progress events failed to persist.
  ///
  /// A task may complete successfully while its diagnostic timeline is
  /// incomplete, so this is separate from [lastError].
  @HiveField(26, defaultValue: false)
  bool eventLogIncomplete;

  static const int defaultActionLimit = 100;
  static const int defaultSoftTimeLimitMinutes = 60;
  static const Duration defaultSoftTimeLimit =
      Duration(minutes: defaultSoftTimeLimitMinutes);

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
    this.workModeTask = false,
    List<String>? queuedUserRequests,
    this.contextSummary = '',
    List<String>? assignedCharacterIds,
    this.startedAt,
    this.actionCount = 0,
    this.softLimitReached = false,
    this.resumeRequired = false,
    this.executionStateJson = '',
    List<String>? lastArtifactPaths,
    this.actionLimit = defaultActionLimit,
    this.softTimeLimitMinutes = defaultSoftTimeLimitMinutes,
    this.eventLogIncomplete = false,
  })  : id = id ?? const Uuid().v4(),
        requestedPermissions = List<ToolPermission>.from(
          requestedPermissions ?? const [],
        ),
        completedOperations =
            List<String>.from(completedOperations ?? const []),
        queuedUserRequests = List<String>.from(queuedUserRequests ?? const []),
        assignedCharacterIds = List<String>.from(
          assignedCharacterIds ?? const [],
        ),
        lastArtifactPaths = List<String>.from(lastArtifactPaths ?? const []),
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  /// Legacy agentic recovery still treats failed/partially-completed tasks as
  /// resumable. Work-mode tasks use terminal checkpoints only through the
  /// explicit follow-up coordinator path.
  bool get canResume => workModeTask
      ? canResumeInWorkMode
      : status != AgentTaskStatus.completed &&
          status != AgentTaskStatus.cancelled;

  bool get canResumeInWorkMode => workModeTask && !isTerminal;

  bool get requiresUserResume =>
      status == AgentTaskStatus.interrupted && resumeRequired;

  Duration get softTimeLimit => Duration(minutes: softTimeLimitMinutes);

  /// 非持久化派生：任务是否已处于任一终态（成功 / 失败 / 取消 / 部分完成）。
  /// 仅供 UI 生命周期判断，不写入 Hive。
  bool get isTerminal =>
      status == AgentTaskStatus.completed ||
      status == AgentTaskStatus.failed ||
      status == AgentTaskStatus.cancelled ||
      status == AgentTaskStatus.partiallyCompleted;

  /// 每个工具步骤完成后刷新可恢复检查点。
  void markProgress({
    required int step,
    required List<String> operations,
    String pendingToolJson = '',
  }) {
    // A late progress callback must not resurrect a completed/failed/cancelled
    // task after the coordinator has already committed its terminal state.
    if (isTerminal) return;
    currentStep = step;
    completedOperations = List<String>.from(operations);
    pendingToolRequestJson = pendingToolJson;
    startedAt ??= DateTime.now();
    resumeRequired = false;
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

  void markInterrupted({required String reason}) {
    if (isTerminal || status == AgentTaskStatus.paused) return;
    status = AgentTaskStatus.interrupted;
    resumeRequired = true;
    lastError = reason;
    updatedAt = DateTime.now();
  }
}

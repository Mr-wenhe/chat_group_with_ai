import 'package:hive/hive.dart';
import 'package:uuid/uuid.dart';

part 'autonomous_task.g.dart';

@HiveType(typeId: 14)
enum AutonomousTaskStatus {
  @HiveField(0)
  planning,
  @HiveField(1)
  running,
  @HiveField(2)
  verifying,
  @HiveField(3)
  fixing,
  @HiveField(4)
  productReview,
  @HiveField(5)
  completed,
  @HiveField(6)
  blocked,
  @HiveField(7)
  paused,
  @HiveField(8)
  cancelled,
  @HiveField(9)
  failed,
}

@HiveType(typeId: 15)
enum AutonomousTaskPhase {
  @HiveField(0)
  intake,
  @HiveField(1)
  requirements,
  @HiveField(2)
  execution,
  @HiveField(3)
  verification,
  @HiveField(4)
  bugfix,
  @HiveField(5)
  productConfirmation,
  @HiveField(6)
  handoff,
}

@HiveType(typeId: 17)
class AutonomousTask extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final String conversationId;

  @HiveField(2)
  final String conversationType;

  @HiveField(3)
  String userGoal;

  @HiveField(4)
  String taskType;

  @HiveField(5)
  String workDirPath;

  @HiveField(6)
  String? targetProjectPath;

  @HiveField(7)
  AutonomousTaskStatus status;

  @HiveField(8)
  AutonomousTaskPhase phase;

  @HiveField(9)
  List<String> participantCharacterIds;

  @HiveField(10)
  String? plannerCharacterId;

  @HiveField(11)
  String? executorCharacterId;

  @HiveField(12)
  String? verifierCharacterId;

  @HiveField(13)
  int repeatedBlockCount;

  @HiveField(14)
  String lastBlockSignature;

  @HiveField(15)
  String resultSummary;

  @HiveField(16)
  DateTime createdAt;

  @HiveField(17)
  DateTime updatedAt;

  AutonomousTask({
    String? id,
    required this.conversationId,
    required this.conversationType,
    required this.userGoal,
    required this.taskType,
    required this.workDirPath,
    this.targetProjectPath,
    this.status = AutonomousTaskStatus.planning,
    this.phase = AutonomousTaskPhase.intake,
    List<String>? participantCharacterIds,
    this.plannerCharacterId,
    this.executorCharacterId,
    this.verifierCharacterId,
    this.repeatedBlockCount = 0,
    this.lastBlockSignature = '',
    this.resultSummary = '',
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : id = id ?? const Uuid().v4(),
        participantCharacterIds = participantCharacterIds ?? const [],
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();
}

@HiveType(typeId: 18)
class AutonomousTaskStep extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final String taskId;

  @HiveField(2)
  final String characterId;

  @HiveField(3)
  String role;

  @HiveField(4)
  String action;

  @HiveField(5)
  String toolName;

  @HiveField(6)
  String inputSummary;

  @HiveField(7)
  String outputSummary;

  @HiveField(8)
  List<String> changedPaths;

  @HiveField(9)
  List<String> artifactPaths;

  @HiveField(10)
  int? commandExitCode;

  @HiveField(11)
  DateTime createdAt;

  AutonomousTaskStep({
    String? id,
    required this.taskId,
    required this.characterId,
    required this.role,
    required this.action,
    this.toolName = '',
    this.inputSummary = '',
    this.outputSummary = '',
    List<String>? changedPaths,
    List<String>? artifactPaths,
    this.commandExitCode,
    DateTime? createdAt,
  })  : id = id ?? const Uuid().v4(),
        changedPaths = changedPaths ?? const [],
        artifactPaths = artifactPaths ?? const [],
        createdAt = createdAt ?? DateTime.now();
}

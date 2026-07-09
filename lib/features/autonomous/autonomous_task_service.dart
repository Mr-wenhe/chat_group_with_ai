import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/autonomous_task.dart';
import 'package:chat_group/features/autonomous/autonomous_conversation_config_service.dart';
import 'package:chat_group/features/autonomous/autonomous_directory_service.dart';
import 'package:chat_group/features/autonomous/autonomous_role_resolver.dart';
import 'package:chat_group/features/autonomous/autonomous_trigger_detector.dart';
import 'package:chat_group/features/autonomous/task_journal_service.dart';

class AutonomousTaskService {
  final DatabaseService db;
  final AutonomousDirectoryService directories;
  final AutonomousConversationConfigService configs;
  final AutonomousRoleResolver roles;
  final TaskJournalService journal;
  final AutonomousTriggerDetector detector;

  AutonomousTaskService({
    required this.db,
    AutonomousDirectoryService? directories,
    AutonomousConversationConfigService? configs,
    AutonomousRoleResolver? roles,
    TaskJournalService? journal,
    AutonomousTriggerDetector? detector,
  })  : directories = directories ?? const AutonomousDirectoryService(),
        configs = configs ??
            AutonomousConversationConfigService(
              db: db,
              directories: directories ?? const AutonomousDirectoryService(),
            ),
        roles = roles ?? const AutonomousRoleResolver(),
        journal = journal ?? const TaskJournalService(),
        detector = detector ?? const AutonomousTriggerDetector();

  Future<AutonomousTask?> maybeCreateTask({
    required String conversationId,
    required bool isDirectChat,
    required String userGoal,
    required List<AICharacter> characters,
  }) async {
    final config = await configs.loadOrCreate(
      conversationId: conversationId,
      isDirectChat: isDirectChat,
    );
    final trigger = detector.detect(
      text: userGoal,
      autonomyEnabled: config.enabled,
      sourceAuthorized: config.sourceWriteAuthorized,
    );
    if (!trigger.shouldStart || characters.isEmpty) return null;

    await configs.grantFullPermissions(characters.map((c) => c.id));
    final assignment = roles.resolve(characters);
    final root = await db.aiProcessingDir;
    final task = AutonomousTask(
      conversationId: conversationId,
      conversationType: isDirectChat ? 'direct' : 'group',
      userGoal: userGoal,
      taskType: trigger.taskType,
      workDirPath: '',
      targetProjectPath: trigger.likelyNeedsProject
          ? config.authorizedProjectPath
          : config.workDirPath,
      participantCharacterIds: characters.map((c) => c.id).toList(),
      plannerCharacterId: assignment.planner.id,
      executorCharacterId: assignment.executor.id,
      verifierCharacterId: assignment.verifier.id,
    );
    final taskDir = await directories.taskDir(
      root: root,
      conversationId: conversationId,
      isDirectChat: isDirectChat,
      taskId: task.id,
    );
    task.workDirPath = taskDir.path;
    task
      ..status = AutonomousTaskStatus.running
      ..phase = AutonomousTaskPhase.requirements
      ..updatedAt = DateTime.now();
    await db.autonomousTaskBox.put(task.id, task);
    await journal.initializeTask(taskDir, task);
    return task;
  }

  Future<AutonomousTaskStep> recordStep({
    required AutonomousTask task,
    required String characterId,
    required String role,
    required String action,
    String toolName = '',
    String inputSummary = '',
    String outputSummary = '',
    List<String> changedPaths = const [],
    List<String> artifactPaths = const [],
    int? commandExitCode,
  }) async {
    final step = AutonomousTaskStep(
      taskId: task.id,
      characterId: characterId,
      role: role,
      action: action,
      toolName: toolName,
      inputSummary: inputSummary,
      outputSummary: outputSummary,
      changedPaths: changedPaths,
      artifactPaths: artifactPaths,
      commandExitCode: commandExitCode,
    );
    await db.autonomousTaskStepBox.put(step.id, step);
    await journal.appendStep(taskDir: Directory(task.workDirPath), step: step);
    return step;
  }

  Future<void> completeTask(AutonomousTask task, String summary) async {
    task
      ..status = AutonomousTaskStatus.completed
      ..phase = AutonomousTaskPhase.handoff
      ..resultSummary = summary
      ..updatedAt = DateTime.now();
    await db.autonomousTaskBox.put(task.id, task);
    final dir = Directory(task.workDirPath);
    await journal.writeAcceptanceReport(
      taskDir: dir,
      content: '# Acceptance Report\n\n$summary\n',
    );
    await journal.writeHandoff(dir, task, nextAction: 'completed');
  }

  Future<List<AutonomousTask>> recoverableTasks() async {
    return db.autonomousTaskBox.values
        .where((task) => const {
              AutonomousTaskStatus.running,
              AutonomousTaskStatus.verifying,
              AutonomousTaskStatus.fixing,
              AutonomousTaskStatus.productReview,
              AutonomousTaskStatus.paused,
              AutonomousTaskStatus.blocked,
            }.contains(task.status))
        .toList();
  }
}

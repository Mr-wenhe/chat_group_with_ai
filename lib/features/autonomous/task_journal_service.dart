import 'dart:convert';
import 'dart:io';

import 'package:chat_group/core/models/autonomous_task.dart';

class TaskJournalService {
  const TaskJournalService();

  Future<void> initializeTask(Directory taskDir, AutonomousTask task) async {
    await _writeIfMissing(
      File('${taskDir.path}/task_journal.md'),
      '# Autonomous Task Journal\n\n'
      '- Task: ${task.userGoal}\n'
      '- Type: ${task.taskType}\n'
      '- Created: ${task.createdAt.toIso8601String()}\n\n',
    );
    await _writeIfMissing(
      File('${taskDir.path}/requirements.md'),
      '# Requirements\n\n${task.userGoal}\n',
    );
    await _writeIfMissing(
      File('${taskDir.path}/acceptance_report.md'),
      '# Acceptance Report\n\nPending.\n',
    );
    await writeHandoff(taskDir, task, nextAction: 'requirements');
  }

  Future<void> appendStep({
    required Directory taskDir,
    required AutonomousTaskStep step,
  }) async {
    final file = File('${taskDir.path}/task_journal.md');
    await file.writeAsString(
      '\n## ${step.createdAt.toIso8601String()} ${step.role}\n\n'
      '- Action: ${step.action}\n'
      '- Tool: ${step.toolName.isEmpty ? 'none' : step.toolName}\n'
      '- Input: ${step.inputSummary}\n'
      '- Output: ${step.outputSummary}\n'
      '- Changed: ${step.changedPaths.join(', ')}\n'
      '- Artifacts: ${step.artifactPaths.join(', ')}\n',
      mode: FileMode.append,
    );
  }

  Future<void> writeAcceptanceReport({
    required Directory taskDir,
    required String content,
  }) async {
    await File('${taskDir.path}/acceptance_report.md').writeAsString(content);
  }

  Future<void> writeHandoff(
    Directory taskDir,
    AutonomousTask task, {
    required String nextAction,
  }) async {
    final file = File('${taskDir.path}/handoff.json');
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert({
      'taskId': task.id,
      'conversationId': task.conversationId,
      'status': task.status.name,
      'phase': task.phase.name,
      'targetProjectPath': task.targetProjectPath,
      'workDirPath': task.workDirPath,
      'nextAction': nextAction,
      'updatedAt': task.updatedAt.toIso8601String(),
    }));
  }

  Future<void> _writeIfMissing(File file, String content) async {
    if (await file.exists()) return;
    await file.create(recursive: true);
    await file.writeAsString(content);
  }
}

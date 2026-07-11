import 'package:chat_group/core/models/agent_task.dart';
import 'package:flutter/material.dart';

/// 展示持久化 Agentic 任务的恢复检查点。
class AgentTaskRecoveryDialog extends StatelessWidget {
  final AgentTask task;
  final VoidCallback onContinue;
  final VoidCallback onAbandon;

  const AgentTaskRecoveryDialog({
    super.key,
    required this.task,
    required this.onContinue,
    required this.onAbandon,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('发现未完成的 Agentic 任务'),
      content: Text(
        '${task.userRequest}\n\n已完成 ${task.completedOperations.length} 个工具步骤。'
        '${task.lastError.isEmpty ? '' : '\n上次中断原因：${task.lastError}'}',
      ),
      actions: [
        TextButton(
          onPressed: onAbandon,
          child: const Text('放弃'),
        ),
        FilledButton(
          onPressed: onContinue,
          child: const Text('继续执行'),
        ),
      ],
    );
  }
}

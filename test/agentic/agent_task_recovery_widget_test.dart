import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/agentic/agent_task_recovery_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('恢复弹窗展示持久化进度并允许继续执行', (tester) async {
    var continued = false;
    final task = AgentTask(
      groupId: 'dm:character-1',
      characterId: 'character-1',
      userRequest: '继续生成 HTML 页面',
      completedOperations: const [
        '{"tool":"workspace.read"}',
        '{"tool":"workspace.patch"}',
      ],
      lastError: '连接中断',
    )..markPartiallyCompleted('连接中断');

    await tester.pumpWidget(MaterialApp(
      home: AgentTaskRecoveryDialog(
        task: task,
        onContinue: () => continued = true,
        onAbandon: () {},
      ),
    ));

    expect(find.text('发现未完成的 Agentic 任务'), findsOneWidget);
    expect(find.textContaining('已完成 2 个工具步骤'), findsOneWidget);
    expect(find.textContaining('上次中断原因：连接中断'), findsOneWidget);
    await tester.tap(find.text('继续执行'));

    expect(continued, isTrue);
  });

  testWidgets('恢复弹窗允许放弃群聊任务', (tester) async {
    var abandoned = false;
    final task = AgentTask(
      groupId: 'group-1',
      characterId: 'character-1',
      userRequest: '生成群聊报告',
    );

    await tester.pumpWidget(MaterialApp(
      home: AgentTaskRecoveryDialog(
        task: task,
        onContinue: () {},
        onAbandon: () => abandoned = true,
      ),
    ));
    await tester.tap(find.text('放弃'));

    expect(abandoned, isTrue);
  });
}

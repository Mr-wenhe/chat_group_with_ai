import 'dart:convert';

import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/agentic/tool_request.dart';
import 'package:chat_group/features/work_mode/presentation/work_task_generic_approval_dialog.dart';
import 'package:chat_group/features/work_mode/work_task_approval_plan.dart';
import 'package:chat_group/features/work_mode/work_approval_decision.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ToolRequest _skillRequest() => const ToolRequest(
      tool: AgentToolName.skillDownload,
      reason: '安装匹配的技能模板',
      args: <String, dynamic>{'templateId': 'frontend.interactive-artifact'},
    );

void main() {
  test('skill mutations require the explicit no-undo decision', () {
    final task = AgentTask(
      id: 'skill-policy',
      groupId: 'group',
      characterId: 'worker',
      userRequest: '安装技能',
      workModeTask: true,
    )..pendingToolRequestJson = jsonEncode(<String, dynamic>{
        'tool': 'skill.download',
        'args': <String, dynamic>{
          'templateId': 'frontend.interactive-artifact'
        },
      });

    expect(taskRequiresNoUndoApproval(task, null), isTrue);
  });

  testWidgets('global skill approval buttons return their real decisions',
      (tester) async {
    WorkChangeApprovalDecision? decision;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              key: const Key('open-generic-approval'),
              onPressed: () async {
                decision = await WorkTaskGenericApprovalDialog.show(
                  context,
                  pending: _skillRequest(),
                  requiresNoUndo: true,
                );
              },
              child: const Text('打开审批'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('open-generic-approval')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(
        find.byKey(const Key('work-generic-approval-dialog')), findsOneWidget);
    expect(find.text('安装应用内技能模板'), findsOneWidget);
    expect(find.text('应用内技能配置没有文件快照，执行后无法通过任务撤销恢复。'), findsOneWidget);
    expect(find.text('仍然执行（无法撤销）'), findsOneWidget);
    expect(find.text('允许本次操作'), findsNothing);

    await tester.tap(find.byKey(const Key('work-generic-approve')));
    await tester.pump();
    expect(decision, WorkChangeApprovalDecision.approvedWithoutUndo);

    await tester.tap(find.byKey(const Key('open-generic-approval')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.byKey(const Key('work-generic-reject')));
    await tester.pump();

    expect(decision, WorkChangeApprovalDecision.rejected);
  });
}

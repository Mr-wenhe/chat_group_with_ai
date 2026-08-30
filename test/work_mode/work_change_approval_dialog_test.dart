import 'package:chat_group/features/work_mode/presentation/work_change_approval_dialog.dart';
import 'package:chat_group/features/work_mode/work_change_plan.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

WorkChangePlan _plan() => WorkChangePlan(
      taskId: 'task-09',
      actionType: WorkChangeActionType.modify,
      exactPaths: const ['/workspace/report.md', '/workspace/summary.md'],
      knownAffectedDirectories: const ['/workspace'],
      estimatedBytes: 512,
      snapshotAvailable: true,
      reversible: true,
      riskReason: '需要更新周报并保留一键撤销能力。',
    );

Future<void> _openDialog(
  WidgetTester tester, {
  required WorkChangePlan plan,
  VoidCallback? onApproved,
  VoidCallback? onRejected,
}) async {
  await tester.tap(find.byKey(const Key('open-work-change-approval')));
  await tester.pumpAndSettle();
  expect(find.byType(WorkChangeApprovalDialog), findsOneWidget);
  // Keep callback wiring in the test host so a close/reject can be proven to
  // have no executor side effect.
  expect(plan.taskId, 'task-09');
  expect(onApproved, isNotNull);
  expect(onRejected, isNotNull);
}

WorkChangePlan _commandPlan() => WorkChangePlan(
      taskId: 'task-09',
      actionType: WorkChangeActionType.command,
      exactPaths: const ['/workspace/build.log'],
      knownAffectedDirectories: const ['/workspace/build'],
      estimatedBytes: 2048,
      snapshotAvailable: false,
      reversible: false,
      command: const WorkChangeCommand(
        executable: 'flutter',
        arguments: ['build', 'macos'],
        workingDirectory: '/workspace',
        knownFiles: ['/workspace/build.log'],
        possibleDirectories: ['/workspace/build'],
        impactUncertain: true,
      ),
      riskReason: '构建可能改写 build 目录。',
    );

void main() {
  testWidgets('lists exact absolute paths and the approval reason',
      (tester) async {
    var executed = 0;
    var rejected = 0;
    WorkChangeApprovalDecision? decision;

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: ElevatedButton(
            key: const Key('open-work-change-approval'),
            onPressed: () async {
              decision = await WorkChangeApprovalDialog.show(
                context,
                plan: _plan(),
                onApproved: () => executed++,
                onRejected: () => rejected++,
              );
            },
            child: const Text('打开审批'),
          ),
        ),
      ),
    ));

    await _openDialog(
      tester,
      plan: _plan(),
      onApproved: () => executed++,
      onRejected: () => rejected++,
    );

    expect(find.text('为什么需要这次变更'), findsOneWidget);
    expect(find.text('需要更新周报并保留一键撤销能力。'), findsOneWidget);
    expect(find.text('将做什么：修改文件'), findsOneWidget);
    expect(find.text('/workspace/report.md'), findsOneWidget);
    expect(find.text('/workspace/summary.md'), findsOneWidget);
    expect(find.text('影响目录：/workspace'), findsOneWidget);
    expect(find.textContaining('预计 512 字节'), findsOneWidget);
    expect(find.textContaining('可创建快照'), findsOneWidget);
    expect(find.textContaining('可撤销'), findsOneWidget);
    expect(find.text('标准工具调用'), findsNothing);

    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(find.byType(WorkChangeApprovalDialog), findsNothing);
    expect(executed, 0);
    expect(rejected, 0);
    expect(decision, isNull);
  });

  testWidgets('rejecting a plan never calls the fake executor', (tester) async {
    var executed = 0;
    var rejected = 0;

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: ElevatedButton(
            key: const Key('open-work-change-approval'),
            onPressed: () => WorkChangeApprovalDialog.show(
              context,
              plan: _plan(),
              onApproved: () => executed++,
              onRejected: () => rejected++,
            ),
            child: const Text('打开审批'),
          ),
        ),
      ),
    ));

    await _openDialog(
      tester,
      plan: _plan(),
      onApproved: () => executed++,
      onRejected: () => rejected++,
    );
    await tester.tap(find.text('拒绝并暂停'));
    await tester.pumpAndSettle();

    expect(executed, 0);
    expect(rejected, 1);
  });

  testWidgets('approving is the only decision that calls the fake executor',
      (tester) async {
    var executed = 0;

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: ElevatedButton(
            key: const Key('open-work-change-approval'),
            onPressed: () => WorkChangeApprovalDialog.show(
              context,
              plan: _plan(),
              onApproved: () => executed++,
            ),
            child: const Text('打开审批'),
          ),
        ),
      ),
    ));

    await tester.tap(find.byKey(const Key('open-work-change-approval')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('允许本次范围'));
    await tester.pumpAndSettle();

    expect(executed, 1);
  });

  testWidgets('shows structured command impact instead of opaque tool wording',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: ElevatedButton(
            key: const Key('open-work-change-approval'),
            onPressed: () => WorkChangeApprovalDialog.show(
              context,
              plan: _commandPlan(),
            ),
            child: const Text('打开审批'),
          ),
        ),
      ),
    ));

    await tester.tap(find.byKey(const Key('open-work-change-approval')));
    await tester.pumpAndSettle();

    expect(find.text('可执行文件：flutter'), findsOneWidget);
    expect(find.text('参数：build macos'), findsOneWidget);
    expect(find.text('工作目录：/workspace'), findsOneWidget);
    expect(find.text('已知文件：/workspace/build.log'), findsOneWidget);
    expect(find.text('可能目录：/workspace/build'), findsOneWidget);
    expect(find.text('影响范围不确定：是，必须再次确认。'), findsOneWidget);
    expect(find.text('标准工具调用'), findsNothing);

    await tester.tap(find.text('拒绝并暂停'));
    await tester.pumpAndSettle();
  });

  testWidgets('requires a separate no-undo confirmation for unsafe changes',
      (tester) async {
    var ordinaryApproval = 0;
    var noUndoApproval = 0;
    WorkChangeApprovalDecision? decision;

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: ElevatedButton(
            key: const Key('open-work-change-approval'),
            onPressed: () async {
              decision = await WorkChangeApprovalDialog.show(
                context,
                plan: _commandPlan(),
                onApproved: () => ordinaryApproval++,
                onApprovedWithoutUndo: () => noUndoApproval++,
              );
            },
            child: const Text('打开审批'),
          ),
        ),
      ),
    ));

    await tester.tap(find.byKey(const Key('open-work-change-approval')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('work-change-approve-without-undo')),
        findsOneWidget);
    expect(find.text('允许本次范围'), findsNothing);
    expect(find.textContaining('单独确认'), findsOneWidget);

    await tester.tap(find.byKey(const Key('work-change-approve-without-undo')));
    await tester.pumpAndSettle();
    expect(ordinaryApproval, 0);
    expect(noUndoApproval, 1);
    expect(decision, WorkChangeApprovalDecision.approvedWithoutUndo);
  });
}

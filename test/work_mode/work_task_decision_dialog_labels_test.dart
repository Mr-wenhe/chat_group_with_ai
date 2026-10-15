import 'package:chat_group/core/text/entity_labels.dart';
import 'package:chat_group/features/work_mode/presentation/work_task_decision_dialog.dart';
import 'package:chat_group/features/work_mode/work_task_decision.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _iterationId = '11111111-1111-4111-8111-111111111111';
const _memberId = 'e1f80660-581f-488b-b8e6-94cb63192ec1';

WorkTaskDecision _decision() => const WorkTaskDecision(
      taskId: 'task-1',
      id: 'decision-1',
      revision: 1,
      status: 'pending',
      reason: '候选需要你确认',
      // 生产路径里 evidence 由应用自己 jsonEncode，每次都带 iterationId。
      evidence: '{"iterationId":"$_iterationId","memberId":"$_memberId"}',
      impact: '待答事项未解决前不开始制作。',
      answer: '',
      missingCondition: '',
      kind: 'member',
      targetId: '',
      promptedReminder: '',
      options: <Map<String, String>>[],
      remainderReady: false,
    );

Future<void> _pumpDialog(WidgetTester tester, EntityLabels labels) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: WorkTaskDecisionDialog(
        decisions: <WorkTaskDecision>[_decision()],
        entityLabels: labels,
        onReply: (decision, answer, {choiceId, disposition = 'answer'}) async =>
            true,
      ),
    ),
  ));
  await tester.pump();
}

void main() {
  testWidgets('决策弹窗的「依据」不再裸露候选与成员 id', (tester) async {
    await _pumpDialog(
      tester,
      EntityLabels.fixed(const {
        _iterationId: '第 1 轮候选',
        _memberId: '产品经理',
      }),
    );

    expect(find.textContaining(_iterationId), findsNothing);
    expect(find.textContaining(_memberId), findsNothing);
    expect(find.textContaining('第 1 轮候选'), findsWidgets);
    expect(find.textContaining('产品经理'), findsWidgets);
  });

  testWidgets('不给标签时「依据」原样显示（不崩）', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: WorkTaskDecisionDialog(
          decisions: <WorkTaskDecision>[_decision()],
          onReply:
              (decision, answer, {choiceId, disposition = 'answer'}) async =>
                  true,
        ),
      ),
    ));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.textContaining(_iterationId), findsOneWidget);
  });
}

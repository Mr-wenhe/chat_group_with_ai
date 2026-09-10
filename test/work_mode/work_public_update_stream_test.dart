import 'dart:async';

import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/work_mode/presentation/work_task_panel.dart';
import 'package:chat_group/features/work_mode/work_public_update_stream.dart';
import 'package:chat_group/features/work_mode/work_task_event.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

AgentTask _task() {
  return AgentTask(
    id: 'stream-task',
    groupId: 'group-one',
    characterId: 'developer',
    userRequest: '检查项目',
    startedAt: DateTime.utc(2026, 9, 10, 10),
    actionLimit: 8,
    workModeTask: true,
  );
}

void main() {
  group('WorkPublicUpdateStream', () {
    test('decodes only the public_update field across SSE chunks', () {
      final stream = WorkPublicUpdateStream();

      expect(stream.add('{"action":"workspace.read","public_'), isEmpty);
      expect(stream.add('update":"正在检查 '), '正在检查 ');
      expect(stream.add(r'\u9879\u76ee"}'), '正在检查 项目');

      final nestedFieldStream = WorkPublicUpdateStream();
      expect(
        nestedFieldStream.add(
          '{"action":"tool","tool":{"arguments":{"public_update":"不应展示"}},'
          '"public_update":"应展示',
        ),
        '应展示',
      );
      expect(
        WorkPublicUpdateStream.sanitize(
          '已检查 https://example.com/result 和 /Users/alice/project.md',
        ),
        '已检查 [外部地址] 和 [本地路径]',
      );
    });

    test('does not expose private reasoning in a live draft', () {
      expect(
        WorkPublicUpdateStream.sanitize('思维链：先分析，再决定下一步'),
        isEmpty,
      );
      expect(
        WorkPublicUpdateStream.sanitize('<think>private</think>公开进度'),
        isEmpty,
      );
    });
  });

  testWidgets(
      'renders a live public update and replaces it with the next event',
      (tester) async {
    final events = StreamController<WorkTaskEvent>.broadcast();
    addTearDown(events.close);
    final task = _task();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorkTaskPanel(
            tasks: <AgentTask>[task],
            eventStreamFor: (_) => events.stream,
            onSelectTask: (_) {},
            onStop: (_) {},
            onContinue: (_) {},
            onOpenConversation: (_) {},
            onCollapse: () {},
            onClose: () {},
          ),
        ),
      ),
    );

    events.add(
      WorkTaskEvent(
        taskId: task.id,
        sequence: 1,
        timestamp: DateTime.utc(2026, 9, 10, 10, 1),
        kind: WorkTaskEventKind.modelOutput,
        title: 'AI 正在输出公开进度',
        detail: '正在检查项目',
        safeMetadata: const <String, Object?>{
          'stream': 'public_update',
          'publicDraft': '正在检查项目',
        },
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('work-task-live-output')), findsOneWidget);
    expect(find.text('正在检查项目'), findsOneWidget);

    events.add(
      WorkTaskEvent(
        taskId: task.id,
        sequence: 2,
        timestamp: DateTime.utc(2026, 9, 10, 10, 1, 1),
        kind: WorkTaskEventKind.stepStarted,
        title: '正在读取项目文件',
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('work-task-live-output')), findsNothing);
    expect(find.text('正在读取项目文件'), findsOneWidget);
  });
}

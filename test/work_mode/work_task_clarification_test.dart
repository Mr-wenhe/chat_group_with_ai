import 'dart:convert';

import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/work_mode/work_follow_up_policy.dart';
import 'package:chat_group/features/work_mode/work_task_clarification.dart';
import 'package:flutter_test/flutter_test.dart';

AgentTask _task() => AgentTask(
      id: 'clarification-unit',
      groupId: 'group-clarification-unit',
      characterId: 'worker-id',
      userRequest: '请修改当前文件',
    );

void main() {
  test('options come back in the order the question lists them', () {
    final task = _task()
      ..executionStateJson = jsonEncode(<String, dynamic>{
        'followUpKind': 'clarification',
        'clarificationQuestion': '请明确要修改的文件路径（点击选项，或回复序号／文件名）？',
        'clarificationOptions': <Map<String, Object?>>[
          <String, Object?>{'index': 1, 'path': '/workspace/report.md'},
          <String, Object?>{'index': 2, 'path': '/workspace/summary.md'},
        ],
      });

    expect(
      WorkTaskClarification.options(task).map((option) => option.index),
      <int>[1, 2],
    );
    expect(
      WorkTaskClarification.options(task).map((option) => option.path),
      <String>['/workspace/report.md', '/workspace/summary.md'],
    );
  });

  test('a malformed option is dropped instead of rendered as a dead button', () {
    // 检查点是持久数据，可能来自旧版本或被写坏。少一个按钮用户还能手打文件名，
    // 而一个提交不出路径的按钮点了什么都不会发生。
    final task = _task()
      ..executionStateJson = jsonEncode(<String, dynamic>{
        'clarificationOptions': <Object?>[
          <String, Object?>{'index': 1, 'path': '/workspace/report.md'},
          <String, Object?>{'index': '2', 'path': '/workspace/summary.md'},
          <String, Object?>{'index': 3, 'path': '   '},
          <String, Object?>{'index': 4},
          'not-a-map',
        ],
      });

    expect(
      WorkTaskClarification.options(task).map((option) => option.path),
      <String>['/workspace/report.md'],
    );
  });

  test('a duplicate number is dropped instead of breaking the button row', () {
    // 按钮的 widget key 取自序号：两个一样的序号不是"多一个选择"，是整块面板
    // 在构建时报重复 key、一行按钮都画不出来。
    final task = _task()
      ..executionStateJson = jsonEncode(<String, dynamic>{
        'clarificationOptions': <Object?>[
          <String, Object?>{'index': 1, 'path': '/workspace/report.md'},
          <String, Object?>{'index': 1, 'path': '/workspace/summary.md'},
        ],
      });

    expect(
      WorkTaskClarification.options(task).map((option) => option.path),
      <String>['/workspace/report.md'],
    );
  });

  test('an answer nobody could act on is flagged for the user', () {
    final task = _task()
      ..status = AgentTaskStatus.paused
      ..resumeRequired = true
      ..executionStateJson = jsonEncode(<String, dynamic>{
        'followUpKind': 'clarification',
        'clarificationQuestion': '请明确要修改的文件路径（点击选项，或回复序号／文件名）？',
        'clarificationAnswerRejected': true,
      });

    expect(WorkTaskClarification.answerRejected(task), isTrue);
    // 没写过这个标记的检查点（含旧版本写下的）一律按"还没答过"读。
    expect(WorkTaskClarification.answerRejected(_task()), isFalse);
  });

  test('clearing the question drops its options with it', () {
    final task = _task()
      ..status = AgentTaskStatus.paused
      ..resumeRequired = true
      ..executionStateJson = jsonEncode(<String, dynamic>{
        'clarificationRequired': true,
        'clarificationQuestion': '请明确要修改的文件路径（点击选项，或回复序号／文件名）？',
        'clarificationOptions': <Map<String, Object?>>[
          <String, Object?>{'index': 1, 'path': '/workspace/report.md'},
        ],
      });
    expect(WorkTaskClarification.isAnswerable(task), isTrue);

    WorkTaskClarification.clear(task);

    // 选项是问题的一部分：问题被别的入口解答后，按钮不能留在检查点里等下一次
    // 无关的暂停把它们重新渲染出来。
    expect(WorkTaskClarification.options(task), isEmpty);
    expect(WorkTaskClarification.isAnswerable(task), isFalse);
  });

  test('options survive a round trip through the stored metadata', () {
    final json = const WorkFollowUpOption(index: 3, path: '/workspace/报告.docx')
        .toJson();

    expect(
      WorkFollowUpOption.listFromJson(<Object?>[json]).single.path,
      '/workspace/报告.docx',
    );
  });
}

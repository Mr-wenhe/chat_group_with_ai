import 'dart:convert';
import 'package:chat_group/features/work_mode/work_contract_change.dart';
import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/work_mode/work_discussion_state.dart';
import 'package:chat_group/features/work_mode/work_task_requirements_confirmation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('artifact path keys preserve POSIX case and unify Windows aliases', () {
    expect(workArtifactPathKey(r'C:\Work\draft.html'),
        workArtifactPathKey('c:/work/draft.html'));
    expect(workArtifactPathKey(r'\\server\share\draft.html'),
        workArtifactPathKey('//SERVER/share/draft.html'));
    expect(workArtifactPathKey('/work/Game.html'),
        isNot(workArtifactPathKey('/work/game.html')));
    expect(
        statesWorkContractChange(r'把 C:\work\output 改成 D:/new。',
            from: 'C:/work/output', to: r'D:\new', asFormat: false),
        isTrue);
    expect(
        statesWorkContractChange(r'把 C:\work\output 改成 D:\new。',
            from: 'C:/work/output', to: 'D:/new', asFormat: false),
        isTrue);
    expect(
        statesWorkContractChange(r'不要把 C:\work\output 改成 D:/new。',
            from: 'C:/work/output', to: r'D:\new', asFormat: false),
        isFalse);
  });

  test('Windows directory rename accepts drive, separators and UNC paths', () {
    expect(
        rewrittenWorkArtifactPath(
            r'把 C:\work\output 改成 D:\new。', r'C:\work\output\game\game.html'),
        r'D:\new\game\game.html');
    expect(
        rewrittenWorkArtifactPath(
            r'把 C:/work/output 改成 D:\new。', 'C:/work/output/game/game.html'),
        r'D:\new\game\game.html');
    expect(
        rewrittenWorkArtifactPath(r'把 C:\work\output 改成 \\server\share\new。',
            r'C:\work\output\game\game.html'),
        r'\\server\share\new\game\game.html');
    expect(
        rewrittenWorkArtifactPath(
            r'不要把 C:\work\output 改成 D:\new。', r'C:\work\output\game\game.html'),
        r'C:\work\output\game\game.html');
    expect(
        rewrittenWorkArtifactPath(
            r'把 c:\WORK\GAME.html 改名为new.html。', r'C:\work\game.html'),
        r'C:\work\new.html');
  });
  const original = '请在 /work/output 这个目录中创建一个飞行棋的目录，里面放着一份飞行棋的html';
  String? output(String supplement) {
    final task = AgentTask(
        id: 'rename',
        groupId: 'g',
        characterId: 'dev',
        userRequest: original,
        workModeTask: true);
    final shell = WorkDiscussionState.forNewTask(task);
    final next = shell.collaboration!.toJson()
      ..['scope'] = '$original；用户补充要求：$supplement'
      ..['requestRevision'] = 2;
    final raw = shell.toJson()
      ..['requestRevision'] = 2
      ..['collaboration'] = next;
    task.executionStateJson = jsonEncode({'discussionState': raw});
    return WorkTaskRequirementsConfirmation.requiredNestedHtmlOutputPath(task);
  }

  test('explicit rename replaces the original confirmed output pin', () {
    expect(output('把飞行棋.html改名为game2.html，保持内容不变。'),
        '/work/output/飞行棋/game2.html');
  });
  test('later supplemental details preserve an already authorized rename', () {
    expect(output('把飞行棋.html改名为game2.html；用户补充要求：按钮改为红色'),
        '/work/output/飞行棋/game2.html');
  });
  test('ordered renames and directory changes preserve the current output', () {
    expect(
        output(
            '把飞行棋.html改名为game2.html；把game2.html改名为game3.html；把 /work/output 改成 /work/new。'),
        '/work/new/飞行棋/game3.html');
  });
  for (final supplement in [
    '不要把飞行棋.html改名为game2.html',
    '先讨论把飞行棋.html改名为game2.html是否合适，不要实际改名',
    '可以参考game2.html，保持飞行棋.html文件名',
    '把超级飞行棋.html改名为game2.html',
    '把飞行棋.html改名为game2.html是不允许的'
  ]) {
    test('mentions or prohibited changes do not rewrite the pin: $supplement',
        () {
      expect(output(supplement), '/work/output/飞行棋/飞行棋.html');
    });
  }
}

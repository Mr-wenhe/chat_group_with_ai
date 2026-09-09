import 'dart:io';
import 'dart:convert';

import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/work_mode/work_context_builder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

void main() {
  const builder = WorkContextBuilder(maxCharacters: 900);

  test('persists only bounded task context and never tool body text', () {
    final snapshot = builder.build(
      conversationId: 'group-a',
      target: '完成报告',
      pendingFollowUps: const ['先改标题', '再检查链接'],
      completedSummaries: const ['已读取 report.md'],
      recentToolResults: const [
        {
          'tool': 'workspace.read',
          'path': '/workspace/report.md',
          'conversationId': 'dm:b',
          'content': 'PRIVATE FILE BODY MUST NOT BE PERSISTED',
        },
      ],
      approvalScope: const {
        'entries': [
          {
            'path': '/workspace',
            'actions': ['write']
          },
        ],
      },
      artifactPaths: const ['/workspace/report.md'],
      roleHandoff: const {'currentCharacterId': 'writer'},
      errors: const ['上一次校验失败'],
      nextStep: '重新读取并校验',
    );

    final encoded = snapshot.toJsonString();
    final decoded = jsonDecode(encoded) as Map<String, dynamic>;
    expect(decoded['conversationId'], 'group-a');
    expect(decoded['target'], '完成报告');
    expect(decoded['pendingFollowUps'], ['先改标题', '再检查链接']);
    expect(decoded['artifactPaths'], ['/workspace/report.md']);
    expect(encoded, isNot(contains('PRIVATE FILE BODY')));
    expect(encoded, isNot(contains('conversationHistory')));
    expect(encoded, isNot(contains('dm:b')));
  });

  test('drops alternate file-body keys from recent safe results', () {
    final encoded = builder.build(
      conversationId: 'group-a',
      target: '分析文件',
      recentToolResults: const [
        {
          'tool': 'workspace.read',
          'path': '/workspace/report.md',
          'text': 'FULL_FILE_TEXT',
          'data': 'FULL_DATA_BODY',
          'output': 'FULL_OUTPUT_BODY',
          'message': '读取完成',
        },
      ],
    ).toJsonString();
    expect(encoded, isNot(contains('FULL_FILE_TEXT')));
    expect(encoded, isNot(contains('FULL_DATA_BODY')));
    expect(encoded, isNot(contains('FULL_OUTPUT_BODY')));
    expect(encoded, contains('读取完成'));
  });

  test('does not persist traversal artifact paths', () {
    final snapshot = builder.build(
      conversationId: 'group-a',
      target: '校验路径',
      artifactPaths: const ['/workspace/report.md', '../private.txt'],
    );
    expect(snapshot.artifactPaths, ['/workspace/report.md']);
  });

  test('large or fenced file text is not stored as a completed summary', () {
    final body = '<html>${List.filled(1000, 'x').join()}</html>';
    final encoded = builder.build(
      conversationId: 'group-a',
      target: '生成报告',
      completedSummaries: [body, '已完成报告'],
    ).toJsonString();
    expect(encoded, isNot(contains(body)));
    expect(encoded, contains('已完成报告'));
    expect(encoded, contains('正文已省略'));
  });

  test('model compression failure falls back to deterministic clipping',
      () async {
    final longValue = List.filled(5000, 'x').join();
    final snapshot = builder.build(
      conversationId: 'dm:a',
      target: longValue,
      pendingFollowUps: [longValue, '第二条追问'],
      completedSummaries: [longValue],
      recentToolResults: [
        {
          'tool': 'workspace.read',
          'path': '/workspace/a.txt',
          'message': longValue,
        },
      ],
      approvalScope: const {
        'entries': [
          {
            'path': '/workspace',
            'actions': ['write']
          },
        ],
      },
      artifactPaths: const ['/workspace/a.txt'],
      errors: [longValue],
      nextStep: longValue,
    );

    final compressed = await builder.compress(
      snapshot,
      model: (_) async => throw StateError('compressor unavailable'),
    );

    expect(compressed.conversationId, 'dm:a');
    expect(compressed.target, isNotEmpty);
    expect(compressed.pendingFollowUps, ['第二条追问']);
    expect(compressed.artifactPaths, ['/workspace/a.txt']);
    expect(compressed.approvalScope, isNotNull);
    expect(compressed.toJsonString().length, lessThanOrEqualTo(900));
    expect(compressed.toJsonString(), isNot(contains(longValue)));
  });

  test('compression cannot omit resume-critical fields', () async {
    final source = builder.build(
      conversationId: 'group-a',
      target: '完成并校验',
      pendingFollowUps: const ['继续修订'],
      approvalScope: const {'entries': []},
      artifactPaths: const ['/workspace/report.md'],
      roleHandoff: const {'currentCharacterId': 'tester'},
      errors: const ['需要重试'],
      nextStep: '重新读取报告',
    );
    final compressed = await builder.compress(
      source,
      model: (_) async => WorkContextSnapshot(conversationId: 'group-a'),
    );

    expect(compressed.target, '完成并校验');
    expect(compressed.pendingFollowUps, ['继续修订']);
    expect(compressed.approvalScope, isNotNull);
    expect(compressed.artifactPaths, ['/workspace/report.md']);
    expect(compressed.roleHandoff, {'currentCharacterId': 'tester'});
    expect(compressed.errors, ['需要重试']);
    expect(compressed.nextStep, '重新读取报告');
  });

  test('compression cannot rewrite resume-critical fields', () async {
    final source = builder.build(
      conversationId: 'group-a',
      target: '原始目标',
      pendingFollowUps: const ['原始追问'],
      approvalScope: const {'entries': []},
      artifactPaths: const ['/workspace/report.md'],
      roleHandoff: const {'currentCharacterId': 'writer'},
      errors: const ['原始错误'],
      nextStep: '原始下一步',
    );
    final compressed = await builder.compress(
      source,
      model: (_) async => WorkContextSnapshot(
        conversationId: 'group-a',
        target: '不可信目标',
        pendingFollowUps: const ['不可信追问'],
        approvalScope: const {'entries': []},
        artifactPaths: const ['/workspace/other.md'],
        roleHandoff: const {'currentCharacterId': 'other'},
        errors: const ['不可信错误'],
        nextStep: '不可信下一步',
      ),
    );

    expect(compressed.target, '原始目标');
    expect(compressed.pendingFollowUps, ['原始追问']);
    expect(compressed.artifactPaths, ['/workspace/report.md']);
    expect(compressed.roleHandoff, {'currentCharacterId': 'writer'});
    expect(compressed.errors, ['原始错误']);
    expect(compressed.nextStep, '原始下一步');
  });

  test('compression cannot invent an approval scope or handoff', () async {
    final source = builder.build(
      conversationId: 'group-a',
      target: '仅分析',
    );
    final compressed = await builder.compress(
      source,
      model: (_) async => WorkContextSnapshot(
        conversationId: 'group-a',
        approvalScope: const {'entries': []},
        roleHandoff: const {'currentCharacterId': 'other'},
      ),
    );

    expect(compressed.approvalScope, isNull);
    expect(compressed.roleHandoff, isNull);
  });

  test('compact checkpoints evict the oldest artifact before the newest', () {
    const compact = WorkContextBuilder(maxCharacters: 520);
    final snapshot = compact.build(
      conversationId: 'group-artifacts',
      target: '交付项目',
      artifactPaths: [
        '/workspace/old/${List.filled(120, 'a').join()}.txt',
        '/workspace/middle/${List.filled(120, 'b').join()}.txt',
        '/workspace/newest/${List.filled(120, 'c').join()}.txt',
      ],
      completedSummaries: const ['完成目录扫描'],
    );

    expect(snapshot.artifactPaths.last, contains('/workspace/newest/'));
    expect(snapshot.artifactPaths, isNot(contains('/workspace/old/')));
  });

  test('restoring with a different conversation id fails closed', () {
    final raw = builder.build(
      conversationId: 'dm:a',
      target: '只属于 A',
      artifactPaths: const ['/workspace/a.txt'],
    ).toJsonString();

    expect(
      () => builder.restore(raw, conversationId: 'dm:b'),
      throwsA(isA<FormatException>()),
    );
    expect(builder.restore(raw, conversationId: 'dm:a').target, '只属于 A');
  });

  test('restoring JSON applies the same file-body redaction as building', () {
    final fileBody = List.filled(1000, 'FULL_FILE_BODY_').join();
    final toolBody = List.filled(1000, 'FULL_TOOL_BODY_').join();
    final raw = jsonEncode({
      'schemaVersion': 1,
      'conversationId': 'group-a',
      'target': '读取报告',
      'completedSummaries': [fileBody],
      'recentToolResults': [
        {
          'tool': 'workspace.read',
          'path': '/workspace/report.md',
          'content': toolBody,
        },
      ],
    });

    final restored = builder.restore(raw, conversationId: 'group-a');
    final encoded = restored.toJsonString();
    expect(encoded, isNot(contains(fileBody)));
    expect(encoded, isNot(contains(toolBody)));
    expect(encoded, contains('文件正文已省略'));
  });

  test('buildFromTask keeps durable queue, summary and artifact paths', () {
    final task = AgentTask(
      groupId: 'group-a',
      characterId: 'writer',
      userRequest: '初始目标',
      workModeTask: true,
      queuedUserRequests: const ['第一条追问', '第二条追问'],
      lastArtifactPaths: const ['/workspace/report.md'],
      contextSummary: builder.build(
        conversationId: 'group-a',
        target: '原始目标',
        completedSummaries: const ['已完成读取'],
      ).toJsonString(),
    );

    final restored = builder.fromTask(task);
    expect(restored.conversationId, 'group-a');
    expect(restored.target, '原始目标');
    expect(restored.pendingFollowUps, ['第一条追问', '第二条追问']);
    expect(restored.artifactPaths, ['/workspace/report.md']);
    expect(restored.completedSummaries, ['已完成读取']);
  });

  test('group context is shared only by the same conversation id', () {
    final group = builder.build(
      conversationId: 'group-a',
      target: '群内共同目标',
      completedSummaries: const ['群内摘要'],
    );
    final memberTask = AgentTask(
      groupId: 'group-a',
      characterId: 'member-b',
      userRequest: '继续群任务',
      workModeTask: true,
      contextSummary: group.toJsonString(),
    );
    expect(builder.fromTask(memberTask).completedSummaries, ['群内摘要']);

    final privateTask = AgentTask(
      groupId: 'dm:a',
      characterId: 'a',
      userRequest: '只属于 A',
      workModeTask: true,
      contextSummary: builder.build(
        conversationId: 'dm:b',
        target: 'B 的私聊内容不应出现',
        completedSummaries: const ['B_ONLY'],
      ).toJsonString(),
    );
    final isolated = builder.fromTask(privateTask);
    expect(isolated.conversationId, 'dm:a');
    expect(isolated.target, '只属于 A');
    expect(isolated.toJsonString(), isNot(contains('B_ONLY')));
  });

  test('canonical summary, paths and FIFO survive a Hive restart', () async {
    final directory =
        await Directory.systemTemp.createTemp('work-context-restart-');
    const boxName = 'work-context-restart';
    try {
      Hive.init(directory.path);
      if (!Hive.isAdapterRegistered(12)) {
        Hive.registerAdapter(AgentTaskStatusAdapter());
      }
      if (!Hive.isAdapterRegistered(13)) {
        Hive.registerAdapter(AgentTaskAdapter());
      }
      final box = await Hive.openBox<AgentTask>(boxName);
      final context = builder.build(
        conversationId: 'group-restart',
        target: '重启后继续处理',
        pendingFollowUps: const ['第一条追问', '第二条追问'],
        completedSummaries: const ['已完成初始读取'],
        artifactPaths: const ['/workspace/report.md'],
      );
      await box.put(
        'restart-task',
        AgentTask(
          id: 'restart-task',
          groupId: 'group-restart',
          characterId: 'writer',
          userRequest: '重启后继续处理',
          workModeTask: true,
          queuedUserRequests: const ['第一条追问', '第二条追问'],
          lastArtifactPaths: const ['/workspace/report.md'],
          contextSummary: context.toJsonString(),
        ),
      );
      await box.close();
      await Hive.close();

      Hive.init(directory.path);
      final reopened = await Hive.openBox<AgentTask>(boxName);
      final restored = builder.fromTask(reopened.get('restart-task')!);
      expect(restored.target, '重启后继续处理');
      expect(restored.pendingFollowUps, ['第一条追问', '第二条追问']);
      expect(restored.completedSummaries, ['已完成初始读取']);
      expect(restored.artifactPaths, ['/workspace/report.md']);
      await reopened.close();
      await Hive.close();
    } finally {
      if (Hive.isBoxOpen(boxName)) await Hive.box<AgentTask>(boxName).close();
      await Hive.close();
      if (await directory.exists()) await directory.delete(recursive: true);
    }
  });
}

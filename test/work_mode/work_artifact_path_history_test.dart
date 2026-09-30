import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/agentic/tool_request.dart';
import 'package:chat_group/features/work_mode/work_agent_loop.dart';
import 'package:chat_group/features/work_mode/work_artifact_delivery_confirmation.dart';
import 'package:chat_group/features/work_mode/work_artifact_delivery_guard.dart';
import 'package:chat_group/features/work_mode/work_failure.dart';
import 'package:chat_group/features/work_mode/work_task_clarification.dart';
import 'package:chat_group/features/work_mode/work_task_event.dart';
import 'package:chat_group/features/work_mode/work_tool_registry.dart';
import 'package:chat_group/features/work_mode/presentation/work_task_panel.dart';
import 'package:chat_group/features/work_mode/workspace_path_policy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 长任务的产物记录与完成校验。
///
/// 现场（taskId 15cf70c3…，2026-09-29）：任务跑了 113 步、7 小时，最后写出的
/// `老街改造详细方案.pdf`（18:12）和 `老街改造方案演示.pptx`（18:14）都真实存在于
/// 桌面，却一个都没进 `task.lastArtifactPaths` —— 记录停在最早的 64 条（脚本 +
/// 素材图）。交付门禁只看这 64 条，于是报"没有可读取的真实文件"，任务被判失败，
/// 且失败被归成不可重试的 `internal`，面板连"重试"都不给。
///
/// 本文件锁住这三件事：记录保留最新的、交付物优先保留、完成校验失败可重试。
class _FakeModel {
  final Queue<Object> responses = Queue<Object>();

  Future<Map<String, dynamic>> call(WorkAgentModelRequest request) async {
    if (responses.isEmpty) {
      throw StateError('fake model response queue is empty');
    }
    final next = responses.removeFirst();
    if (next is Exception) throw next;
    return Map<String, dynamic>.from(next as Map);
  }
}

class _FakeTool {
  WorkToolResult Function(WorkToolInvocation invocation)? behavior;

  Future<WorkToolResult> call(WorkToolInvocation invocation) async {
    return behavior?.call(invocation) ??
        const WorkToolResult.success(message: '工具已完成。');
  }
}

AgentTask _task({
  String request = '在桌面生成一个文件夹，包含详细 PDF 文档与 PPT 文档。',
}) =>
    AgentTask(
      id: 'artifact-path-history',
      groupId: 'loop-conversation',
      characterId: 'worker',
      userRequest: request,
      workModeTask: true,
      actionLimit: 500,
    );

Map<String, dynamic> _patchDecision(String path, int index) => {
      'success': true,
      'content': jsonEncode({
        'action': 'tool',
        'public_update': '正在写入 $path。',
        'tool': {
          'name': AgentToolName.workspacePatch.wireName,
          'arguments': {
            'path': path,
            'content': '第 $index 份内容',
          },
        },
        'completion': null,
      }),
    };

Map<String, dynamic> _finishDecision([String summary = '任务完成。']) => {
      'success': true,
      'content': jsonEncode({
        'action': 'finish',
        'public_update': '已完成全部步骤。',
        'tool': null,
        'completion': {
          'summary': summary,
          'evidence': <String>['fake'],
        },
      }),
    };

/// A registry whose only tool writes one file and reports it as changed.
WorkToolRegistry _patchRegistry() {
  final tool = _FakeTool()
    ..behavior = (invocation) => WorkToolResult.success(
          message: '文件操作已完成。',
          data: {
            'path': invocation.arguments['path'],
            'changed': true,
          },
        );
  return WorkToolRegistry(
    definitions: [
      WorkToolDefinition(
        name: AgentToolName.workspacePatch,
        access: WorkToolAccess.mutation,
        schema: const WorkToolSchema(
          fields: {
            'path': WorkToolValueType.string,
            'content': WorkToolValueType.string,
          },
          required: {'path'},
        ),
        handler: tool.call,
        mutationPipeline: WorkToolMutationPipeline(
          policy: (_) => null,
          approval: (_) => null,
          snapshot: (_) => null,
          lock: (_) => null,
        ),
      ),
    ],
  );
}

/// 交付确认：门禁认不出产物时先问用户。
void _deliveryConfirmationTests() {
  Future<WorkAgentLoopResult> runGuardRejected(
    AgentTask task, {
    required List<String> offered,
  }) async {
    final model = _FakeModel()
      ..responses.add(_finishDecision('第一次完成'))
      ..responses.add(_finishDecision('第二次完成'))
      ..responses.add(_finishDecision('第三次完成'));
    return WorkAgentLoop(
      model: model.call,
      registry: WorkToolRegistry(),
      sleep: (_) async {},
      maxCompletionRepairs: 2,
      completionGuard: (_, __) =>
          WorkArtifactDeliveryGuard.missingArtifactMessage,
      artifactConfirmation: (_) async => offered,
    ).execute(task);
  }

  test('asks the user instead of failing when the run wrote real files',
      () async {
    final task = _task();
    final result = await runGuardRejected(
      task,
      offered: <String>[
        '/workspace/mac_hardware_info.h',
        '/x/mac_hardware_info.cpp'
      ],
    );

    expect(result.status, WorkAgentLoopStatus.paused);
    expect(task.status, AgentTaskStatus.paused);
    expect(
      artifactDeliveryConfirmationPending(task.executionStateJson),
      isTrue,
      reason: '问题必须在记录里，重启后仍能回答',
    );
    expect(
      artifactDeliveryConfirmationPaths(task.executionStateJson),
      <String>['/workspace/mac_hardware_info.h', '/x/mac_hardware_info.cpp'],
    );
    expect(
      WorkTaskClarification.isPending(task),
      isTrue,
      reason: '走同一个澄清契约，面板才会给出回答入口',
    );
    expect(
      WorkTaskClarification.question(task),
      allOf(contains('mac_hardware_info.h'), contains('mac_hardware_info.cpp')),
      reason: '问题要点名文件，用户才能分辨产物和中间文件',
    );
  });

  test('keeps the plain failure when the run wrote nothing to offer', () async {
    final task = _task();
    final result = await runGuardRejected(task, offered: const <String>[]);

    expect(result.status, WorkAgentLoopStatus.failed);
    expect(task.status, AgentTaskStatus.failed);
    expect(artifactDeliveryConfirmationPaths(task.executionStateJson), isEmpty);
    expect(
      WorkFailure.fromTask(task)?.canRetry,
      isTrue,
      reason: '没有可确认的文件时仍然是可重试的失败',
    );
  });

  test('asks at most once, then reports the failure', () async {
    // 已经问过一次（结论可能是"不是，我要别的"），再撞同一堵墙就必须判失败，
    // 否则用户会被同一个问题反复拦住。
    final task = _task()
      ..executionStateJson =
          withArtifactDeliveryConfirmationPending('', <String>['/x/a.h']);
    final result = await runGuardRejected(task, offered: <String>['/x/a.h']);

    expect(result.status, WorkAgentLoopStatus.failed);
    expect(task.status, AgentTaskStatus.failed);
  });

  test('a confirmed delivery is delivered even when the format is unknown',
      () async {
    final root = await Directory.systemTemp.createTemp('confirm-delivery-');
    addTearDown(() => root.delete(recursive: true));
    final header = File('${root.path}/mac_hardware_info.h')
      ..writeAsStringSync('#pragma once\n');
    final source = File('${root.path}/mac_hardware_info.cpp')
      ..writeAsStringSync('int main() { return 0; }\n');
    final now = DateTime.now();
    final policy = WorkspacePathPolicy(authorizedRoots: [root.path]);

    AgentTask taskFor(String executionStateJson) => AgentTask(
          id: 'confirm-delivery',
          groupId: 'field',
          characterId: 'executor',
          // 门禁认不出的那种请求：裸写的 CPP/H 之外还点了别的格式。
          userRequest: '生成一个读取硬件的 objc 文件',
          workModeTask: true,
          createdAt: now,
          startedAt: now,
          lastArtifactPaths: <String>[header.path, source.path],
          executionStateJson: executionStateJson,
        );

    // 没有确认时，这两个文件按契约确实不合格。
    final withoutConfirmation = await WorkArtifactDeliveryGuard.validateTask(
      task: taskFor(''),
      pathPolicy: policy,
      workspaceRoot: root.path,
      now: now,
    );
    expect(withoutConfirmation.valid, isFalse);

    // 只是"问过"还不够，必须真的回答过。
    final pendingOnly = await WorkArtifactDeliveryGuard.validateTask(
      task: taskFor(
        withArtifactDeliveryConfirmationPending(
            '', <String>[header.path, source.path]),
      ),
      pathPolicy: policy,
      workspaceRoot: root.path,
      now: now,
    );
    expect(pendingOnly.valid, isFalse, reason: '等待回答不等于用户同意');

    final confirmed = await WorkArtifactDeliveryGuard.validateTask(
      task: taskFor(
        withArtifactDeliveryConfirmationAccepted(
            '', <String>[header.path, source.path]),
      ),
      pathPolicy: policy,
      workspaceRoot: root.path,
      now: now,
    );
    expect(confirmed.valid, isTrue, reason: confirmed.message);
    expect(confirmed.deliveredPaths, hasLength(2));
    expect(confirmed.requiresArtifact, isTrue);
  });

  test('a confirmed path that is gone is still refused', () async {
    // 用户确认的是"这些文件"，不是"随便什么都行"：文件消失后不能凭空通过。
    final root = await Directory.systemTemp.createTemp('confirm-gone-');
    addTearDown(() => root.delete(recursive: true));
    final now = DateTime.now();
    final task = AgentTask(
      id: 'confirm-gone',
      groupId: 'field',
      characterId: 'executor',
      userRequest: '生成一个读取硬件的 objc 文件',
      workModeTask: true,
      createdAt: now,
      startedAt: now,
      lastArtifactPaths: <String>['${root.path}/gone.h'],
      executionStateJson: withArtifactDeliveryConfirmationAccepted(
        '',
        <String>['${root.path}/gone.h'],
      ),
    );

    final result = await WorkArtifactDeliveryGuard.validateTask(
      task: task,
      pathPolicy: WorkspacePathPolicy(authorizedRoots: [root.path]),
      workspaceRoot: root.path,
      now: now,
    );

    expect(result.valid, isFalse);
    expect(result.message, WorkArtifactDeliveryGuard.missingArtifactMessage);
  });
  testWidgets('offers the delivery confirmation only while it is pending',
      (tester) async {
    var confirmed = 0;
    AgentTask taskFor(String executionStateJson) => AgentTask(
          id: 'panel-confirm-artifact',
          groupId: 'group-one',
          characterId: 'worker',
          userRequest: '生成一个读取硬件的 objc 文件',
          workModeTask: true,
        )..executionStateJson = executionStateJson;

    Future<void> pump(String executionStateJson) => tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: WorkTaskPanel(
                tasks: <AgentTask>[
                  taskFor(executionStateJson)..status = AgentTaskStatus.paused,
                ],
                eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
                onSelectTask: (_) {},
                onStop: (_) {},
                onContinue: (_) {},
                onConfirmArtifactDelivery: (_) async => confirmed++,
                onOpenConversation: (_) {},
                onCollapse: () {},
                onClose: () {},
              ),
            ),
          ),
        );

    await pump(
      withArtifactDeliveryConfirmationPending(
        '',
        <String>['/x/mac_hardware_info.h', '/x/mac_hardware_info.cpp'],
      ),
    );
    expect(find.byKey(const Key('work-task-confirm-artifact')), findsOneWidget);
    expect(find.text('确认交付 2 个文件'), findsOneWidget);
    await tester.tap(find.byKey(const Key('work-task-confirm-artifact')));
    expect(confirmed, 1);

    // 回答之后就不要再问第二遍。
    await pump(
      withArtifactDeliveryConfirmationAccepted('', <String>['/x/a.h']),
    );
    expect(find.byKey(const Key('work-task-confirm-artifact')), findsNothing);
  });
  test('an unchanged revision is not overrulable by confirming files',
      () async {
    // 这条拒绝说的不是"认不出格式"，而是"什么都没改"。手上只有未修改的原文件，
    // 让用户确认它就把反造假检查绕过去了。
    final root = await Directory.systemTemp.createTemp('confirm-revision-');
    addTearDown(() => root.delete(recursive: true));
    final page = File('${root.path}/page.html')
      ..writeAsStringSync('<html><body><main>旧页面</main></body></html>');
    final now = DateTime.now();
    final task = AgentTask(
      id: 'confirm-revision',
      groupId: 'field',
      characterId: 'executor',
      userRequest: '优化一下',
      workModeTask: true,
      createdAt: now,
      startedAt: now,
      lastArtifactPaths: <String>[page.path],
      executionStateJson: jsonEncode(<String, dynamic>{
        'followUpKind': 'reviseArtifact',
        'revisionTargetPath': page.path,
      }),
    );

    final result = await WorkArtifactDeliveryGuard.validateTask(
      task: task,
      pathPolicy: WorkspacePathPolicy(authorizedRoots: [root.path]),
      workspaceRoot: root.path,
      now: now,
    );

    expect(result.valid, isFalse);
    expect(result.code, WorkArtifactDeliveryGuard.unchangedRevisionCode);
    expect(result.confirmable, isFalse);
  });

  test('a missing deliverable is overrulable by confirming files', () async {
    // 反面：认不出产物格式的那一类拒绝必须可确认，否则这个功能就没有意义。
    final root = await Directory.systemTemp.createTemp('confirm-missing-');
    addTearDown(() => root.delete(recursive: true));
    final now = DateTime.now();
    final task = AgentTask(
      id: 'confirm-missing',
      groupId: 'field',
      characterId: 'executor',
      userRequest: '生成一个读取硬件的 objc 文件',
      workModeTask: true,
      createdAt: now,
      startedAt: now,
      lastArtifactPaths: <String>['${root.path}/a.h'],
    );

    final result = await WorkArtifactDeliveryGuard.validateTask(
      task: task,
      pathPolicy: WorkspacePathPolicy(authorizedRoots: [root.path]),
      workspaceRoot: root.path,
      now: now,
    );

    expect(result.valid, isFalse);
    expect(result.confirmable, isTrue);
  });
}

void main() {
  test('a full artifact window still records the newly written deliverable',
      () async {
    // 现场形态：任务早期已经写满 64 个不同路径（脚本 + 素材图），此时才写出真正
    // 的交付物。运行开始时列表就是这个状态。
    final seeded = <String>[
      for (var index = 0; index < 64; index++) '生成脚本/stage$index.py',
    ];
    const deliverablePath = '老街改造详细方案.pdf';

    final model = _FakeModel()
      ..responses.add(_patchDecision('生成脚本/part0.py', 0))
      ..responses.add(_patchDecision('生成脚本/part1.py', 1))
      ..responses.add(_patchDecision(deliverablePath, 2))
      ..responses.add(_finishDecision());

    final task = _task()..lastArtifactPaths = seeded;
    final result = await WorkAgentLoop(
      model: model.call,
      registry: _patchRegistry(),
      sleep: (_) async {},
    ).execute(task);

    expect(
      result.status,
      WorkAgentLoopStatus.completed,
      reason: 'loop paused: ${task.lastError}',
    );
    expect(
      task.lastArtifactPaths,
      contains(deliverablePath),
      reason: '新写出的交付物必须进入记录，否则交付门禁看不到它',
    );
    expect(
      task.lastArtifactPaths,
      contains('生成脚本/part1.py'),
      reason: '列表满了之后写入的中间文件也应当留下',
    );
    expect(
      task.lastArtifactPaths,
      hasLength(64),
      reason: '窗口上限不变；丢掉的是最旧的中间文件，不是最新的',
    );
    expect(task.lastArtifactPaths, isNot(contains('生成脚本/stage0.py')));
  });

  test('keeps a deliverable that was written before the window filled',
      () async {
    // 交付物写在最前面、之后被大量中间文件淹没时，仍然必须留在记录里：门禁只
    // 接受请求点名的格式，交付物一旦滚出窗口，任务就再也无法完成。
    const deliverablePath = '老街改造详细方案.pdf';
    final seeded = <String>[
      deliverablePath,
      for (var index = 0; index < 63; index++) '生成脚本/stage$index.py',
    ];

    final model = _FakeModel()
      ..responses.add(_patchDecision('生成脚本/late0.py', 0))
      ..responses.add(_patchDecision('生成脚本/late1.py', 1))
      ..responses.add(_finishDecision());

    final task = _task()..lastArtifactPaths = seeded;
    final result = await WorkAgentLoop(
      model: model.call,
      registry: _patchRegistry(),
      sleep: (_) async {},
    ).execute(task);

    expect(
      result.status,
      WorkAgentLoopStatus.completed,
      reason: 'loop paused: ${task.lastError}',
    );
    expect(
      task.lastArtifactPaths,
      contains(deliverablePath),
      reason: '请求点名格式的交付物优先于中间文件保留',
    );
    expect(task.lastArtifactPaths, contains('生成脚本/late1.py'));
    expect(task.lastArtifactPaths, hasLength(64));
  });

  test('never grows past the window even when every file is a deliverable',
      () async {
    // 请求点名了同一种格式时，运行写出的每个文件都是交付物；钉住它们不能把
    // 窗口撑破，丢掉的是最旧的那些。
    final seeded = <String>[
      for (var index = 0; index < 100; index++) '图片/p$index.png',
    ];

    final model = _FakeModel()
      ..responses.add(_patchDecision('图片/p100.png', 100))
      ..responses.add(_finishDecision());

    final task = _task(request: '把老街现状与效果图生成一批 png 图片并保存到文件夹')
      ..lastArtifactPaths = seeded;
    final result = await WorkAgentLoop(
      model: model.call,
      registry: _patchRegistry(),
      sleep: (_) async {},
    ).execute(task);

    expect(
      result.status,
      WorkAgentLoopStatus.completed,
      reason: 'loop paused: ${task.lastError}',
    );
    expect(task.lastArtifactPaths, hasLength(64));
    expect(
      task.lastArtifactPaths,
      contains('图片/p100.png'),
      reason: '最新写出的交付物留在窗口内',
    );
    expect(task.lastArtifactPaths, isNot(contains('图片/p0.png')));
  });

  test('a rejected completion is retryable instead of an internal failure',
      () async {
    final model = _FakeModel()
      ..responses.add(_finishDecision('第一次完成'))
      ..responses.add(_finishDecision('第二次完成'))
      ..responses.add(_finishDecision('第三次完成'));

    final task = _task();
    final result = await WorkAgentLoop(
      model: model.call,
      registry: WorkToolRegistry(),
      sleep: (_) async {},
      maxCompletionRepairs: 2,
      completionGuard: (_, __) =>
          WorkArtifactDeliveryGuard.missingArtifactMessage,
    ).execute(task);

    expect(result.status, WorkAgentLoopStatus.failed);
    final failure = WorkFailure.fromTask(task);
    expect(failure, isNotNull);
    expect(failure!.type, WorkFailureType.completionUnmet);
    expect(
      failure.canRetry,
      isTrue,
      reason: '面板的“重试”只在 onRetry != null && failure.canRetry 时渲染',
    );
    expect(failure.suggestedAction, contains('重试'));
  });

  _fieldGuardTests();
  _bareSourceWordTests();
  _deliveryConfirmationTests();
}

/// 现场请求原文（截图里的那条）。
const _fieldRequest = '好呀，你将老街改造的整体项目 再桌面生成一个文件夹，里面包含老街改造的详细PDF文档，'
    '文档要求3000字并且加上老街现在配图和以后的配图，另再给我一份详细的PPT文档，'
    '要求50+页，每一页要有详细的配图，配图不得重复';

void _fieldGuardTests() {
  test(
      'the guard reports the field message when the deliverable is not recorded',
      () async {
    final root = await Directory.systemTemp.createTemp('artifact-history-');
    addTearDown(() => root.delete(recursive: true));
    final scripts = <String>[];
    for (var index = 0; index < 64; index++) {
      final file = File('${root.path}/stage$index.py')
        ..writeAsStringSync('print($index)');
      scripts.add(file.path);
    }
    final pdf = File('${root.path}/老街改造详细方案.pdf')
      ..writeAsBytesSync(List<int>.filled(2048, 0x25));
    final now = DateTime.now();
    final policy = WorkspacePathPolicy(authorizedRoots: [root.path]);

    expect(
      WorkArtifactDeliveryGuard.requiresFileArtifact(_fieldRequest),
      isTrue,
      reason: '请求点名了 pdf/pptx，必须带文件契约',
    );

    final truncated = AgentTask(
      id: 'truncated',
      groupId: 'field',
      characterId: 'executor',
      userRequest: _fieldRequest,
      workModeTask: true,
      createdAt: now,
      startedAt: now,
      lastArtifactPaths: scripts,
    );
    final truncatedResult = await WorkArtifactDeliveryGuard.validateTask(
      task: truncated,
      pathPolicy: policy,
      workspaceRoot: root.path,
      now: now,
    );

    expect(truncatedResult.valid, isFalse);
    expect(
      truncatedResult.message,
      WorkArtifactDeliveryGuard.missingArtifactMessage,
      reason: '这正是现场聊天里出现的那句话',
    );

    final recorded = AgentTask(
      id: 'recorded',
      groupId: 'field',
      characterId: 'executor',
      userRequest: _fieldRequest,
      workModeTask: true,
      createdAt: now,
      startedAt: now,
      // 记录里只有少量中间文件时，交付物在 64 条窗口内。
      lastArtifactPaths: <String>[...scripts.take(10), pdf.path],
    );
    final recordedResult = await WorkArtifactDeliveryGuard.validateTask(
      task: recorded,
      pathPolicy: policy,
      workspaceRoot: root.path,
      now: now,
    );

    expect(
      recordedResult.valid,
      isTrue,
      reason: '同一次运行、同一批文件，只差交付物是否进入记录：${recordedResult.message}',
    );
    expect(
      recordedResult.path,
      endsWith('老街改造详细方案.pdf'),
      reason: 'macOS 的 /var 与 /private/var 是同一条路径的两种写法',
    );

    // 第二处同类截断：门禁自己也只看记录的前 64 条，而且保留的同样是最旧的。
    // 即使 runner 把交付物写进了记录，只要它的下标 ≥64，门禁依然看不见。
    final beyondWindow = AgentTask(
      id: 'beyond-window',
      groupId: 'field',
      characterId: 'executor',
      userRequest: _fieldRequest,
      workModeTask: true,
      createdAt: now,
      startedAt: now,
      lastArtifactPaths: <String>[...scripts, pdf.path],
    );
    final beyondWindowResult = await WorkArtifactDeliveryGuard.validateTask(
      task: beyondWindow,
      pathPolicy: policy,
      workspaceRoot: root.path,
      now: now,
    );

    expect(
      beyondWindowResult.valid,
      isTrue,
      reason: '交付物就在记录里（第 65 条），门禁不该因为它排在窗口外而判失败',
    );
  });
}

/// 现场请求原文（截图里的那条，私聊「周明」）。
const _cppFieldRequest = '帮我生成 一个读取MAC 系统硬件的 CPP和H文件';

void _bareSourceWordTests() {
  test('a request naming CPP and H as bare words is a source request', () {
    // 先钉住"同样意思换个写法就能过"，证明失败来自措辞而不是别的环节。
    expect(
      WorkArtifactDeliveryGuard.requiresSourceArtifact(
          '生成一个读取MAC系统硬件的 .cpp 和 .h 文件'),
      isTrue,
      reason: '写成扩展名 .cpp/.h',
    );
    expect(
      WorkArtifactDeliveryGuard.requiresSourceArtifact('生成一个读取MAC系统硬件的 C++ 文件'),
      isTrue,
      reason: '写成 C++',
    );
    expect(
      WorkArtifactDeliveryGuard.requiresFileArtifact(_cppFieldRequest),
      isTrue,
      reason: '“文件” + cpp 让它成为一个带文件契约的任务',
    );
    expect(
      WorkArtifactDeliveryGuard.requiresSourceArtifact(_cppFieldRequest),
      isTrue,
      reason: '用户要的就是源码；不认它就会被当成文档任务，'
          '于是写出的 .h/.cpp 被当作“生成脚本”拒绝',
    );
  });

  test('every format spelling in the table is reachable from a request',
      () async {
    // 表驱动的护栏：词表里每个拼写至少要在一种真实写法下被认出来——用户写的
    // `CPP和H文件`（裸词）和 `report.cpp`（扩展名）都得算数。当初 `cpp` 的
    // 漏洞正是这条会红的场景：扩展名写法一直没坏，坏的是裸词写法。
    final broken = <String>[];
    var covered = 0;

    for (final entry in WorkArtifactDeliveryGuard.formatAliases.entries) {
      final canonical = entry.value;
      final spelling = entry.key;
      final isSource = WorkArtifactDeliveryGuard.isSourceFormat(canonical);

      bool reachable(String request) =>
          WorkArtifactDeliveryGuard.requiresFileArtifact(request) &&
          (!isSource ||
              WorkArtifactDeliveryGuard.requiresSourceArtifact(request));

      final byExtension = reachable('生成一个程序.$spelling');
      final byWord = reachable('生成一个 $spelling 文件');
      if (!byExtension && !byWord) {
        broken.add('$spelling: 扩展名写法和裸词写法都没被认成'
            '${isSource ? '源码' : '文件'}请求');
      }
      covered++;
    }

    expect(covered, greaterThan(150), reason: '表驱动用例不该空转');
    expect(broken, isEmpty, reason: '这些拼写没走通：\n${broken.join('\n')}');
  });

  test('the guard accepts a real file for every text-representable spelling',
      () async {
    // 上一用例只验请求侧；这里再验交付侧：认得出来的拼写，写出的真实文件也必须
    // 被收下。Office 与 HTML 家族跳过——它们另有结构校验（真实 DOCX 正文、
    // 完整 html/body），由 work_artifact_delivery_guard_test.dart 用真实夹具覆盖。
    const structuredOnly = <String>{
      'docx',
      'html',
    };
    final root = await Directory.systemTemp.createTemp('format-table-');
    addTearDown(() => root.delete(recursive: true));
    final policy = WorkspacePathPolicy(authorizedRoots: [root.path]);
    final now = DateTime.now();
    final broken = <String>[];
    var covered = 0;

    for (final entry in WorkArtifactDeliveryGuard.formatAliases.entries) {
      final canonical = entry.value;
      if (structuredOnly.contains(canonical)) continue;
      final spelling = entry.key;
      final deliverable = File('${root.path}/artefact.$spelling')
        ..writeAsStringSync('payload for $spelling\n');
      final request = '生成一个程序.$spelling';
      final task = AgentTask(
        id: 'format-table-$spelling',
        groupId: 'table',
        characterId: 'worker',
        userRequest: request,
        workModeTask: true,
        createdAt: now,
        startedAt: now,
        lastArtifactPaths: <String>[deliverable.path],
      );

      final result = await WorkArtifactDeliveryGuard.validateTask(
        task: task,
        pathPolicy: policy,
        workspaceRoot: root.path,
        now: now,
      );
      if (!result.valid) {
        broken.add('$spelling: 交付侧拒绝了 artefact.$spelling（${result.code}）');
      }
      covered++;
    }

    expect(covered, greaterThan(140), reason: '表驱动用例不该空转');
    expect(broken, isEmpty, reason: '这些拼写没走通：\n${broken.join('\n')}');
  });

  test('a bare ambiguous format word never turns prose into a file task', () {
    // 这些拼写既是格式名也是普通词或常见缩写。它们只允许在扩展名或紧跟文件名词
    // 时生效，否则“生成一份 less 的说明”会变成必须产出文件的任务。
    for (final request in <String>[
      '生成一份 less 的说明',
      '生成一份 sass 的说明',
      '生成一份 zig 的说明',
      '生成一份 nim 的说明',
      '生成一份 ml 的说明',
      '生成一份 fs 的说明',
      '生成一份 sol 的说明',
      '生成一份 v 的说明',
      '生成一份 s 的说明',
      '生成一份 A/B/C 三种方案的对比',
    ]) {
      expect(
        WorkArtifactDeliveryGuard.requiresFileArtifact(request),
        isFalse,
        reason: request,
      );
      expect(
        WorkArtifactDeliveryGuard.requiresSourceArtifact(request),
        isFalse,
        reason: request,
      );
    }
  });

  test('a dotted abbreviation is not read as a file extension', () async {
    // “U.S.” 里的 `.s` 被当成扩展名，于是 `.s`→`asm` 成了这份报告请求的"点名格式"：
    // 桌面上真实的 us_market_report.txt 被判成 "artifactInvalidOrStale"，报的还是
    // 那句"没有可读取的真实文件"。缩写里的点不是扩展名——真正的扩展名是文件名的
    // 最后一段，后面不会再跟点。
    const request = '帮我生成一份 U.S. 市场的分析报告';
    expect(
      WorkArtifactDeliveryGuard.requiresSourceArtifact(request),
      isFalse,
      reason: '缩写不该把报告请求变成源码请求',
    );
    expect(
      WorkArtifactDeliveryGuard.declaredOutputFormats(_task(request: request)),
      isEmpty,
      reason: '报告请求没点名任何格式；点成 asm 会把它自己的交付物拒掉',
    );

    final root = await Directory.systemTemp.createTemp('dotted-abbrev-');
    addTearDown(() => root.delete(recursive: true));
    final report = File('${root.path}/us_market_report.txt')
      ..writeAsStringSync('U.S. 市场分析\n');
    final now = DateTime.now();
    final task = AgentTask(
      id: 'dotted-abbrev',
      groupId: 'field',
      characterId: 'executor',
      userRequest: request,
      workModeTask: true,
      createdAt: now,
      startedAt: now,
      lastArtifactPaths: <String>[report.path],
    );

    final result = await WorkArtifactDeliveryGuard.validateTask(
      task: task,
      pathPolicy: WorkspacePathPolicy(authorizedRoots: [root.path]),
      workspaceRoot: root.path,
      now: now,
    );

    expect(result.valid, isTrue, reason: result.message);

    // 同一枚点在别处仍然只是普通文本：句尾带点的缩写后面接别的词也一样。
    expect(
      WorkArtifactDeliveryGuard.requiresSourceArtifact('生成一份报告，参考 U.S. 的数据'),
      isFalse,
    );
    // 反过来，真正写在句尾的扩展名照样算数（不能靠"后面不能有点"把正常写法漏掉）。
    expect(
      WorkArtifactDeliveryGuard.requiresSourceArtifact('生成一个程序.lua'),
      isTrue,
    );
    expect(
      WorkArtifactDeliveryGuard.declaredOutputFormats(
        _task(request: '生成一个程序.lua'),
      ),
      <String>{'lua'},
    );
  });

  test('an initialism written without its final dot is not an extension either',
      () async {
    // `U.S`（省略末点）与 `a.h` 形状完全相同——点两侧各一个单字母，没有结构性规则
    // 能把它们分开，只有大小写可以：缩写由大写字母加点连成，用户点名的文件是小写。
    // 少了这一层，`U.S` 仍然会把声明格式变成 asm、把请求判成源码请求。
    for (final request in <String>[
      '帮我生成一份 U.S 市场的分析报告',
      '帮我生成一份 U.S. 市场的分析报告',
      '帮我生成一份 U.S.A 市场的分析报告',
      '生成一份报告，补充 P.S 说明',
    ]) {
      expect(
        WorkArtifactDeliveryGuard.declaredOutputFormats(
            _task(request: request)),
        isEmpty,
        reason: request,
      );
      expect(
        WorkArtifactDeliveryGuard.requiresSourceArtifact(request),
        isFalse,
        reason: request,
      );
    }

    // 端到端看同一个症状：请求里带缩写时，桌面上真实的报告文件必须能被收下。
    final root = await Directory.systemTemp.createTemp('initialism-');
    addTearDown(() => root.delete(recursive: true));
    final report = File('${root.path}/us_market_report.txt')
      ..writeAsStringSync('U.S 市场分析\n');
    final now = DateTime.now();
    final result = await WorkArtifactDeliveryGuard.validateTask(
      task: AgentTask(
        id: 'initialism',
        groupId: 'field',
        characterId: 'executor',
        userRequest: '帮我生成一份 U.S 市场的分析报告',
        workModeTask: true,
        createdAt: now,
        startedAt: now,
        lastArtifactPaths: <String>[report.path],
      ),
      pathPolicy: WorkspacePathPolicy(authorizedRoots: [root.path]),
      workspaceRoot: root.path,
      now: now,
    );

    expect(result.valid, isTrue, reason: result.message);

    // 反面清单：小写的单字母主干必须照旧算扩展名——C/C++ 现场就是靠它认出 a.h 的。
    // 期望值是 canonical：`.h` 与 `.cpp` 同属一个交付物族。
    for (final entry in <String, String>{
      '生成 a.h': 'cpp',
      '生成 a.cpp': 'cpp',
      '生成 report.s': 'asm',
      '生成 a.py': 'py',
    }.entries) {
      expect(
        WorkArtifactDeliveryGuard.declaredOutputFormats(
          _task(request: entry.key),
        ),
        <String>{entry.value},
        reason: entry.key,
      );
    }
    expect(WorkArtifactDeliveryGuard.requiresSourceArtifact('生成 a.h'), isTrue);
    expect(
      WorkArtifactDeliveryGuard.requiresSourceArtifact('帮我生成一份 US 市场的分析报告'),
      isFalse,
      reason: '去掉缩写点之后剩下的普通词不能变成格式',
    );
    // 这一层只在大写碰上大写时生效：`R&D.docx` 里的点后是小写，扩展名照旧。
    expect(
      WorkArtifactDeliveryGuard.declaredOutputFormats(
        _task(request: '生成一份 R&D.docx'),
      ),
      <String>{'docx'},
    );
  });

  test('a header belongs to the same deliverable family as its source', () {
    expect(
        WorkArtifactDeliveryGuard.matchesDeclaredFormat('a.h', 'cpp'), isTrue);
    expect(
      WorkArtifactDeliveryGuard.matchesDeclaredFormat('a.hpp', 'cpp'),
      isTrue,
    );
    expect(WorkArtifactDeliveryGuard.matchesDeclaredFormat('a.cpp', 'cpp'),
        isTrue);
    // 反过来不成立，别把 C 也折进去。
    expect(
        WorkArtifactDeliveryGuard.matchesDeclaredFormat('a.h', 'c'), isFalse);
    // 只有裸写的 `c`（A/B/C 那种）不该被读成点名了 .c 格式。
    final task = _task(request: '生成一份 A/B/C 三种方案的对比');
    expect(WorkArtifactDeliveryGuard.declaredOutputFormats(task), isEmpty);
  });

  test('a short format spelling in front of a file noun is a source signal',
      () async {
    // 请求写得很明确：“H文件”。紧挨着的“文件”二字就是那个单字母的消歧依据。
    const request = '帮我生成一个读取 Mac 硬件信息的 H 文件';
    expect(
      WorkArtifactDeliveryGuard.requiresSourceArtifact(request),
      isTrue,
      reason: '“H文件”必须被认成源码请求，否则写出的 .h 会被当成生成脚本排除',
    );
    // 同一个字母出现在别处时不算信号：这里的 `h` 后面没有文件名词。
    expect(
      WorkArtifactDeliveryGuard.requiresSourceArtifact('把 h 的值更新为 5'),
      isFalse,
      reason: '单字母裸写太弱，不能仅凭它把散文请求变成文件任务',
    );

    final root = await Directory.systemTemp.createTemp('header-contract-');
    addTearDown(() => root.delete(recursive: true));
    final header = File('${root.path}/mac_hardware_info.h')
      ..writeAsStringSync('#pragma once\nstruct CpuInfo {};\n');
    final now = DateTime.now();
    final task = AgentTask(
      id: 'header-contract',
      groupId: 'field',
      characterId: 'executor',
      userRequest: request,
      workModeTask: true,
      createdAt: now,
      startedAt: now,
      lastArtifactPaths: <String>[header.path],
    );

    final result = await WorkArtifactDeliveryGuard.validateTask(
      task: task,
      pathPolicy: WorkspacePathPolicy(authorizedRoots: [root.path]),
      workspaceRoot: root.path,
      now: now,
    );

    expect(result.valid, isTrue, reason: result.message);
    expect(result.deliveredPaths, hasLength(1));
  });

  test('the guard accepts the two source files this request produces',
      () async {
    final root = await Directory.systemTemp.createTemp('cpp-contract-');
    addTearDown(() => root.delete(recursive: true));
    final header = File('${root.path}/mac_hardware_info.h')
      ..writeAsStringSync('#pragma once\nstruct CpuInfo {};\n');
    final source = File('${root.path}/mac_hardware_info.cpp')
      ..writeAsStringSync(
          '#include "mac_hardware_info.h"\nint main() { return 0; }\n');
    final now = DateTime.now();
    final task = AgentTask(
      id: 'cpp-contract',
      groupId: 'field',
      characterId: 'executor',
      userRequest: _cppFieldRequest,
      workModeTask: true,
      createdAt: now,
      startedAt: now,
      lastArtifactPaths: <String>[header.path, source.path],
    );

    final result = await WorkArtifactDeliveryGuard.validateTask(
      task: task,
      pathPolicy: WorkspacePathPolicy(authorizedRoots: [root.path]),
      workspaceRoot: root.path,
      now: now,
    );

    expect(
      result.valid,
      isTrue,
      reason: '两个真实源码文件就是用户要的交付物：${result.message}',
    );
    expect(result.deliveredPaths, hasLength(2));
  });
}

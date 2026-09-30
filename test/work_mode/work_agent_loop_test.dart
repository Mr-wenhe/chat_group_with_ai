import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/agentic/tool_request.dart';
import 'package:chat_group/features/work_mode/agent_decision.dart';
import 'package:chat_group/features/work_mode/work_agent_loop.dart';
import 'package:chat_group/features/work_mode/work_change_plan.dart';
import 'package:chat_group/features/work_mode/work_handoff_state.dart';
import 'package:chat_group/features/work_mode/work_task_approval_plan.dart';
import 'package:chat_group/features/work_mode/work_task_event.dart';
import 'package:chat_group/features/work_mode/work_task_coordinator.dart';
import 'package:chat_group/features/work_mode/work_task_budget_wait.dart';
import 'package:chat_group/features/work_mode/work_discussion_state.dart';
import 'package:chat_group/features/work_mode/work_context_builder.dart';
import 'package:chat_group/features/work_mode/work_failure.dart';
import 'package:chat_group/features/work_mode/work_model_deadline.dart';
import 'package:chat_group/features/work_mode/work_tool_registry.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeClock {
  DateTime now;

  _FakeClock([DateTime? initial])
      : now = initial ?? DateTime.utc(2026, 8, 31, 8);

  DateTime call() => now;

  void advance(Duration duration) {
    now = now.add(duration);
  }
}

class _FakeModel {
  final Queue<Object> responses = Queue<Object>();
  final List<WorkAgentModelRequest> requests = <WorkAgentModelRequest>[];

  Future<Map<String, dynamic>> call(WorkAgentModelRequest request) async {
    requests.add(request);
    if (responses.isEmpty) {
      throw StateError('fake model response queue is empty');
    }
    final next = responses.removeFirst();
    if (next is Exception) throw next;
    if (next is Error) throw next;
    return Map<String, dynamic>.from(next as Map);
  }
}

class _FakeTool {
  int calls = 0;
  final List<Map<String, dynamic>> arguments = <Map<String, dynamic>>[];
  WorkToolResult Function(WorkToolInvocation invocation)? behavior;

  Future<WorkToolResult> call(WorkToolInvocation invocation) async {
    calls++;
    arguments.add(Map<String, dynamic>.from(invocation.arguments));
    return behavior?.call(invocation) ??
        const WorkToolResult.success(message: '工具已完成。');
  }
}

WorkToolMutationPipeline _recordingPipeline(List<String> phases) {
  return WorkToolMutationPipeline(
    policy: (_) {
      phases.add('policy');
      return null;
    },
    approval: (_) {
      phases.add('approval');
      return null;
    },
    snapshot: (_) {
      phases.add('snapshot');
      return null;
    },
    lock: (_) {
      phases.add('lock');
      return null;
    },
  );
}

AgentTask _task({
  String id = 'loop-task',
  int actionLimit = AgentTask.defaultActionLimit,
  int softTimeLimitMinutes = AgentTask.defaultSoftTimeLimitMinutes,
}) {
  return AgentTask(
    id: id,
    groupId: 'loop-conversation',
    characterId: 'worker',
    userRequest: '完成工作模式任务',
    workModeTask: true,
    actionLimit: actionLimit,
    softTimeLimitMinutes: softTimeLimitMinutes,
  );
}

Map<String, dynamic> _toolDecision({
  String path = 'notes.txt',
  AgentToolName name = AgentToolName.workspaceRead,
  Map<String, dynamic>? arguments,
  String update = '正在执行工具。',
}) {
  final args = arguments ??
      (name == AgentToolName.workspacePatch
          ? {
              'path': path,
              'content': '完成内容',
            }
          : {'path': path});
  return {
    'success': true,
    'content': jsonEncode({
      'action': 'tool',
      'public_update': update,
      'tool': {
        'name': name.wireName,
        'arguments': args,
      },
      'completion': null,
    }),
  };
}

Map<String, dynamic> _planDecision() => {
      'success': true,
      'content': jsonEncode({
        'action': 'plan',
        'public_update': '已确认执行计划。',
        'tool': null,
        'completion': {
          'steps': ['先读取工作区，再完成任务。'],
        },
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
          'evidence': ['Fake tool result'],
        },
      }),
    };

Map<String, dynamic> _handoffDecision({
  String target = 'receiver',
  String summary = '当前阶段完成。',
}) =>
    {
      'success': true,
      'content': jsonEncode({
        'action': 'handoff',
        'public_update': '已完成当前阶段，交给下一角色。',
        'tool': null,
        'completion': {
          'target': target,
          'summary': summary,
        },
      }),
    };

WorkToolDefinition _definition(
  AgentToolName name,
  _FakeTool fake, {
  WorkToolAccess access = WorkToolAccess.readOnly,
  WorkToolMutationPipeline? pipeline,
  bool skillDownload = false,
}) {
  return WorkToolDefinition(
    name: name,
    access: access,
    schema: WorkToolSchema(
      fields: skillDownload
          ? {'templateId': WorkToolValueType.string}
          : {
              'path': WorkToolValueType.string,
              'content': WorkToolValueType.string,
              // 生产 schema 同样声明了它们（`default_work_task_runner_tools.dart`）：
              // 夹具少一个字段，循环合成的追加写就会在校验处被判成"不支持参数"。
              'append': WorkToolValueType.boolean,
              'overwrite': WorkToolValueType.boolean,
            },
      required: skillDownload ? {'templateId'} : {'path'},
    ),
    handler: fake.call,
    mutationPipeline: pipeline,
  );
}

/// `workspace.patch` 的变更工具夹具，闸门默认全部放行。
///
/// 生产里它是 **mutation**；夹具若用默认的只读形态，`_safeResult` 的 `committed`
/// 恒为 false，抢救会一直落在"没落盘"的兜底分支上——续写指令根本不会被构造出来，
/// 相关断言就只能在别处漏出来的文件名上碰巧通过。
WorkToolDefinition _patchDefinition(
  _FakeTool tool, {
  WorkToolMutationPipeline? pipeline,
}) {
  return _definition(
    AgentToolName.workspacePatch,
    tool,
    access: WorkToolAccess.mutation,
    pipeline: pipeline ?? _recordingPipeline(<String>[]),
  );
}

/// 审批通过后协调器重放的那个请求。
///
/// 生产里它是 runner 内存中留着的那份完整请求（`_pendingRequests[task.id]`），不是
/// 持久化检查点——检查点只用于 `canResumeApprovedTool` 的逐字比对，因此这里按抢救
/// 的真实参数重建：派生路径从检查点取（它是抢救自己算出来的），正文与开关与
/// `_salvageRequest` 一致，于是两边的 `safeToolRequestCheckpoint` 逐字相同。
ToolRequest _resumeSalvageRequest(AgentTask task) {
  final checkpoint = ToolRequest.fromJsonString(task.pendingToolRequestJson)!;
  return ToolRequest(
    tool: AgentToolName.workspacePatch,
    reason: '截断抢救',
    args: {
      'path': checkpoint.args['path'],
      'content': '第一段',
      'append': true,
      'overwrite': false,
    },
  );
}

WorkAgentLoop _loop({
  required _FakeModel model,
  required WorkToolRegistry registry,
  _FakeClock? clock,
  List<WorkTaskEvent>? events,
  Future<void> Function(Duration)? sleep,
  double Function()? retryJitter,
  int? maxModelRetries,
  int? maxToolRetries,
  int? maxToolRepairs,
  int? maxCompletionRepairs,
  WorkAgentArtifactCompletion? artifactCompletion,
  WorkAgentCompletionGuard? completionGuard,
  WorkAgentPreflightTool? preflightTool,
  int? promptCompactionBudgetTokens,
}) {
  return WorkAgentLoop(
    model: model.call,
    registry: registry,
    clock: clock?.call,
    sleep: sleep ?? (_) async {},
    retryJitter: retryJitter ?? () => 0.5,
    maxModelRetries: maxModelRetries,
    maxToolRetries: maxToolRetries,
    maxToolRepairs: maxToolRepairs,
    maxCompletionRepairs: maxCompletionRepairs,
    artifactCompletion: artifactCompletion,
    completionGuard: completionGuard,
    preflightTool: preflightTool,
    promptCompactionBudgetTokens: promptCompactionBudgetTokens,
    onEvent: events == null
        ? null
        : (event) {
            events.add(event);
          },
  );
}

void main() {
  test('discussion gate blocks model decisions and tools before readiness',
      () async {
    final model = _FakeModel();
    final fakeTool = _FakeTool();
    final task = _task(id: 'discussion-loop-gate');
    final state = WorkDiscussionState.initial(
      conversationId: task.groupId,
      requestRevision: 1,
      executorId: task.characterId,
      candidateCharacterIds: const ['worker'],
      participantCharacterIds: const ['worker'],
      deliverableContract: const <String, dynamic>{
        'deliverableType': 'document',
        'format': 'docx',
        'location': 'desktop',
        'contentScope': '完成任务',
        'explicitExecutorId': 'worker',
        'revisionTarget': '',
        'requestRevision': 1,
      },
    );
    task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
      '',
      state,
    );
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(
        definitions: [
          _definition(AgentToolName.workspaceRead, fakeTool),
        ],
      ),
    );

    final result = await loop.execute(task);

    expect(result.status, WorkAgentLoopStatus.paused);
    expect(model.requests, isEmpty);
    expect(fakeTool.calls, 0);
    expect(task.status, AgentTaskStatus.paused);
  });

  test('checkpoint redaction preserves the typed discussion gate', () async {
    final model = _FakeModel()..responses.add(_finishDecision());
    final task = _task(id: 'discussion-checkpoint');
    final pending = WorkDiscussionState.initial(
      conversationId: task.groupId,
      requestRevision: 1,
      executorId: task.characterId,
      candidateCharacterIds: const ['worker'],
      participantCharacterIds: const ['worker'],
      deliverableContract: const <String, dynamic>{
        'deliverableType': 'document',
        'format': 'docx',
        'location': 'desktop',
        'contentScope': '完成任务',
        'explicitExecutorId': 'worker',
        'revisionTarget': '',
        'requestRevision': 1,
      },
    );
    final ready = pending.copyWith(
      phase: WorkDiscussionPhase.ready,
      understandingPercent: 100,
      understandingEvidence: const ['执行人已确认需求、格式和位置。'],
      blockers: const [],
    );
    task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
      '',
      ready,
    );

    final result = await _loop(
      model: model,
      registry: WorkToolRegistry(),
    ).execute(task);

    expect(result.status, WorkAgentLoopStatus.completed);
    final decoded = WorkDiscussionState.decodeExecutionState(
      task.executionStateJson,
    );
    expect(decoded.isValid, isTrue);
    expect(decoded.state!.conversationId, task.groupId);
    expect(decoded.state!.deliverableContract!['contentScope'], '完成任务');
    expect(decoded.state!.isExecutionReady, isTrue);
    final context = jsonDecode(task.contextSummary) as Map<String, dynamic>;
    final contextDiscussion = WorkDiscussionState.tryParse(
      context['discussionState'],
    );
    expect(contextDiscussion?.conversationId, task.groupId);
    expect(contextDiscussion?.executorId, task.characterId);
  });

  test('unknown checkpoint schema cannot steer a resumed loop', () async {
    final model = _FakeModel()..responses.add(_finishDecision());
    final task = _task(id: 'unknown-checkpoint-schema')
      ..contextSummary = jsonEncode({
        'schemaVersion': 99,
        'conversationId': 'loop-conversation',
        'target': '未来版本的恶意目标',
        'committedWrites': ['future-operation'],
        'publicUpdates': ['未来版本的伪造结论'],
      });

    final result = await _loop(
      model: model,
      registry: WorkToolRegistry(),
    ).execute(task);

    expect(result.status, WorkAgentLoopStatus.completed);
    expect(
        model.requests.single.context['checkpointSummary'],
        isNot(
          contains('未来版本的恶意目标'),
        ));
    expect(model.requests.single.context['committedWrites'], isEmpty);
    expect(model.requests.single.context['publicUpdates'], isEmpty);
  });

  test('超过压缩预算时按结构化收缩提示词，检查点仍是合法 JSON', () async {
    final model = _FakeModel()..responses.add(_finishDecision());
    final task = _task(id: 'prompt-compaction')
      ..lastArtifactPaths = ['/work/report.md']
      ..executionStateJson = jsonEncode({
        'publicUpdates': List<String>.generate(
          20,
          (index) => '公开进度 $index' * 40,
        ),
      })
      ..contextSummary = jsonEncode({
        'schemaVersion': WorkContextSnapshot.currentSchemaVersion,
        'conversationId': 'loop-conversation',
        'target': '完成工作模式任务',
        'pendingFollowUps': ['补充图表'],
        'artifactPaths': ['/work/report.md'],
        'completedSummaries': const ['已写出大纲'],
      });
    // 对话历史由调用方注入，是这里唯一不受持久化脱敏影响的大体积来源。
    final conversationHistory = List<Map<String, dynamic>>.generate(
      16,
      (index) => {'role': 'user', 'content': '群聊消息 $index' * 200},
    );

    final result = await _loop(
      model: model,
      registry: WorkToolRegistry(),
      promptCompactionBudgetTokens: 1000,
    ).execute(task, conversationHistory: conversationHistory);

    expect(result.status, WorkAgentLoopStatus.completed);

    final request = model.requests.single;
    final checkpointMessage = request.messages.lastWhere(
      (message) => (message['content'] as String).startsWith('公开任务检查点：'),
    );
    final checkpoint = jsonDecode(
      (checkpointMessage['content'] as String)
          .substring('公开任务检查点：'.length),
    ) as Map<String, dynamic>;

    // 关键回归：收缩发生之后这段 JSON 仍能整体解析。改动前超长提示词是被
    // fitToTokenBudget 从中间插入裁剪标记的，同一段 JSON 会被剪成两半，
    // 模型拿到的检查点是残缺的。
    expect(checkpoint['goal'], '完成工作模式任务');
    // 确实收缩了：低价值字段被丢掉。
    expect(checkpoint['publicUpdates'], isEmpty);
    // 执行状态字段不参与收缩。
    expect(checkpoint['actionLimit'], isNotNull);
    expect(checkpoint['artifacts'], contains('/work/report.md'));
    // 收缩只影响发给模型的那一份，原始上下文不被就地改写。
    expect((request.context['publicUpdates'] as List), hasLength(20));
    expect(
      (request.context['conversationHistory'] as List),
      hasLength(16),
    );
  });

  test('current QA scope replaces a stale development target in checkpoint',
      () async {
    const qaScope = '只测试现有 HTML，并写入 doudizhu_test_report.md';
    final model = _FakeModel()..responses.add(_finishDecision());
    final task = _task()
      ..userRequest = '旧任务：开发 Desktop/doudizhu_game.html。新的 QA：$qaScope'
      ..contextSummary = jsonEncode({
        'schemaVersion': WorkContextSnapshot.currentSchemaVersion,
        'conversationId': 'loop-conversation',
        'target': '旧任务：开发 Desktop/doudizhu_game.html',
        'goal': '旧任务：开发 Desktop/doudizhu_game.html',
      });
    final discussion = WorkDiscussionState.initial(
      conversationId: task.groupId,
      requestRevision: 2,
      coordinatorId: 'coordinator',
      executorId: task.characterId,
      candidateCharacterIds: [task.characterId],
      participantCharacterIds: [task.characterId],
      deliverableContract: const <String, dynamic>{
        'deliverableType': 'document',
        'format': 'markdown',
        'location': 'doudizhu_test_report.md',
        'contentScope': qaScope,
        'explicitExecutorId': null,
        'revisionTarget': '',
        'requestRevision': 2,
      },
    ).copyWith(
      phase: WorkDiscussionPhase.ready,
      understandingPercent: 100,
      understandingEvidence: const ['QA 报告合同已确认。'],
      openQuestions: const [],
      blockers: const [],
    );
    task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
      '',
      discussion,
    );

    final result = await _loop(
      model: model,
      registry: WorkToolRegistry(),
    ).execute(task);

    expect(result.status, WorkAgentLoopStatus.completed);
    final context = model.requests.single.context;
    expect(context['goal'], qaScope);
    expect(context['checkpointSummary'], contains(qaScope));
    expect(
      context['checkpointSummary'],
      isNot(contains('旧任务：开发 Desktop/doudizhu_game.html')),
    );
  });

  test('unknown execution schema pauses without dropping typed blockers',
      () async {
    final model = _FakeModel()..responses.add(_finishDecision());
    final task = _task(id: 'unknown-execution-schema');
    final discussion = WorkDiscussionState(
      conversationId: task.groupId,
      phase: WorkDiscussionPhase.ready,
      requestRevision: 1,
      executorId: task.characterId,
      candidateCharacterIds: const ['worker'],
      participants: const [
        WorkDiscussionParticipant(characterId: 'worker'),
      ],
      round: 2,
      understandingPercent: 100,
      understandingEvidence: const ['已确认执行角色与交付合同。'],
      blockers: const [],
      deliverableContract: const {
        'deliverableType': 'document',
        'format': 'docx',
        'location': 'desktop',
        'contentScope': '完成任务',
        'explicitExecutorId': 'worker',
        'revisionTarget': '',
        'requestRevision': 1,
      },
    );
    task.executionStateJson = jsonEncode({
      'schemaVersion': 99,
      'discussionState': discussion.toJson(),
      'folderGrantPending': true,
      'folderRequestPath': '/workspace/project',
      'approvalDecision': 'approved',
    });

    final result = await _loop(
      model: model,
      registry: WorkToolRegistry(),
    ).execute(task);

    expect(result.status, WorkAgentLoopStatus.paused);
    expect(model.requests, isEmpty);
    final execution = jsonDecode(task.executionStateJson) as Map;
    expect(execution['schemaVersion'], 1);
    expect(execution['checkpointSchemaUnsupported'], isTrue);
    expect(execution['folderGrantPending'], isTrue);
    expect(execution['folderRequestPath'], '/workspace/project');
    expect(execution, isNot(contains('approvalDecision')));
    expect(
      WorkDiscussionState.fromExecutionState(task.executionStateJson)
          ?.isExecutionReady,
      isTrue,
    );
  });

  test('malformed execution checkpoint pauses before model execution',
      () async {
    final model = _FakeModel()..responses.add(_finishDecision());
    final task = _task(id: 'malformed-execution-checkpoint')
      ..executionStateJson = '{malformed execution checkpoint';

    final result = await _loop(
      model: model,
      registry: WorkToolRegistry(),
    ).execute(task);

    expect(result.status, WorkAgentLoopStatus.paused);
    expect(model.requests, isEmpty);
    final execution = jsonDecode(task.executionStateJson) as Map;
    expect(execution['schemaVersion'], 1);
    expect(execution['checkpointSchemaUnsupported'], isTrue);
  });

  test(
      'late loop calls cannot rewrite a terminal task through the discussion gate',
      () async {
    final model = _FakeModel();
    final task = _task(id: 'terminal-discussion-gate')
      ..status = AgentTaskStatus.completed
      ..resultSummary = '已完成。'
      ..executionStateJson = '{malformed discussion checkpoint';

    final result = await _loop(
      model: model,
      registry: WorkToolRegistry(),
    ).execute(task);

    expect(result.status, WorkAgentLoopStatus.completed);
    expect(result.message, '已完成。');
    expect(task.status, AgentTaskStatus.completed);
    expect(task.executionStateJson, '{malformed discussion checkpoint');
    expect(model.requests, isEmpty);
  });

  test('requires execution after a plan has been accepted', () async {
    final model = _FakeModel()
      ..responses.add(_planDecision())
      ..responses.add(_toolDecision())
      ..responses.add(_finishDecision());
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(
        definitions: [_definition(AgentToolName.workspaceRead, _FakeTool())],
      ),
    );

    final result = await loop.execute(_task(id: 'plan-then-execute'));

    expect(result.status, WorkAgentLoopStatus.completed);
    expect(model.requests, hasLength(3));
    final secondSystemMessage = model.requests[1].messages.firstWhere(
      (message) => message['role'] == 'system',
    );
    expect(
      secondSystemMessage['content'],
      contains('禁止再次返回 action=plan'),
    );
  });

  test('persists a durable marker when the model asks for clarification',
      () async {
    const question = '你要生成 PPTX 还是其他格式？';
    final model = _FakeModel()
      ..responses.add({
        'success': true,
        'content': jsonEncode({
          'action': 'clarify',
          'public_update': '需要先确认交付格式。',
          'tool': null,
          'completion': {
            'question': question,
            'options': ['PowerPoint（.pptx）', '其他格式'],
          },
        }),
      });
    final loop = _loop(model: model, registry: WorkToolRegistry());
    final task = _task(id: 'clarification-marker');

    final result = await loop.execute(task);

    expect(result.status, WorkAgentLoopStatus.paused);
    final execution = jsonDecode(task.executionStateJson) as Map;
    expect(execution['clarificationRequired'], isTrue);
    expect(execution['clarificationQuestion'], question);
  });

  test('runs a 20+ step trace, emits every step, then finish completes',
      () async {
    final model = _FakeModel();
    final tool = _FakeTool();
    final events = <WorkTaskEvent>[];
    final clock = _FakeClock();
    for (var index = 0; index < 21; index++) {
      model.responses.add(_toolDecision(path: 'notes-$index.txt'));
    }
    model.responses.add(_finishDecision());
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(
        definitions: [_definition(AgentToolName.workspaceRead, tool)],
      ),
      clock: clock,
      events: events,
    );

    final task = _task();
    final result = await loop.execute(task);

    expect(result.status, WorkAgentLoopStatus.completed);
    expect(task.status, AgentTaskStatus.completed);
    expect(task.actionCount, 43, reason: '模型决策和工具动作均计入步骤');
    expect(tool.calls, 21);
    expect(model.requests, hasLength(22));
    expect(
      events.where((event) => event.kind == WorkTaskEventKind.stepStarted),
      hasLength(22),
    );
    expect(
      events.where((event) => event.kind == WorkTaskEventKind.stepCompleted),
      hasLength(21),
    );
    expect(events.last.kind, WorkTaskEventKind.completed);
    expect(
      events
          .where((event) => event.kind != WorkTaskEventKind.stepStarted)
          .map((event) => event.safeMetadata['actionCount'])
          .whereType<int>(),
      everyElement(greaterThan(0)),
    );
    expect(task.contextSummary, isNot(contains('chain-of-thought')));
  });

  test('retries transient model failures with named bounded policy', () async {
    final model = _FakeModel()
      ..responses.add({
        'success': false,
        'statusCode': 503,
        'message': '服务暂时不可用',
      })
      ..responses.add(_finishDecision());
    final delays = <Duration>[];
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(),
      maxModelRetries: 1,
      sleep: (delay) async => delays.add(delay),
    );

    final result = await loop.execute(_task(id: 'model-retry'));

    expect(result.status, WorkAgentLoopStatus.completed);
    expect(model.requests, hasLength(2));
    expect(delays, [WorkAgentLoop.defaultRetryDelays[0]]);
    expect(result.retryCount, 1);
  });

  test('uses the extended model retry budget across a growing backoff',
      () async {
    // 退避阶梯必须覆盖全部重试次数：阶梯短于预算时，末尾延迟会被重复使用，
    // 那次重试就等于没有更长的等待。
    final model = _FakeModel();
    for (var attempt = 0;
        attempt < WorkAgentLoop.defaultMaxModelRetries;
        attempt++) {
      model.responses.add({
        'success': false,
        'statusCode': 503,
        'message': '服务暂时不可用',
      });
    }
    model.responses.add(_finishDecision());
    final delays = <Duration>[];
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(),
      sleep: (delay) async => delays.add(delay),
    );

    final result = await loop.execute(_task(id: 'model-retry-budget'));

    expect(result.status, WorkAgentLoopStatus.completed);
    expect(result.modelRetryCount, WorkAgentLoop.defaultMaxModelRetries);
    expect(delays, WorkAgentLoop.defaultRetryDelays);
    expect(delays.last, const Duration(seconds: 8));
  });

  test('honors Retry-After and jitters ordinary model backoff', () async {
    final retryAfterModel = _FakeModel()
      ..responses.add({
        'success': false,
        'statusCode': 429,
        'retryAfterMs': 7000,
        'message': '请求过于频繁',
      })
      ..responses.add(_finishDecision());
    final retryAfterDelays = <Duration>[];
    final retryAfterLoop = _loop(
      model: retryAfterModel,
      registry: WorkToolRegistry(),
      maxModelRetries: 1,
      retryJitter: () => 1,
      sleep: (delay) async => retryAfterDelays.add(delay),
    );

    final retryAfterResult = await retryAfterLoop.execute(
      _task(id: 'model-retry-after'),
    );

    expect(retryAfterResult.status, WorkAgentLoopStatus.completed);
    expect(retryAfterDelays, [const Duration(seconds: 7)]);

    final jitterModel = _FakeModel()
      ..responses.add({
        'success': false,
        'statusCode': 503,
        'message': '服务暂时不可用',
      })
      ..responses.add(_finishDecision());
    final jitterDelays = <Duration>[];
    final jitterLoop = _loop(
      model: jitterModel,
      registry: WorkToolRegistry(),
      maxModelRetries: 1,
      retryJitter: () => 1,
      sleep: (delay) async => jitterDelays.add(delay),
    );

    final jitterResult = await jitterLoop.execute(
      _task(id: 'model-retry-jitter'),
    );

    expect(jitterResult.status, WorkAgentLoopStatus.completed);
    expect(jitterDelays, [const Duration(milliseconds: 300)]);
  });

  test('feeds completion guard failures back to the next model decision',
      () async {
    final model = _FakeModel()
      ..responses.add(_finishDecision('第一次完成'))
      ..responses.add(_finishDecision('修复后完成'));
    var guardCalls = 0;
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(),
      completionGuard: (_, __) {
        guardCalls++;
        return guardCalls == 1 ? '用户要求 xlsx 文件，但尚未生成真实文件。' : null;
      },
    );

    final task = _task(id: 'completion-guard-repair');
    final result = await loop.execute(task);

    expect(result.status, WorkAgentLoopStatus.completed);
    expect(task.status, AgentTaskStatus.completed);
    expect(model.requests, hasLength(2));
    expect(
      model.requests[1].context['previousCompletionFailure'],
      contains('尚未生成真实文件'),
    );
    expect(guardCalls, 2);
  });

  test('a successful tool call restores the completion repair budget',
      () async {
    final model = _FakeModel()
      ..responses.add(_finishDecision('第一次完成'))
      ..responses.add(_toolDecision(name: AgentToolName.workspaceRead))
      ..responses.add(_finishDecision('第二次完成'))
      ..responses.add(_finishDecision('第三次完成'));
    final tool = _FakeTool()
      ..behavior = (_) => const WorkToolResult.success(message: '读取成功');
    var guardCalls = 0;
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(
        definitions: [_definition(AgentToolName.workspaceRead, tool)],
      ),
      maxCompletionRepairs: 1,
      completionGuard: (_, __) {
        guardCalls++;
        // 前两次未通过，而第 2 次紧跟在一次成功的工具调用之后：那次成功必须把
        // 预算归零，否则第 2 次就已经超预算、任务会被直接判失败。
        return guardCalls <= 2 ? '尚未生成真实文件。' : null;
      },
    );

    final result = await loop.execute(_task(id: 'completion-repair-reset'));

    expect(result.status, WorkAgentLoopStatus.completed);
    expect(guardCalls, 3);
    expect(tool.calls, 1);
    // finish / tool / finish / finish：失败后各要一次新决策，最后一次通过。
    expect(model.requests, hasLength(4));
  });

  test('a persistently failing completion guard fails after its repair budget',
      () async {
    final model = _FakeModel()
      ..responses.add(_finishDecision('第一次完成'))
      ..responses.add(_finishDecision('第二次完成'))
      ..responses.add(_finishDecision('第三次完成'));
    var guardCalls = 0;
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(),
      maxCompletionRepairs: 2,
      completionGuard: (_, __) {
        guardCalls++;
        return '用户要求 xlsx 文件，但尚未生成真实文件。';
      },
    );

    final result = await loop.execute(_task(id: 'completion-repair-exhaust'));

    expect(result.status, WorkAgentLoopStatus.failed);
    expect(result.failure?.reason, contains('尚未生成真实文件'));
    expect(guardCalls, 3, reason: '首次 + 两次修复，之后必须判失败而不是继续循环');
    expect(model.requests, hasLength(3));
  });

  test('completion repairs restart after every successful tool call', () async {
    // 预算是按进展分段的：每次成功的工具调用都会重置，所以整轮可以修 3 次以上
    // （示例为 3 次），最终由 100 步动作上限兜底，而不是整轮只修 2 次。
    final model = _FakeModel()
      ..responses.add(_finishDecision('第一次完成'))
      ..responses.add(_toolDecision(name: AgentToolName.workspaceRead))
      ..responses.add(_finishDecision('第二次完成'))
      ..responses.add(_toolDecision(name: AgentToolName.workspaceRead))
      ..responses.add(_finishDecision('第三次完成'))
      ..responses.add(_finishDecision('第四次完成'));
    final tool = _FakeTool()
      ..behavior = (_) => const WorkToolResult.success(message: '读取成功');
    var guardCalls = 0;
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(
        definitions: [_definition(AgentToolName.workspaceRead, tool)],
      ),
      completionGuard: (_, __) {
        guardCalls++;
        return guardCalls <= 3 ? '尚未生成真实文件。' : null;
      },
    );

    final result = await loop.execute(_task(id: 'completion-repair-cycles'));

    expect(result.status, WorkAgentLoopStatus.completed);
    expect(guardCalls, 4);
    expect(tool.calls, 2);
    expect(model.requests, hasLength(6));
  });

  test('retries an empty model completion from the latest checkpoint',
      () async {
    final model = _FakeModel()
      ..responses.add({
        'success': false,
        'failureCode': 'emptyResponse',
        'message': '模型返回了空内容',
      })
      ..responses.add(_finishDecision());
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(),
      maxModelRetries: 1,
    );

    final result = await loop.execute(_task(id: 'empty-model-retry'));

    expect(result.status, WorkAgentLoopStatus.completed);
    expect(model.requests, hasLength(2));
    expect(result.modelRetryCount, 1);
  });

  test('pauses instead of failing when a model retry reaches the action limit',
      () async {
    final model = _FakeModel()
      ..responses.add({
        'success': false,
        'statusCode': 503,
        'message': '服务暂时不可用',
      });
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(),
      maxModelRetries: 1,
    );

    final task = _task(id: 'model-retry-action-limit', actionLimit: 1);
    final result = await loop.execute(task);

    expect(result.status, WorkAgentLoopStatus.paused);
    expect(task.status, AgentTaskStatus.paused);
    expect(task.softLimitReached, isTrue);
    expect(task.lastError, contains('软上限'));
    expect(model.requests, hasLength(1));
  });

  test('retries a transient tool failure once without double-counting action',
      () async {
    final model = _FakeModel()
      ..responses.add(_toolDecision())
      ..responses.add(_finishDecision());
    final tool = _FakeTool();
    var first = true;
    tool.behavior = (_) {
      if (first) {
        first = false;
        return const WorkToolResult.retryableFailure(message: '网络暂时失败');
      }
      return const WorkToolResult.success(message: '读取成功');
    };
    final delays = <Duration>[];
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(
        definitions: [_definition(AgentToolName.workspaceRead, tool)],
      ),
      maxToolRetries: 1,
      sleep: (delay) async => delays.add(delay),
    );

    final task = _task(id: 'tool-retry');
    final result = await loop.execute(task);

    expect(result.status, WorkAgentLoopStatus.completed);
    expect(tool.calls, 2);
    expect(task.actionCount, 3, reason: '重试共享工具动作但模型决策也计步');
    expect(delays, [WorkAgentLoop.defaultRetryDelays[0]]);
  });

  test('replans a failed command from diagnostics before surfacing failure',
      () async {
    final model = _FakeModel()
      ..responses.add(_toolDecision())
      ..responses.add(_toolDecision(update: '已根据错误修正命令，继续生成。'))
      ..responses.add(_finishDecision());
    final tool = _FakeTool();
    var calls = 0;
    tool.behavior = (_) {
      calls++;
      if (calls == 1) {
        return const WorkToolResult.failed(
          message: '命令退出码为 47。',
          data: {
            'runStatus': 'failed',
            'stderr': "'pdflatex' not found",
          },
          failureCode: 'commandFailed',
        );
      }
      return const WorkToolResult.success(message: 'PDF 已生成。');
    };
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(
        definitions: [_definition(AgentToolName.workspaceRead, tool)],
      ),
    );

    final task = _task(id: 'command-diagnostic-repair');
    final result = await loop.execute(task);

    expect(result.status, WorkAgentLoopStatus.completed);
    expect(calls, 2);
    expect(model.requests, hasLength(3));
    expect(
      model.requests[1].messages.map((message) => message['content']).join(),
      contains("'pdflatex' not found"),
    );
    expect(task.executionStateJson, contains('commandFailureKeys'));
  });

  test('continues command repair beyond two failures until command succeeds',
      () async {
    final model = _FakeModel()
      ..responses.add(_toolDecision(path: 'attempt-1.txt'))
      ..responses.add(_toolDecision(path: 'attempt-2.txt'))
      ..responses.add(_toolDecision(path: 'attempt-3.txt'))
      ..responses.add(_toolDecision(path: 'attempt-4.txt'))
      ..responses.add(_finishDecision());
    final tool = _FakeTool();
    var calls = 0;
    tool.behavior = (_) {
      calls++;
      if (calls < 4) {
        return WorkToolResult.failed(
          message: '命令退出码为 1。',
          data: {
            'runStatus': 'failed',
            'stderr': '第 $calls 次诊断仍待修复',
          },
          failureCode: 'commandFailed',
        );
      }
      return const WorkToolResult.success(message: '命令已修复并完成。');
    };
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(
        definitions: [_definition(AgentToolName.workspaceRead, tool)],
      ),
    );

    final task = _task(id: 'command-repair-beyond-two');
    final result = await loop.execute(task);

    expect(result.status, WorkAgentLoopStatus.completed);
    expect(tool.calls, 4, reason: '自动修复不应被固定为两次');
    expect(model.requests, hasLength(5));
  });

  test('pauses when a repaired command keeps failing with the same error',
      () async {
    // 回归：模型每次“修复”都改写了命令文本，但进程错误完全没变。旧指纹包含
    // 整条命令，所以每次都算“新失败”，循环检测永不触发，一次任务因此空转
    // 十几步。现在只要退出码 + stderr 末行相同，修复一次后即暂停。
    final model = _FakeModel()
      ..responses.add(_toolDecision(path: 'v1.py'))
      ..responses.add(_toolDecision(path: 'v2.py'))
      ..responses.add(_toolDecision(path: 'v3.py'))
      ..responses.add(_finishDecision());
    final tool = _FakeTool()
      ..behavior = (_) => const WorkToolResult.failed(
            message: '命令退出码为 1。',
            data: {
              'runStatus': 'failed',
              'exitCode': 1,
              'stderr': 'Traceback (most recent call last):\n'
                  '  File "v1.py", line 3\n'
                  "NameError: name 'rank' is not defined",
            },
            failureCode: 'commandFailed',
          );
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(
        definitions: [_definition(AgentToolName.workspaceRead, tool)],
      ),
    );

    final task = _task(id: 'command-repaired-same-outcome');
    final result = await loop.execute(task);

    expect(result.status, WorkAgentLoopStatus.paused);
    expect(result.message, contains('自动修复没有取得进展'));
    expect(tool.calls, 2, reason: '同一错误只允许一次诚实的修复尝试');
    expect(task.lastError, contains('自动修复没有取得进展'));
  });

  test('continues when the repaired command produces a new error', () async {
    // 反向：末行错误确实变化时，说明修复在推进，必须继续自动修复。
    final model = _FakeModel()
      ..responses.add(_toolDecision(path: 'v1.py'))
      ..responses.add(_toolDecision(path: 'v2.py'))
      ..responses.add(_toolDecision(path: 'v3.py'))
      ..responses.add(_finishDecision());
    final tool = _FakeTool();
    var calls = 0;
    tool.behavior = (_) {
      calls++;
      if (calls >= 3) {
        return const WorkToolResult.success(message: '脚本执行成功。');
      }
      return WorkToolResult.failed(
        message: '命令退出码为 1。',
        data: {
          'runStatus': 'failed',
          'exitCode': 1,
          'stderr': 'Traceback (most recent call last):\n'
              "NameError: name 'step$calls' is not defined",
        },
        failureCode: 'commandFailed',
      );
    };
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(
        definitions: [_definition(AgentToolName.workspaceRead, tool)],
      ),
    );

    final result = await loop.execute(_task(id: 'command-new-outcome'));

    expect(result.status, WorkAgentLoopStatus.completed);
    expect(tool.calls, 3);
  });

  test('continues command repair after a timeout', () async {
    final model = _FakeModel()
      ..responses.add(_toolDecision())
      ..responses.add(_toolDecision(update: '已调整超时命令，继续执行。'))
      ..responses.add(_finishDecision());
    final tool = _FakeTool();
    var calls = 0;
    tool.behavior = (_) {
      calls++;
      if (calls == 1) {
        return const WorkToolResult.failed(
          message: '命令执行超时。',
          data: {'runStatus': 'timedOut'},
          failureCode: 'commandFailed',
        );
      }
      return const WorkToolResult.success(message: '命令已完成。');
    };
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(
        definitions: [_definition(AgentToolName.workspaceRead, tool)],
      ),
    );

    final result = await loop.execute(_task(id: 'command-timeout-repair'));

    expect(result.status, WorkAgentLoopStatus.completed);
    expect(tool.calls, 2);
    expect(model.requests, hasLength(3));
  });

  test('pauses when command repair repeats the same failure without progress',
      () async {
    final model = _FakeModel()
      ..responses.add(_toolDecision())
      ..responses.add(_toolDecision())
      ..responses.add(_toolDecision());
    final tool = _FakeTool()
      ..behavior = (_) => const WorkToolResult.failed(
            message: '命令退出码为 1。',
            data: {
              'runStatus': 'failed',
              'stderr': '相同错误：没有取得进展',
            },
            failureCode: 'commandFailed',
          );
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(
        definitions: [_definition(AgentToolName.workspaceRead, tool)],
      ),
    );

    final task = _task(id: 'command-repair-loop');
    final result = await loop.execute(task);

    expect(result.status, WorkAgentLoopStatus.paused);
    expect(tool.calls, 2);
    expect(model.requests, hasLength(2));
    expect(task.status, AgentTaskStatus.paused);
    expect(task.resumeRequired, isTrue);
    expect(task.lastError, contains('反复出现'));
  });

  test('pauses command failures that require permission', () async {
    final model = _FakeModel()..responses.add(_toolDecision());
    final tool = _FakeTool()
      ..behavior = (_) => const WorkToolResult.failed(
            message: '命令退出码为 1。',
            data: {
              'runStatus': 'failed',
              'stderr': 'operation not permitted',
            },
            failureCode: 'commandFailed',
          );
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(
        definitions: [_definition(AgentToolName.workspaceRead, tool)],
      ),
    );

    final result = await loop.execute(_task(id: 'command-permission'));

    expect(result.status, WorkAgentLoopStatus.paused);
    expect(tool.calls, 1);
    expect(model.requests, hasLength(1));
  });

  test('permission and path failures are not retried', () async {
    for (final failure in <WorkToolResult>[
      const WorkToolResult.permissionDenied(message: '没有权限'),
      const WorkToolResult.pathRejected(message: '路径越界'),
    ]) {
      final model = _FakeModel()..responses.add(_toolDecision());
      final tool = _FakeTool()..behavior = (_) => failure;
      final loop = _loop(
        model: model,
        registry: WorkToolRegistry(
          definitions: [_definition(AgentToolName.workspaceRead, tool)],
        ),
        maxToolRetries: 3,
      );

      final result = await loop.execute(_task(id: failure.status.name));

      expect(tool.calls, 1);
      expect(result.retryCount, 0);
      expect(
          result.status,
          failure.status == WorkToolResultStatus.permissionDenied
              ? WorkAgentLoopStatus.paused
              : WorkAgentLoopStatus.failed);
      expect(
        result.actionCount,
        1,
        reason: '权限或路径门禁未启动真实工具，不应消耗工具动作步数',
      );
    }
  });

  test('hands a non-command tool failure back to the model for repair',
      () async {
    final model = _FakeModel()
      ..responses.add(_toolDecision(name: AgentToolName.workspaceRead))
      ..responses.add(_finishDecision('已改用可用的读取方式。'));
    final tool = _FakeTool()
      ..behavior = (_) => const WorkToolResult.failed(
            message: '文档解析失败',
            failureCode: 'documentParseFailed',
          );
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(
        definitions: [_definition(AgentToolName.workspaceRead, tool)],
      ),
    );

    final result = await loop.execute(_task(id: 'tool-repair'));

    expect(tool.calls, 1);
    expect(model.requests, hasLength(2));
    expect(
      model.requests[1].context['previousToolFailure'],
      contains('文档解析失败'),
    );
    expect(result.status, WorkAgentLoopStatus.completed);
    expect(result.retryCount, 0);
  });

  test('pauses when a non-command tool failure repeats without progress',
      () async {
    final model = _FakeModel()
      ..responses.add(_toolDecision(name: AgentToolName.workspaceRead))
      ..responses.add(_toolDecision(name: AgentToolName.workspaceRead));
    final tool = _FakeTool()
      ..behavior = (_) => const WorkToolResult.failed(
            message: '文档解析失败',
            failureCode: 'documentParseFailed',
          );
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(
        definitions: [_definition(AgentToolName.workspaceRead, tool)],
      ),
    );

    final result = await loop.execute(_task(id: 'tool-repair-repeat'));

    expect(tool.calls, 2);
    expect(result.status, WorkAgentLoopStatus.paused);
  });

  test('pauses after the tool repair budget instead of failing the task',
      () async {
    // 每次失败文案都不同，指纹与结果签名都不重复，只有修复预算能兜住这种
    // 「每次看起来都是新错误」的漂移。
    var attempt = 0;
    final model = _FakeModel()
      ..responses.add(_toolDecision(name: AgentToolName.workspaceRead))
      ..responses.add(_toolDecision(name: AgentToolName.workspaceRead))
      ..responses.add(_toolDecision(name: AgentToolName.workspaceRead));
    final tool = _FakeTool()
      ..behavior = (_) => WorkToolResult.failed(
            message: '文档解析失败 ${++attempt}',
            failureCode: 'documentParseFailed',
          );
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(
        definitions: [_definition(AgentToolName.workspaceRead, tool)],
      ),
      maxToolRepairs: 2,
    );

    final result = await loop.execute(_task(id: 'tool-repair-budget'));

    expect(tool.calls, 3);
    expect(result.status, WorkAgentLoopStatus.paused);
  });

  test('a rejected mutation is a safe no-op, never a committed artifact',
      () async {
    final model = _FakeModel()
      ..responses.add(_toolDecision(name: AgentToolName.workspacePatch))
      ..responses.add(_finishDecision('已按用户决定停止写入。'));
    final tool = _FakeTool();
    final registry = WorkToolRegistry(
      definitions: [
        _definition(
          AgentToolName.workspacePatch,
          tool,
          access: WorkToolAccess.mutation,
          pipeline: WorkToolMutationPipeline(
            approval: (_) => const WorkToolResult.success(
              message: '用户拒绝了该变更，未写入文件。',
              data: {'rejected': true},
            ),
          ),
        ),
      ],
    );

    final task = _task(id: 'rejected-mutation');
    final result = await _loop(model: model, registry: registry).execute(task);

    expect(result.status, WorkAgentLoopStatus.completed);
    expect(tool.calls, 0);
    expect(task.lastArtifactPaths, isEmpty);
    expect(task.executionStateJson, contains('"committedActionKeys":[]'));
    expect(task.contextSummary, contains('"committed":false'));
    expect(task.contextSummary, isNot(contains('"committed":true')));
  });

  test('does not reuse a completed mutation approval for the next tool',
      () async {
    final model = _FakeModel()
      ..responses.add(_toolDecision(
        name: AgentToolName.skillDownload,
        arguments: {'templateId': 'frontend.interactive-artifact'},
      ))
      ..responses.add(_toolDecision(name: AgentToolName.workspacePatch))
      ..responses.add(_finishDecision());
    final skillTool = _FakeTool();
    final fileTool = _FakeTool();
    final task = _task(id: 'approval-cannot-leak-between-tools')
      ..executionStateJson = jsonEncode({
        'approvalDecision': 'approvedWithoutUndo',
        'approvalCapability': 'mutation',
      });
    final registry = WorkToolRegistry(
      definitions: [
        _definition(
          AgentToolName.skillDownload,
          skillTool,
          access: WorkToolAccess.mutation,
          pipeline: _recordingPipeline(<String>[]),
          skillDownload: true,
        ),
        _definition(
          AgentToolName.workspacePatch,
          fileTool,
          access: WorkToolAccess.mutation,
          pipeline: WorkToolMutationPipeline(
            policy: (invocation) {
              final execution = jsonDecode(
                invocation.task.executionStateJson,
              ) as Map<String, dynamic>;
              if (execution['approvalDecision'] != null) {
                return const WorkToolResult.failed(
                  message: '旧审批不应继续授权新的文件变更。',
                  failureCode: 'notApproved',
                );
              }
              return null;
            },
          ),
        ),
      ],
    );

    final result = await _loop(model: model, registry: registry).execute(task);

    expect(result.status, WorkAgentLoopStatus.completed);
    expect(skillTool.calls, 1);
    expect(fileTool.calls, 1);
    final execution = jsonDecode(task.executionStateJson) as Map;
    expect(execution, isNot(contains('approvalDecision')));
  });

  test('an unchanged mutation replans once and then pauses without success',
      () async {
    final model = _FakeModel()
      ..responses.add(_toolDecision(name: AgentToolName.workspacePatch))
      ..responses.add(_toolDecision(name: AgentToolName.workspacePatch));
    final tool = _FakeTool()
      ..behavior = (_) => const WorkToolResult.success(
            message: '目标文件内容未发生变化，未执行写入。',
            data: {'changed': false},
          );
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(
        definitions: [
          _definition(
            AgentToolName.workspacePatch,
            tool,
            access: WorkToolAccess.mutation,
            pipeline: _recordingPipeline(<String>[]),
          ),
        ],
      ),
    );

    final task = _task(id: 'unchanged-mutation');
    final result = await loop.execute(task);

    expect(result.status, WorkAgentLoopStatus.paused,
        reason: '${result.message}; ${task.lastError}');
    expect(task.status, AgentTaskStatus.paused,
        reason: '${result.message}; ${task.lastError}');
    expect(task.lastError, contains('没有实际变化'));
    expect(task.completedOperations, isEmpty);
    expect(task.lastArtifactPaths, isEmpty);
    expect(tool.calls, 2);
  });

  test('unchanged mutation guard persists across soft-limit continuations',
      () async {
    final model = _FakeModel()
      ..responses.add(_toolDecision(name: AgentToolName.workspacePatch))
      ..responses.add(_toolDecision(name: AgentToolName.workspacePatch));
    final tool = _FakeTool()
      ..behavior = (_) => const WorkToolResult.success(
            message: '目标文件内容未发生变化，未执行写入。',
            data: {'changed': false},
          );
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(
        definitions: [
          _definition(
            AgentToolName.workspacePatch,
            tool,
            access: WorkToolAccess.mutation,
            pipeline: _recordingPipeline(<String>[]),
          ),
        ],
      ),
      clock: _FakeClock(DateTime.utc(2026, 8, 31, 9)),
    );
    final task = _task(id: 'unchanged-mutation-across-runs', actionLimit: 2);

    final first = await loop.execute(task);
    expect(first.status, WorkAgentLoopStatus.paused);
    expect(task.lastError, contains('动作上限'));
    expect(
      (jsonDecode(task.executionStateJson) as Map)['unchangedMutationCount'],
      1,
    );

    task
      ..actionCount = 0
      ..softLimitReached = false
      ..status = AgentTaskStatus.queued
      ..resumeRequired = false
      ..startedAt = DateTime.utc(2026, 8, 31, 9);
    final second = await loop.execute(task);

    expect(second.status, WorkAgentLoopStatus.paused);
    expect(task.lastError, contains('没有实际变化'));
    expect(tool.calls, 2);
    expect(
      (jsonDecode(task.executionStateJson) as Map)['unchangedMutationCount'],
      2,
    );
  });

  test('a verified artifact can finish without a second model decision',
      () async {
    final model = _FakeModel()
      ..responses.add(_toolDecision(name: AgentToolName.workspacePatch));
    final tool = _FakeTool()
      ..behavior = (_) => const WorkToolResult.success(
            message: '文件已写入。',
            data: {
              'path': '/workspace/page.html',
              'changed': true,
              'beforeSha256': 'before',
              'afterSha256': 'after',
            },
          );
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(
        definitions: [
          _definition(
            AgentToolName.workspacePatch,
            tool,
            access: WorkToolAccess.mutation,
            pipeline: _recordingPipeline(<String>[]),
          ),
        ],
      ),
      artifactCompletion: (_, __, ___) => const AgentFinishCompletion(
        summary: '已验证文件。',
      ),
    );

    final task = _task(id: 'auto-artifact-finish');
    final result = await loop.execute(task);

    expect(result.status, WorkAgentLoopStatus.completed,
        reason: '${result.message}; ${task.lastError}');
    expect(model.requests, hasLength(1));
    expect(tool.calls, 1);
  });

  test('skill preflight runs before the first model decision', () async {
    final model = _FakeModel()..responses.add(_finishDecision());
    final tool = _FakeTool();
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(
        definitions: [
          _definition(
            AgentToolName.skillDownload,
            tool,
            access: WorkToolAccess.mutation,
            pipeline: _recordingPipeline(<String>[]),
            skillDownload: true,
          ),
        ],
      ),
      preflightTool: (_) => const AgentToolCall(
        name: AgentToolName.skillDownload,
        arguments: {'templateId': 'frontend.interactive-artifact'},
      ),
    );

    final task = _task(id: 'skill-preflight');
    final result = await loop.execute(task);

    expect(result.status, WorkAgentLoopStatus.completed,
        reason: '${result.message}; ${task.lastError}');
    expect(tool.calls, 1);
    expect(model.requests, hasLength(1));
    expect(
        tool.arguments.single['templateId'], 'frontend.interactive-artifact');
  });

  test('protocol repair is attempted once and never exposes raw response',
      () async {
    final model = _FakeModel()
      ..responses.add({
        'success': true,
        'content': '不是 JSON，也不是公开进度。',
      })
      ..responses.add(_toolDecision())
      ..responses.add(_finishDecision());
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(
        definitions: [_definition(AgentToolName.workspaceRead, _FakeTool())],
      ),
    );

    final task = _task(id: 'repair-once');
    final result = await loop.execute(task);

    expect(result.status, WorkAgentLoopStatus.completed);
    expect(result.protocolRepairAttempts, 1);
    expect(model.requests.where((request) => request.isRepair), hasLength(1));
    final repairPrompt = model.requests
        .firstWhere((request) => request.isRepair)
        .messages
        .map((message) => message['content']?.toString() ?? '')
        .join('\n');
    expect(repairPrompt, contains('command.run'));
    expect(repairPrompt, contains('arguments 必须是 JSON 字符串数组'));
    expect(task.contextSummary, isNot(contains('不是 JSON')));
  });

  test(
      'truncated response is repaired with a compact instruction, not the raw body',
      () async {
    // 模型把输出预算烧在重复内容上时（实测 8192 token），原文对修复毫无价值，
    // 回灌还会把 prompt 从 3902 撑到 10968 token。这里锁定它被换成精简指令。
    const repeated = '陆教授：好的，我先把完整的量子力学研究报告 Markdown 源文件写到桌面。';
    final model = _FakeModel()
      ..responses.add({
        'success': true,
        'content': repeated,
        'truncated': true,
      })
      ..responses.add(_finishDecision('截断后按精简指令完成。'));
    final loop = _loop(model: model, registry: WorkToolRegistry());

    final task = _task(id: 'truncated-repair');
    final result = await loop.execute(task);

    expect(result.status, WorkAgentLoopStatus.completed,
        reason: '${result.message}; ${task.lastError}');
    final repair = model.requests.firstWhere((request) => request.isRepair);
    expect(repair.malformedResponse, isNull);
    final repairPrompt = repair.messages
        .map((message) => message['content']?.toString() ?? '')
        .join('\n');
    expect(repairPrompt, contains('输出上限'));
    // 只要求"输出合法 JSON"没有用：被截断的正是"一次写完整份文件"这个动作，
    // 修复指令必须把策略换成"分块写"，否则模型原样重试还会再撞一次上限。
    expect(repairPrompt, contains('拆成多次动作'));
    // 合并只写纯文本：分块指令必须说明"先合并成 Markdown 源、需要 DOCX 时再
    // 转换"，否则要 Word 的任务会把合并目标直接写成 .docx，得到改了名的文本。
    expect(repairPrompt, contains('pandoc'));
    expect(repairPrompt, isNot(contains(repeated)));
  });

  test('a truncation that survives repair retries with a chunking instruction',
      () async {
    final model = _FakeModel()
      ..responses.add({
        'success': true,
        'content': '陆教授：我先把完整的量子力学研究报告写到桌面',
        'truncated': true,
      })
      ..responses.add({
        'success': true,
        'content': '还是被截断了',
        'truncated': true,
      })
      ..responses.add(_finishDecision('按分块指令完成。'));
    final loop = _loop(model: model, registry: WorkToolRegistry());

    final task = _task(id: 'truncation-chunking-retry');
    final result = await loop.execute(task);

    expect(result.status, WorkAgentLoopStatus.completed,
        reason: '${result.message}; ${task.lastError}');
    // 第三次请求是"截断后的协议重试"（不是修复请求）：它必须带上分块指令。
    expect(model.requests.length, greaterThanOrEqualTo(3));
    final retry = model.requests[2];
    expect(retry.isRepair, isFalse);
    final retryPrompt = retry.messages
        .map((message) => message['content']?.toString() ?? '')
        .join('\n');
    expect(retryPrompt, contains('拆成多次动作'));
  });

  test('a truncated write action is salvaged into a staged part file',
      () async {
    final model = _FakeModel()
      ..responses.add({
        'success': true,
        'truncated': true,
        'content': '{"action":"tool","public_update":"正在写报告。","tool":'
            '{"name":"workspace.patch","arguments":{"path":"report.md",'
            '"content":"第一段\\n第二段',
      })
      // 截断的正文同样修不出 JSON：修复请求也失败之后才轮到抢救，所以这里必须
      // 再排一条非 JSON 的响应（否则修复那次就会拿 `_finishDecision` 直接收尾，
      // 抢救分支根本不会执行）。
      ..responses.add({
        'success': true,
        'content': '还是写坏的正文',
      })
      ..responses.add(_finishDecision('按抢救结果续写完成。'));
    final tool = _FakeTool();
    final events = <WorkTaskEvent>[];
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(
        definitions: [_patchDefinition(tool)],
      ),
      events: events,
    );

    final task = _task(id: 'truncation-salvage');
    final result = await loop.execute(task);

    expect(result.status, WorkAgentLoopStatus.completed,
        reason: '${result.message}; ${task.lastError}');
    expect(tool.calls, 1, reason: '抢救就是一次真实的工具请求');
    final args = tool.arguments.single;
    expect(args['path'], startsWith('report.rescue-'));
    // 落盘的必须是模型原本要写的字符，而不是带反斜杠的 JSON 字面量。
    expect(args['content'], '第一段\n第二段');
    // `append` 是"这次写还不是交付物的最终形态"的契约标记（`_artifactToolChanged`）：
    // 缺了它，暂存分段会立刻满足交付物契约，任务带着被截断的前缀 completed。
    expect(args['append'], isTrue,
        reason: '抢救写入不得被当成交付物已就绪');
    // `overwrite: false` 把"跨任务同名（哈希只由内容决定）时静默把同一段前缀接两遍"
    // 换成"放弃这次抢救、退回话术路径"：内容静默翻倍比少救一次危险得多。
    expect(args['overwrite'], isFalse,
        reason: '抢救写入必须拒绝覆盖已存在的同名分段');
    expect(
      events.any((event) => event.safeMetadata['salvagedCharacters'] != null),
      isTrue,
    );
    final retryPrompt = model.requests.last.messages
        .map((message) => message['content']?.toString() ?? '')
        .join('\n');
    // 钉"续写指令装上"必须用抢救提示独有的措辞：`committedActionKeys` 的操作键里
    // `path` 是明文，它经 `committedWrites` 进 context 时会带出 `report.rescue-…`，
    // 用文件名断言的话，把 `continuationHint` 整个摘掉这两条用例仍然会绿。
    expect(retryPrompt, contains('补写余下内容'),
        reason: '续写指令必须告诉模型往已抢救的分段文件接着写');
    expect(retryPrompt, contains('report.rescue-'),
        reason: '续写指令必须点名已抢救的分段文件');
  });

  test('a salvaged part file never satisfies the artifact contract', () async {
    // 抢救文件与目标同目录、同扩展名、内容非空、mtime 新鲜，因此"这次写是不是
    // 交付物"完全由 `append` 标记决定（生产判据见
    // `default_work_task_runner_delivery.dart` 的 `_artifactToolChanged`；该判据
    // 本身由 `default_work_task_runner_stage02_test.dart` 的
    // 'an append alone never satisfies the deliverable contract' 用真实 runner
    // 钉住）。这里盯住循环这一侧：抢救写入一旦被判成交付物已就绪，任务会在只写了
    // 一段残缺内容时 completed，摘要与交付附件都指向 `report.rescue-<hash>.md`。
    final model = _FakeModel()
      ..responses.add({
        'success': true,
        'truncated': true,
        'content': '{"action":"tool","tool":{"name":"workspace.patch",'
            '"arguments":{"path":"report.md","content":"被截断的正文',
      })
      ..responses.add({'success': true, 'content': '还是写坏的正文'})
      ..responses.add(_finishDecision('按续写指令补齐并交付。'));
    final tool = _FakeTool();
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(
        definitions: [_patchDefinition(tool)],
      ),
      // 生产契约判定的替身：`append` 写入不算"交付物已就绪"，其余成功的整文件写
      // 就算（回读校验由真实 runner 那条用例负责）。
      artifactCompletion: (task, call, result) {
        if (call.arguments['append'] == true) return null;
        final path = call.arguments['path']?.toString() ?? '';
        return AgentFinishCompletion(summary: '文件已写入并通过回读校验：$path。');
      },
    );

    final task = _task(id: 'truncation-salvage-contract');
    final result = await loop.execute(task);

    expect(result.status, WorkAgentLoopStatus.completed,
        reason: '${result.message}; ${task.lastError}');
    // 先钉行为：完成必须来自模型自己的 finish，而不是抢救写入触发的契约自动收尾。
    expect(task.resultSummary, isNot(contains('rescue-')),
        reason: '暂存分段不得成为被交付的产物：${task.resultSummary}');
    expect(task.resultSummary, contains('按续写指令补齐并交付'),
        reason: '任务不得因一次抢救写入就自动收尾：${task.resultSummary}');
    // 再钉机制：挡住自动收尾的就是这个标记。
    expect(tool.arguments.single['append'], isTrue,
        reason: '抢救写入必须带 append，否则会被判成交付物已就绪');
  });

  test('a salvaged part file never enters the artifact candidates', () async {
    // 救援分段与目标同目录、同扩展名、内容非空：一旦登记进产物历史，
    // `WorkArtifactDeliveryGuard.validateTask` 就会把它当交付候选，用户每次遭遇
    // 截断都会额外收到一个 `xxx.rescue-<hash>.md` 附件（设计 §6：分段不登记）。
    final model = _FakeModel()
      ..responses.add({
        'success': true,
        'truncated': true,
        'content': '{"action":"tool","tool":{"name":"workspace.patch",'
            '"arguments":{"path":"report.md","content":"被截断的正文',
      })
      ..responses.add({'success': true, 'content': '还是写坏的正文'})
      ..responses.add(_finishDecision('按续写指令补齐并交付。'));
    final tool = _FakeTool();
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(definitions: [_patchDefinition(tool)]),
    );

    final task = _task(id: 'truncation-salvage-artifact-paths');
    await loop.execute(task);

    expect(tool.calls, 1, reason: '抢救确实写过一次');
    expect(tool.arguments.single['append'], isTrue);
    expect(
      task.lastArtifactPaths.where((path) => path.contains('rescue-')),
      isEmpty,
      reason: '救援分段只是中转，不得成为交付候选：${task.lastArtifactPaths}',
    );
  });

  test('the continuation hint survives context compaction', () async {
    final model = _FakeModel()
      ..responses.add({
        'success': true,
        'truncated': true,
        'content': '{"action":"tool","tool":{"name":"workspace.patch",'
            '"arguments":{"path":"report.md","content":"被截断的正文',
      })
      ..responses.add({
        'success': true,
        'content': '还是写坏的正文',
      })
      ..responses.add(_finishDecision('完成。'));
    final tool = _FakeTool();
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(
        definitions: [_patchDefinition(tool)],
      ),
      promptCompactionBudgetTokens: 1,
    );

    final task = _task(id: 'truncation-salvage-compaction');
    // 先给出一段会被压缩丢掉的对话历史（预算 1 时 `conversationHistory` 只留最后
    // 两条），否则这条用例只在"压根没压缩"的世界里验证指令还在——续写指令混进
    // 检查点也一样能通过。
    final history = <Map<String, dynamic>>[
      for (var index = 0; index < 5; index++)
        {
          'role': 'user',
          'content': '压缩前的历史消息编号 $index，应当被丢掉。',
        },
    ];
    await loop.execute(task, conversationHistory: history);

    final retryPrompt = model.requests.last.messages
        .map((message) => message['content']?.toString() ?? '')
        .join('\n');
    expect(retryPrompt, isNot(contains('压缩前的历史消息编号 0')),
        reason: '压缩必须真的发生，否则这条用例证明不了什么');
    expect(retryPrompt, contains('压缩前的历史消息编号 4'),
        reason: '压缩只丢旧的，最近两条要留下');
    // 用抢救提示独有的措辞，而不是 `report.rescue-`：后者会经 `committedWrites`
    // 从操作键里漏进 context（`path` 是明文），摘掉 `continuationHint` 也照样绿。
    expect(retryPrompt, contains('已写入内容的结尾是'),
        reason: '检查点被压缩后续写指令仍必须到达模型');
  });

  test('a salvage write that needs approval pauses instead of failing',
      () async {
    // 抢救是一次真实的工具请求：它的审批必须按既有语义暂停任务，而不是被跳过。
    final model = _FakeModel()
      ..responses.add({
        'success': true,
        'truncated': true,
        'content': '{"action":"tool","tool":{"name":"workspace.patch",'
            '"arguments":{"path":"report.md","content":"第一段',
      })
      ..responses.add({'success': true, 'content': '还是写坏的正文'});
    final tool = _FakeTool();
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(
        definitions: [
          _definition(
            AgentToolName.workspacePatch,
            tool,
            access: WorkToolAccess.mutation,
            pipeline: WorkToolMutationPipeline(
              approval: (_) => const WorkToolResult.waitingForApproval(
                message: '需要用户批准',
              ),
            ),
          ),
        ],
      ),
    );

    final task = _task(id: 'truncation-salvage-approval');
    final result = await loop.execute(task);

    expect(result.status, WorkAgentLoopStatus.waitingForApproval);
    expect(tool.calls, 0);
    expect(task.pendingToolRequestJson, contains('report.rescue-'),
        reason: '等待审批的必须是抢救写入本身');
  });

  test('a failed salvage write does not fail the task', () async {
    // 抢救只是止损：派生路径被策略拒绝时，任务必须退回话术路径继续，而不是被
    // 这条补救动作判死（设计 §4.6）。
    final model = _FakeModel()
      ..responses.add({
        'success': true,
        'truncated': true,
        'content': '{"action":"tool","tool":{"name":"workspace.patch",'
            '"arguments":{"path":"report.md","content":"第一段',
      })
      ..responses.add({'success': true, 'content': '还是写坏的正文'})
      ..responses.add(_finishDecision('按分块指令完成。'));
    final tool = _FakeTool();
    final events = <WorkTaskEvent>[];
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(
        definitions: [
          _definition(
            AgentToolName.workspacePatch,
            tool,
            access: WorkToolAccess.mutation,
            pipeline: WorkToolMutationPipeline(
              policy: (_) => const WorkToolResult.pathRejected(
                message: '无法在授权目录内解析精确文件路径。',
              ),
            ),
          ),
        ],
      ),
      events: events,
    );

    final task = _task(id: 'truncation-salvage-rejected');
    final result = await loop.execute(task);

    expect(result.status, WorkAgentLoopStatus.completed,
        reason: '${result.message}; ${task.lastError}');
    expect(tool.calls, 0);
    final retryPrompt = model.requests.last.messages
        .map((message) => message['content']?.toString() ?? '')
        .join('\n');
    // 退回话术路径：不提"已抢救"，只给分块配方。
    expect(retryPrompt, contains('拆成多次动作'));
    expect(retryPrompt, isNot(contains('report.rescue-')));
    // 拨回终态撤不回 `_fail` 已落的那条「任务未完成。」，所以抢救失败那条事件必须
    // 自己把口径点明，免得用户把红色失败读成本任务的结局。
    final salvageEvent = events.lastWhere(
      (event) => event.safeMetadata['scope'] == 'truncationSalvage',
    );
    expect(salvageEvent.safeMetadata['salvaged'], isFalse);
    expect(salvageEvent.detail, contains('无法在授权目录内解析精确文件路径。'));
    expect(salvageEvent.detail, contains('任务未完成。'));
    expect(salvageEvent.detail, contains('可以忽略'));
  });

  test('a salvage rejected before its result is recorded invents no part file',
      () async {
    // 抢救写入可能连 handler 都没进就被 `registry.validate` 拒掉（合成参数不在
    // 工具 schema 里）。那条分支在把结果写进 `recentResults` **之前**就 `_fail`
    // 了：若照旧读 `recentResults.last`，读到的会是更早那次成功写入，于是发出一条
    // 点名根本不存在的分段文件的续写指令。
    final model = _FakeModel()
      ..responses.add(
        _toolDecision(name: AgentToolName.workspacePatch, path: 'notes.txt'),
      )
      ..responses.add({
        'success': true,
        'truncated': true,
        'content': '{"action":"tool","tool":{"name":"workspace.patch",'
            '"arguments":{"path":"report.md","content":"第一段',
      })
      ..responses.add({'success': true, 'content': '还是写坏的正文'})
      ..responses.add(_finishDecision('按分块指令完成。'));
    final tool = _FakeTool();
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(
        definitions: [
          WorkToolDefinition(
            name: AgentToolName.workspacePatch,
            access: WorkToolAccess.mutation,
            // 刻意不声明 `append`：合成的抢救参数会被 schema 拒绝。
            schema: const WorkToolSchema(
              fields: {
                'path': WorkToolValueType.string,
                'content': WorkToolValueType.string,
              },
              required: {'path'},
            ),
            handler: tool.call,
            mutationPipeline: _recordingPipeline(<String>[]),
          ),
        ],
      ),
    );

    final task = _task(id: 'truncation-salvage-invalid-args');
    final result = await loop.execute(task);

    expect(result.status, WorkAgentLoopStatus.completed,
        reason: '${result.message}; ${task.lastError}');
    expect(tool.calls, 1, reason: '只有模型自己那次写入进了 handler');
    final retryPrompt = model.requests.last.messages
        .map((message) => message['content']?.toString() ?? '')
        .join('\n');
    expect(retryPrompt, isNot(contains('report.rescue-')),
        reason: '抢救没落盘，不得点名一个不存在的分段文件');
    expect(retryPrompt, contains('拆成多次动作'));
  });

  test('a salvage that needs approval marks its source before the pause',
      () async {
    // 抢救的第一次几乎必然要审批（分段是新路径）。审批一弹，任务就带离循环，而用户
    // 面前只有一张普通的变更确认卡：`需要批准 workspace.patch：report.rescue-<hash>.md`
    // ——和"模型主动新建了一个陌生哈希名文件"完全同形。所以来源必须在弹审批之前
    // 就写进事件流（设计 §4.3）。
    final model = _FakeModel()
      ..responses.add({
        'success': true,
        'truncated': true,
        'content': '{"action":"tool","tool":{"name":"workspace.patch",'
            '"arguments":{"path":"report.md","content":"第一段',
      })
      ..responses.add({'success': true, 'content': '还是写坏的正文'});
    final tool = _FakeTool();
    final events = <WorkTaskEvent>[];
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(
        definitions: [
          _definition(
            AgentToolName.workspacePatch,
            tool,
            access: WorkToolAccess.mutation,
            pipeline: WorkToolMutationPipeline(
              approval: (_) => const WorkToolResult.waitingForApproval(
                message: '需要用户批准',
              ),
            ),
          ),
        ],
      ),
      events: events,
    );

    final task = _task(id: 'truncation-salvage-source-event');
    final result = await loop.execute(task);

    expect(result.status, WorkAgentLoopStatus.waitingForApproval);
    expect(tool.calls, 0, reason: '审批没过，写入还没发生');
    final announced = events
        .where((event) => event.safeMetadata['scope'] == 'truncationSalvage')
        .toList(growable: false);
    expect(announced, hasLength(1),
        reason: '审批之前只该有一条标明来源的事件：'
            '${events.map((event) => event.title).join(' | ')}');
    final source = announced.single;
    expect(source.title, contains('截断'));
    expect(source.title, contains('抢救'));
    expect(source.title, contains('3 字'), reason: '要说明救回多少字');
    expect(source.safeMetadata['partPath'], contains('report.rescue-'));
    expect(source.safeMetadata['truncatedTargetPath'], 'report.md');
    expect(source.safeMetadata['salvagedCharacters'], 3);
    expect(source.safeMetadata['truncated'], isTrue);
    expect(source.kind, WorkTaskEventKind.toolOutput);
  });

  test('a salvaged part file keeps its continuation hint across an approval pause',
      () async {
    // 抢救落盘要审批 → 任务暂停 → 用户批准 → 恢复运行，而 `execute` 会重新进入：
    // 续写指令若只活在循环局部变量里，这一刻就没了。模型于是只看到
    // `committedWrites` 里多了个 `report.rescue-<hash>.md`，没有"从这里接着写"的
    // 说明，大概率重吐全文、再撞上限、再抢救、再弹审批。
    var needsApproval = true;
    final model = _FakeModel()
      ..responses.add({
        'success': true,
        'truncated': true,
        'content': '{"action":"tool","tool":{"name":"workspace.patch",'
            '"arguments":{"path":"report.md","content":"第一段',
      })
      ..responses.add({'success': true, 'content': '还是写坏的正文'})
      ..responses.add(_finishDecision('按续写指令补齐并交付。'));
    final tool = _FakeTool();
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(
        definitions: [
          _definition(
            AgentToolName.workspacePatch,
            tool,
            access: WorkToolAccess.mutation,
            pipeline: WorkToolMutationPipeline(
              approval: (_) => needsApproval
                  ? const WorkToolResult.waitingForApproval(message: '需要用户批准')
                  : null,
            ),
          ),
        ],
      ),
    );

    final task = _task(id: 'truncation-salvage-resume-hint');
    final first = await loop.execute(task);

    expect(first.status, WorkAgentLoopStatus.waitingForApproval);
    expect(tool.calls, 0);
    expect(task.executionStateJson, contains('truncationSalvage'),
        reason: '运行态必须活过这次暂停，否则恢复后无从重建指令');

    // 用户批准：协调器把任务拨回 queued，并把同一个请求重放回循环。
    needsApproval = false;
    final pending = _resumeSalvageRequest(task);
    expect(pending.args['path'], contains('report.rescue-'));
    task
      ..status = AgentTaskStatus.queued
      ..resumeRequired = false;
    final second = await loop.execute(task, approvedPendingTool: pending);

    expect(second.status, WorkAgentLoopStatus.completed,
        reason: '${second.message}; ${task.lastError}');
    expect(tool.calls, 1, reason: '重放的就是那次抢救写入');
    final resumedPrompt = model.requests.last.messages
        .map((message) => message['content']?.toString() ?? '')
        .join('\n');
    // 用抢救提示独有的措辞钉住指令本身：`report.rescue-` 会经 `committedWrites` 的
    // 操作键漏进 context，只断言文件名的话，把续写指令整个摘掉也照样绿。
    expect(resumedPrompt, contains('补写余下内容'),
        reason: '恢复后仍必须告诉模型从那个分段文件接着写');
    expect(resumedPrompt, contains('report.rescue-'),
        reason: '恢复后的指令必须点名已抢救的分段文件');
  });

  test('a denied salvage approval leaves no continuation hint behind', () async {
    // 运行态写在发起写入**之前**（否则审批暂停会把它一起丢掉），所以"记录在"不等于
    // "内容在"。用户拒绝审批时那次写入从未发生：此时若按记录重建指令，模型会以为
    // 前缀已经在分段文件里，只写余下部分——合并出来的交付物缺了前半截。
    var needsApproval = true;
    final model = _FakeModel()
      ..responses.add({
        'success': true,
        'truncated': true,
        'content': '{"action":"tool","tool":{"name":"workspace.patch",'
            '"arguments":{"path":"report.md","content":"第一段',
      })
      ..responses.add({'success': true, 'content': '还是写坏的正文'})
      ..responses.add(_finishDecision('按分块指令完成。'));
    final tool = _FakeTool();
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(
        definitions: [
          _definition(
            AgentToolName.workspacePatch,
            tool,
            access: WorkToolAccess.mutation,
            pipeline: WorkToolMutationPipeline(
              approval: (_) => needsApproval
                  ? const WorkToolResult.waitingForApproval(message: '需要用户批准')
                  // 生产里的"拒绝"是一次成功的空操作（`rejected: true`），不是失败：
                  // 模型据此换一条安全路径，任务不该因此判死。
                  : const WorkToolResult.success(
                      message: '用户拒绝了该变更，未执行。',
                      data: {'rejected': true},
                    ),
            ),
          ),
        ],
      ),
    );

    final task = _task(id: 'truncation-salvage-resume-denied');
    await loop.execute(task);
    expect(task.executionStateJson, contains('truncationSalvage'));

    needsApproval = false;
    final pending = _resumeSalvageRequest(task);
    task
      ..status = AgentTaskStatus.queued
      ..resumeRequired = false;
    final second = await loop.execute(task, approvedPendingTool: pending);

    expect(second.status, WorkAgentLoopStatus.completed,
        reason: '${second.message}; ${task.lastError}');
    expect(tool.calls, 0, reason: '被拒的写入从未进 handler');
    final resumedPrompt = model.requests.last.messages
        .map((message) => message['content']?.toString() ?? '')
        .join('\n');
    expect(resumedPrompt, isNot(contains('补写余下内容')),
        reason: '没落盘就没有"已写入的前缀"，不得发续写指令');
    expect(resumedPrompt, isNot(contains('已写入内容的结尾是')));
  });

  test('the echoed tail never splits a surrogate pair', () async {
    // `substring(length - 200)` 可能正好劈开代理对，孤立代理经 `utf8.encode` 会静默
    // 变成 U+FFFD。这里让那个表情恰好落在切口上：按码元切时提示里一个**完整**表情
    // 都没有（只剩一个孤立低代理），按 runes 切才原样保留。
    final content = '${'a' * 198}😀${'a' * 199}';
    final model = _FakeModel()
      ..responses.add({
        'success': true,
        'truncated': true,
        'content': '{"action":"tool","tool":{"name":"workspace.patch",'
            '"arguments":{"path":"report.md","content":"$content',
      })
      ..responses.add({'success': true, 'content': '还是写坏的正文'})
      ..responses.add(_finishDecision('完成。'));
    final tool = _FakeTool();
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(definitions: [_patchDefinition(tool)]),
    );

    final task = _task(id: 'truncation-salvage-tail-runes');
    await loop.execute(task);

    final retryPrompt = model.requests.last.messages
        .map((message) => message['content']?.toString() ?? '')
        .join('\n');
    expect(retryPrompt, contains('已写入内容的结尾是'));
    expect(retryPrompt.runes.contains(0x1F600), isTrue,
        reason: '结尾回显里的代理对必须完整');
    final loneSurrogates = retryPrompt.runes
        .where((rune) => rune >= 0xD800 && rune <= 0xDFFF)
        .toList(growable: false);
    expect(loneSurrogates, isEmpty,
        reason: '回显里不得出现孤立代理：$loneSurrogates');
  });

  test('the echoed tail survives the chain-of-thought vocabulary', () async {
    // 被抢救的正文里出现"思维链"在本 App 的产物主题里很常见，而 `_publicText` 的
    // 思维链正则从命中处**一直吃到字符串结尾**——续写指令的最后一段正好是结尾回显，
    // 于是模型拿到的接点变成 `[已隐藏]`，无缝续写没了依据。
    final model = _FakeModel()
      ..responses.add({
        'success': true,
        'truncated': true,
        'content': '{"action":"tool","tool":{"name":"workspace.patch",'
            '"arguments":{"path":"report.md","content":"关于思维链的第 1 段。'
            '结尾标记-ZZZ',
      })
      ..responses.add({'success': true, 'content': '还是写坏的正文'})
      ..responses.add(_finishDecision('完成。'));
    final tool = _FakeTool();
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(definitions: [_patchDefinition(tool)]),
    );

    final task = _task(id: 'truncation-salvage-tail-cot');
    await loop.execute(task);

    final retryPrompt = model.requests.last.messages
        .map((message) => message['content']?.toString() ?? '')
        .join('\n');
    expect(retryPrompt, contains('已写入内容的结尾是'));
    expect(retryPrompt, contains('结尾标记-ZZZ'),
        reason: '结尾回显不得被思维链折叠吃掉');
    expect(retryPrompt, isNot(contains('[已隐藏]')));
  });

  test('a blank content field still salvages from the message field',
      () async {
    // 解析器在 `content` 为空白时看 `message`；抢救若把空白 `content` 当正文，就是
    // 在一份解析器压根没读的文本里找前缀——两边看的不是同一份正文。
    final model = _FakeModel()
      ..responses.add({
        'success': true,
        'truncated': true,
        'content': '   ',
        'message': '{"action":"tool","tool":{"name":"workspace.patch",'
            '"arguments":{"path":"report.md","content":"第一段',
      })
      ..responses.add({'success': true, 'content': '还是写坏的正文'})
      ..responses.add(_finishDecision('按抢救结果续写完成。'));
    final tool = _FakeTool();
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(definitions: [_patchDefinition(tool)]),
    );

    final task = _task(id: 'truncation-salvage-message-body');
    final result = await loop.execute(task);

    expect(result.status, WorkAgentLoopStatus.completed,
        reason: '${result.message}; ${task.lastError}');
    expect(tool.calls, 1, reason: '正文在 message 里，抢救照样要发生');
    expect(tool.arguments.single['content'], '第一段');
  });

  test('untruncated malformed response still feeds the raw body back',
      () async {
    // 对照：非截断的格式错误仍要把原文当数据交回模型，否则修 JSON 就没有依据。
    final model = _FakeModel()
      ..responses.add({
        'success': true,
        'content': '{"action":"不完整的 JSON"',
      })
      ..responses.add(_finishDecision('按原文修复后完成。'));
    final loop = _loop(model: model, registry: WorkToolRegistry());

    final task = _task(id: 'untruncated-repair');
    final result = await loop.execute(task);

    expect(result.status, WorkAgentLoopStatus.completed,
        reason: '${result.message}; ${task.lastError}');
    final repair = model.requests.firstWhere((request) => request.isRepair);
    expect(repair.malformedResponse, '{"action":"不完整的 JSON"');
    // 对照：非截断的格式错误不该被塞进"分块写"指令——它是语法问题，原文回灌
    // 才是修复依据。
    final repairPrompt = repair.messages
        .map((message) => message['content']?.toString() ?? '')
        .join('\n');
    expect(repairPrompt, isNot(contains('拆成多次动作')));
  });

  test('a response that merely fills the budget is not treated as truncated',
      () async {
    // token 兜底只在解析失败之后才起作用：恰好用满预算但 JSON 合法的响应必须
    // 照常完成，不能被当截断而走进"分块写"的修复指令。
    final model = _FakeModel()
      ..responses.add(<String, dynamic>{
        ..._finishDecision('预算刚好用满，但 JSON 完整。'),
        'completionTokens': 8192,
        'requestedMaxTokens': 8192,
      });
    final loop = _loop(model: model, registry: WorkToolRegistry());

    final task = _task(id: 'budget-boundary-finish');
    final result = await loop.execute(task);

    expect(result.status, WorkAgentLoopStatus.completed,
        reason: '${result.message}; ${task.lastError}');
    expect(model.requests.where((request) => request.isRepair), isEmpty);
  });

  test('a broken JSON below the output budget is not treated as truncation',
      () async {
    // 负例：没有用满预算的格式错误仍是普通 JSON 语法问题，必须回灌原文修，
    // 而不是把它当成截断去要求"分块写"。
    final model = _FakeModel()
      ..responses.add(<String, dynamic>{
        'success': true,
        'content': '{"action":"不完整的 JSON"',
        'completionTokens': 120,
        'requestedMaxTokens': 8192,
      })
      ..responses.add(_finishDecision('按原文修复后完成。'));
    final loop = _loop(model: model, registry: WorkToolRegistry());

    final task = _task(id: 'budget-below-format-error');
    final result = await loop.execute(task);

    expect(result.status, WorkAgentLoopStatus.completed,
        reason: '${result.message}; ${task.lastError}');
    final repair = model.requests.firstWhere((request) => request.isRepair);
    expect(repair.malformedResponse, isNotNull);
    final repairPrompt = repair.messages
        .map((message) => message['content']?.toString() ?? '')
        .join('\n');
    expect(repairPrompt, isNot(contains('拆成多次动作')));
  });

  test('an exhausted truncated run names the output cap, not a format error',
      () async {
    // 真实故障：模型把输出预算烧在重复内容上，四轮都拿不到完整动作 JSON。
    // 此时报「格式无效 / 内部处理失败」会让人以为是模型不会写 JSON。
    final model = _FakeModel();
    for (var attempt = 0; attempt < 10; attempt++) {
      model.responses.add({
        'success': true,
        'content': '陆教授：好的，我先把完整的量子力学研究报告 Markdown 源文件写到桌面。',
        'truncated': true,
        'completionTokens': 8192,
      });
    }
    final loop = _loop(model: model, registry: WorkToolRegistry());

    final task = _task(id: 'truncated-exhausted');
    final result = await loop.execute(task);

    expect(result.status, WorkAgentLoopStatus.failed);
    expect(result.message, contains('截断'));
    expect(result.message, contains('8192'));
    expect(
      result.events.map((event) => event.title).join('\n'),
      contains('截断'),
    );
  });

  test('a protocol without the truncated flag still detects a spent budget',
      () async {
    // Anthropic / Responses / Gemini 通道不回 finish_reason，只回 usage：靠
    // "已输出 token 是否达到本次请求的 max_tokens"判定，否则这条恢复链在那些
    // 协议下完全不触发——用户换个协议就照旧失败。
    final model = _FakeModel();
    for (var attempt = 0; attempt < 10; attempt++) {
      model.responses.add({
        'success': true,
        'content': '陆教授：好的，我先把完整的量子力学研究报告写一遍。',
        'completionTokens': 8192,
        'requestedMaxTokens': 8192,
      });
    }
    final loop = _loop(model: model, registry: WorkToolRegistry());

    final task = _task(id: 'protocol-truncated-exhausted');
    final result = await loop.execute(task);

    expect(result.status, WorkAgentLoopStatus.failed);
    expect(result.message, contains('截断'), reason: result.message);
    expect(result.message, contains('8192'));
  });

  test('a response that stops just short of the output budget is a spent budget',
      () async {
    // 实测故障（2026-09-30）：模型在 20480 的预算上输出 20331 token 后被切断，
    // 供应商没给 finish_reason=length，也没把预算用满。按"必须 >= 预算"判定时
    // 这条恢复链完全不触发：任务拿着"一次写完整篇"的原策略原样重发，每轮 300 秒。
    final model = _FakeModel()
      ..responses.add(<String, dynamic>{
        'success': true,
        'content': '{"action":"tool","public_update":"我来重新生成一份完整的文档。"',
        'completionTokens': 20331,
        'requestedMaxTokens': 20480,
      })
      ..responses.add(_finishDecision('按分块指令完成。'));
    final loop = _loop(model: model, registry: WorkToolRegistry());

    final task = _task(id: 'near-budget-truncation');
    final result = await loop.execute(task);

    expect(result.status, WorkAgentLoopStatus.completed,
        reason: '${result.message}; ${task.lastError}');
    final repair = model.requests.firstWhere((request) => request.isRepair);
    final repairPrompt = repair.messages
        .map((message) => message['content']?.toString() ?? '')
        .join('\n');
    expect(repairPrompt, contains('拆成多次动作'));
    // 判成截断就必须按截断走：正文是半截的，回灌对修 JSON 没有价值。
    expect(repair.malformedResponse, isNull);
  });

  test('a broken response well below the output budget keeps the raw body repair',
      () async {
    // 负例（守住阈值另一侧）：预算只用到 85% 的格式错误不能判成截断，否则
    // "原文回灌修 JSON"这条更有依据的路径会被一起关掉。
    final model = _FakeModel()
      ..responses.add(<String, dynamic>{
        'success': true,
        'content': '{"action":"不完整的 JSON"',
        'completionTokens': 7000,
        'requestedMaxTokens': 8192,
      })
      ..responses.add(_finishDecision('按原文修复后完成。'));
    final loop = _loop(model: model, registry: WorkToolRegistry());

    final task = _task(id: 'far-below-budget-format-error');
    final result = await loop.execute(task);

    expect(result.status, WorkAgentLoopStatus.completed,
        reason: '${result.message}; ${task.lastError}');
    final repair = model.requests.firstWhere((request) => request.isRepair);
    expect(repair.malformedResponse, isNotNull);
    final repairPrompt = repair.messages
        .map((message) => message['content']?.toString() ?? '')
        .join('\n');
    expect(repairPrompt, isNot(contains('拆成多次动作')));
  });

  test('a protocol retry records why the response failed to parse', () async {
    // 这条事件是用户唯一看得到的失败线索，而原始响应按设计不落盘：原因、输出
    // 规模和本次预算必须随事件一起记下，否则"为什么格式无效"只能靠反推。
    const broken = '{"action":"tool","public_update":"正在写文件。"';
    final model = _FakeModel()
      ..responses.add(<String, dynamic>{
        'success': true,
        'content': broken,
        'completionTokens': 120,
        'requestedMaxTokens': 8192,
      })
      ..responses.add(<String, dynamic>{
        'success': true,
        'content': broken,
      })
      ..responses.add(_finishDecision('协议重试后完成。'));
    final loop = _loop(model: model, registry: WorkToolRegistry());

    final result = await loop.execute(_task(id: 'protocol-retry-diagnostic'));

    expect(result.status, WorkAgentLoopStatus.completed,
        reason: '${result.message}; '
            '${result.events.map((event) => event.title).join('|')}');
    final retry = result.events.firstWhere(
        (event) => event.title == '模型返回格式无效，正在自动重试。');
    expect(retry.safeMetadata['reason'], '响应不是单个合法 JSON object。');
    expect(retry.safeMetadata['responseCharacters'], broken.length);
    expect(retry.safeMetadata['completionTokens'], 120);
    expect(retry.safeMetadata['requestedMaxTokens'], 8192);
  });

  test('retries a fresh model decision when protocol repair is empty',
      () async {
    final model = _FakeModel()
      ..responses.add({
        'success': true,
        'content': '不是 JSON，也不是公开进度。',
      })
      ..responses.add({
        'success': true,
        'content': '',
      })
      ..responses.add(_finishDecision('自动协议重试后完成。'));
    final loop = _loop(model: model, registry: WorkToolRegistry());

    final result = await loop.execute(_task(id: 'repair-empty-retry'));

    expect(result.status, WorkAgentLoopStatus.completed);
    expect(result.protocolRepairAttempts, 1);
    expect(model.requests, hasLength(3));
    expect(model.requests[1].isRepair, isTrue);
    expect(model.requests[2].isRepair, isFalse);
  });

  test(
      'a transient failure of the repair request is retried at the model level',
      () async {
    // 真实故障（2026-09-30，sensenova-6.8-flash-lite）：一次可重试的链路停滞
    // 发生在修复请求上时，它原本直接冒泡成协议错误——白吃掉一次协议重试额度，
    // 还把这轮记成"模型不会写 JSON"。修复请求必须和普通决策一样走模型级重试。
    final model = _FakeModel()
      ..responses.add(<String, dynamic>{
        'success': true,
        'content': '{"action":"不完整的 JSON"',
        'completionTokens': 120,
        'requestedMaxTokens': 8192,
      })
      ..responses.add(<String, dynamic>{
        'success': false,
        'failureCode': 'timeout',
        'message': '工作模式模型请求首字节超时。',
        'retryable': true,
      })
      ..responses.add(_finishDecision('修复后完成。'));
    final loop = _loop(model: model, registry: WorkToolRegistry());

    final task = _task(id: 'repair-transient-retry');
    final result = await loop.execute(task);

    expect(result.status, WorkAgentLoopStatus.completed,
        reason: '${result.message}; ${task.lastError}');
    expect(model.requests.where((request) => request.isRepair), hasLength(2));
    final titles = result.events.map((event) => event.title).join('\n');
    expect(titles, contains('模型请求暂时失败，准备重试。'));
    expect(titles, isNot(contains('模型返回格式无效，正在自动重试。')));
    expect(titles, isNot(contains('修复请求失败')));
  });

  test('a stalled repair request is retried like any transient model failure',
      () async {
    // 上一条用的是失败响应体，这条用生产形状：停滞是从模型调用里抛出的
    // TimeoutException（首字节看门狗掐断的请求就是这样冒出来的）。
    final model = _FakeModel()
      ..responses.add(<String, dynamic>{
        'success': true,
        'content': '{"action":"不完整的 JSON"',
        'completionTokens': 120,
        'requestedMaxTokens': 8192,
      })
      ..responses.add(TimeoutException('工作模式模型请求首字节超时。'))
      ..responses.add(_finishDecision('修复后完成。'));
    final loop = _loop(model: model, registry: WorkToolRegistry());

    final task = _task(id: 'repair-stall-retry');
    final result = await loop.execute(task);

    expect(result.status, WorkAgentLoopStatus.completed,
        reason: '${result.message}; ${task.lastError}');
    expect(model.requests.where((request) => request.isRepair), hasLength(2));
  });

  test('a model retry records the failure cause in the event metadata',
      () async {
    // 这条气泡原本不带成因：「上游 5xx」「链路断」「首字节停滞」在面板上完全
    // 同形，事后只能去翻 ai_request_diagnostics_v1 反查（网关口径还不同源）。
    // 成因随事件落盘后，光看事件日志就能定性。
    final model = _FakeModel()
      ..responses.add(<String, dynamic>{
        'success': false,
        'failureCode': 'retryableNetwork',
        'statusCode': 503,
        'message': '模型服务暂时不可用。',
        'retryable': true,
      })
      ..responses.add(_finishDecision('重试后完成。'));
    final loop = _loop(model: model, registry: WorkToolRegistry());

    final result = await loop.execute(_task(id: 'retry-cause-metadata'));

    expect(result.status, WorkAgentLoopStatus.completed,
        reason: result.message);
    final retry = result.events
        .firstWhere((event) => event.title == '模型请求暂时失败，准备重试。');
    expect(retry.safeMetadata['retry'], 1);
    expect(retry.safeMetadata['scope'], 'model');
    expect(retry.safeMetadata['failureCode'], 'retryableNetwork');
  });

  test('a first-byte stall names itself instead of the generic network code',
      () async {
    // 生产形状：首字节看门狗（2026-09-30 现场是 180 秒零输出）抛的是
    // WorkModelDeadlineException。它必须带着专属码走完这一路——只按
    // `failure.type.name` 写响应体，停滞与上游 5xx 就是同一个 retryableNetwork。
    final model = _FakeModel()
      ..responses.add(WorkModelDeadlineException.firstByteStall)
      ..responses.add(_finishDecision('重试后完成。'));
    final loop = _loop(model: model, registry: WorkToolRegistry());

    final result = await loop.execute(_task(id: 'retry-cause-stall'));

    expect(result.status, WorkAgentLoopStatus.completed,
        reason: result.message);
    final retry = result.events
        .firstWhere((event) => event.title == '模型请求暂时失败，准备重试。');
    expect(retry.safeMetadata['failureCode'], 'modelFirstByteStall');
  });

  test('a first-byte stall still classifies as a retryable network failure',
      () async {
    // 专属码必须被分类表认出来。认不出来就会掉进 `scope == 'model'` 那条兜底
    // 变成 modelProtocol——面板会把"上游一个字符都没吐"说成"模型写坏了 JSON"，
    // 重试标题也跟着变。
    final model = _FakeModel()
      ..responses.add(WorkModelDeadlineException.firstByteStall);
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(),
      maxModelRetries: 0,
    );

    final result = await loop.execute(_task(id: 'stall-final-classification'));

    expect(result.failure?.type, WorkFailureType.retryableNetwork);
    expect(result.failure?.retryable, isTrue);
  });

  test('an exhausted repair request names the repair failure, not the format',
      () async {
    // 与上一条相反：模型级重试都用完时，用户看到的必须是"修复请求失败"，
    // 因为这次的成因是链路，不是模型的 JSON。
    final model = _FakeModel()
      ..responses.add(<String, dynamic>{
        'success': true,
        'content': '{"action":"不完整的 JSON"',
        'completionTokens': 120,
        'requestedMaxTokens': 8192,
      })
      ..responses.add(<String, dynamic>{
        'success': false,
        'failureCode': 'timeout',
        'message': '工作模式模型请求首字节超时。',
        'retryable': true,
      })
      ..responses.add(<String, dynamic>{
        'success': false,
        'failureCode': 'timeout',
        'message': '工作模式模型请求首字节超时。',
        'retryable': true,
      })
      ..responses.add(_finishDecision('重试后完成。'));
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(),
      maxModelRetries: 1,
    );

    final task = _task(id: 'repair-failure-label');
    final result = await loop.execute(task);

    expect(result.status, WorkAgentLoopStatus.completed,
        reason: '${result.message}; ${task.lastError}');
    final retry = result.events
        .firstWhere((event) => event.title == '模型响应无法解析，修复请求失败，正在重试。');
    expect(retry.detail, contains('协议重试'));
    expect(retry.safeMetadata['reason'], contains('首字节超时'));
    expect(result.events.map((event) => event.title),
        isNot(contains('模型返回格式无效，正在自动重试。')));
  });

  test('a protocol retry records a bounded snippet of the unparseable body',
      () async {
    // 反复出现的"模型写到一半就停"只能靠形状定性：计数与解析器文案都看不出
    // JSON 是在哪一步被切断的。片段必须短（事件存储另有 512 字上限）又保留
    // 开头，所以显式截断并标出省略。
    final body = '甲' * 400;
    final model = _FakeModel()
      ..responses.add(<String, dynamic>{
        'success': true,
        'content': body,
        'completionTokens': 400,
        'requestedMaxTokens': 8192,
      })
      ..responses.add(<String, dynamic>{
        'success': true,
        'content': 'still-not-json',
      })
      ..responses.add(_finishDecision('协议重试后完成。'));
    final loop = _loop(model: model, registry: WorkToolRegistry());

    final result = await loop.execute(_task(id: 'protocol-retry-snippet'));

    expect(result.status, WorkAgentLoopStatus.completed,
        reason: '${result.message}; '
            '${result.events.map((event) => event.title).join('|')}');
    final retry =
        result.events.firstWhere((event) => event.title == '模型返回格式无效，正在自动重试。');
    final snippet = retry.safeMetadata['responseSnippet'] as String;
    expect(snippet, startsWith('甲甲甲'));
    expect(snippet.length, lessThanOrEqualTo(301));
    expect(snippet, endsWith('…'));
    expect(retry.safeMetadata['responseCharacters'], body.length);
  });

  test('a protocol retry records the repaired body as well as the original',
      () async {
    // 关键的对不上：`reason` 描述的多半是**修复后**那次解析的失败，而
    // responseCharacters / responseSnippet 都属于首次决策响应。只留首次正文会
    // 让人按错误的形状去推断（2026-09-30 那 29 次协议重试里，27 次的 reason
    // 来自修复后的正文）。
    const broken = '{"action":"tool","public_update":"正在写文件。"';
    final model = _FakeModel()
      ..responses.add(<String, dynamic>{'success': true, 'content': broken})
      ..responses.add(<String, dynamic>{'success': true, 'content': '修了一半'})
      ..responses.add(_finishDecision('协议重试后完成。'));
    final loop = _loop(model: model, registry: WorkToolRegistry());

    final result =
        await loop.execute(_task(id: 'protocol-retry-repaired-body'));

    expect(result.status, WorkAgentLoopStatus.completed,
        reason: '${result.message}; '
            '${result.events.map((event) => event.title).join('|')}');
    final retry =
        result.events.firstWhere((event) => event.title == '模型返回格式无效，正在自动重试。');
    expect(retry.safeMetadata['reason'], '响应不是单个合法 JSON object。');
    expect(retry.safeMetadata['responseSnippet'], broken);
    expect(retry.safeMetadata['repairResponseSnippet'], '修了一半');
  });

  test('automatically retries a second fresh protocol decision', () async {
    final invalidResponse = <String, dynamic>{
      'success': true,
      'content': '仍然不是合法 AgentDecision。',
    };
    final model = _FakeModel()
      ..responses.add(invalidResponse)
      ..responses.add(invalidResponse)
      ..responses.add(invalidResponse)
      ..responses.add(invalidResponse)
      ..responses.add(_finishDecision('自动协议重试后完成。'));
    final loop = _loop(model: model, registry: WorkToolRegistry());

    final result = await loop.execute(_task(id: 'protocol-retry-twice'));

    expect(result.status, WorkAgentLoopStatus.completed);
    expect(result.protocolRepairAttempts, 2);
    expect(model.requests, hasLength(5));
    expect(model.requests[1].isRepair, isTrue);
    expect(model.requests[2].isRepair, isFalse);
    expect(model.requests[3].isRepair, isTrue);
    expect(model.requests[4].isRepair, isFalse);
  });

  test('automatically retries a third fresh protocol decision', () async {
    final invalidResponse = <String, dynamic>{
      'success': true,
      'content': '仍然不是合法 AgentDecision。',
    };
    final model = _FakeModel();
    for (var attempt = 0; attempt < 6; attempt++) {
      model.responses.add(invalidResponse);
    }
    model.responses.add(_finishDecision('自动协议重试后完成。'));
    final loop = _loop(model: model, registry: WorkToolRegistry());

    final result = await loop.execute(_task(id: 'protocol-retry-thrice'));

    expect(result.status, WorkAgentLoopStatus.completed);
    expect(result.protocolRepairAttempts, 3);
    expect(model.requests, hasLength(7));
  });

  test('stop before model creates an interrupted checkpoint', () async {
    final model = _FakeModel()..responses.add(_finishDecision());
    final cancellation = WorkTaskCancellation()..cancel();
    final loop = _loop(model: model, registry: WorkToolRegistry());
    final task = _task(id: 'stop-before-model');

    final result = await loop.execute(task, cancellation: cancellation);

    expect(result.status, WorkAgentLoopStatus.cancelled);
    expect(model.requests, isEmpty);
    expect(task.status, AgentTaskStatus.interrupted);
    expect(task.resumeRequired, isTrue);
  });

  test('stop before tool prevents execution after public decision', () async {
    final model = _FakeModel()..responses.add(_toolDecision());
    final tool = _FakeTool();
    final cancellation = WorkTaskCancellation();
    final events = <WorkTaskEvent>[];
    final loop = WorkAgentLoop(
      model: model.call,
      registry: WorkToolRegistry(
        definitions: [_definition(AgentToolName.workspaceRead, tool)],
      ),
      sleep: (_) async {},
      onEvent: (event) {
        events.add(event);
        if (event.kind == WorkTaskEventKind.stepStarted) {
          cancellation.cancel();
        }
      },
    );
    final task = _task(id: 'stop-before-tool');

    final result = await loop.execute(task, cancellation: cancellation);

    expect(result.status, WorkAgentLoopStatus.cancelled);
    expect(tool.calls, 0);
    expect(task.actionCount, 1, reason: '模型决策已发生，工具尚未启动');
    expect(task.status, AgentTaskStatus.interrupted);
  });

  test(
      'stop after tool checkpoints the committed action and does not ask model again',
      () async {
    final model = _FakeModel()
      ..responses.add(_toolDecision())
      ..responses.add(_finishDecision());
    final cancellation = WorkTaskCancellation();
    final tool = _FakeTool()
      ..behavior = (_) {
        cancellation.cancel();
        return const WorkToolResult.success(message: '已写入');
      };
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(
        definitions: [_definition(AgentToolName.workspaceRead, tool)],
      ),
    );
    final task = _task(id: 'stop-after-tool');

    final result = await loop.execute(task, cancellation: cancellation);

    expect(result.status, WorkAgentLoopStatus.cancelled);
    expect(tool.calls, 1);
    expect(task.actionCount, 2, reason: '模型决策和工具动作各计一步');
    expect(model.requests, hasLength(1));
    expect(task.completedOperations, hasLength(1));
    expect(task.status, AgentTaskStatus.interrupted);
  });

  test('100 combined model and tool steps pause without asking for step 101',
      () async {
    final model = _FakeModel();
    final tool = _FakeTool();
    for (var index = 0; index < 100; index++) {
      model.responses.add(_toolDecision(path: 'file-$index.txt'));
    }
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(
        definitions: [_definition(AgentToolName.workspaceRead, tool)],
      ),
    );
    final task = _task(id: 'action-limit');

    final result = await loop.execute(task);

    expect(result.status, WorkAgentLoopStatus.paused);
    expect(task.status, AgentTaskStatus.paused);
    expect(task.softLimitReached, isTrue);
    expect(task.actionCount, 100);
    expect(tool.calls, 50);
    expect(model.requests, hasLength(50));
  });

  test('60 minute limit pauses before the next model call', () async {
    final clock = _FakeClock();
    final model = _FakeModel()
      ..responses.add(_toolDecision())
      ..responses.add(_finishDecision());
    final tool = _FakeTool()
      ..behavior = (_) {
        clock.advance(const Duration(minutes: 60));
        return const WorkToolResult.success(message: '完成一步');
      };
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(
        definitions: [_definition(AgentToolName.workspaceRead, tool)],
      ),
      clock: clock,
    );
    final task = _task(id: 'time-limit');

    final result = await loop.execute(task);

    expect(result.status, WorkAgentLoopStatus.paused);
    expect(task.softLimitReached, isTrue);
    expect(task.actionCount, 2);
    expect(model.requests, hasLength(1));
  });

  test('60 minute limit also pauses when the model call crosses the deadline',
      () async {
    final clock = _FakeClock();
    var modelCalls = 0;
    final loop = WorkAgentLoop(
      model: (_) {
        modelCalls++;
        clock.advance(const Duration(minutes: 60));
        return _finishDecision();
      },
      registry: WorkToolRegistry(),
      clock: clock.call,
      sleep: (_) async {},
    );

    final task = _task(id: 'model-time-limit');
    final result = await loop.execute(task);

    expect(result.status, WorkAgentLoopStatus.paused);
    expect(task.softLimitReached, isTrue);
    expect(task.actionCount, 1);
    expect(modelCalls, 1);
  });

  test('a settled approval wait does not consume the task time budget',
      () async {
    final clock = _FakeClock();
    final model = _FakeModel()
      ..responses.add(_toolDecision())
      ..responses.add(_finishDecision());
    final tool = _FakeTool()
      ..behavior = (_) {
        // The hour passed while the user was deciding on an approval, not
        // while the agent was working.
        clock.advance(const Duration(minutes: 60));
        return const WorkToolResult.success(message: '完成一步');
      };
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(
        definitions: [_definition(AgentToolName.workspaceRead, tool)],
      ),
      clock: clock,
    );
    final task = _task(id: 'approval-wait-budget')..startedAt = clock.now;
    task.executionStateJson = jsonEncode(
      WorkTaskBudgetWait.settle(
        WorkTaskBudgetWait.begin(<String, dynamic>{}, task.startedAt!),
        task.startedAt!.add(const Duration(hours: 1)),
        budgetStartedAt: task.startedAt!,
      ),
    );

    final result = await loop.execute(task);

    expect(result.status, WorkAgentLoopStatus.completed);
    expect(task.softLimitReached, isFalse);
    expect(model.requests, hasLength(2));
  });

  test('an open approval wait is settled when the run resumes', () async {
    final clock = _FakeClock();
    final startedAt = clock.now;
    final model = _FakeModel()..responses.add(_finishDecision());
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(),
      clock: clock,
    );
    final task = _task(id: 'settle-approval-wait')
      ..startedAt = startedAt
      ..executionStateJson = jsonEncode(<String, dynamic>{
        WorkTaskBudgetWait.startedAtKey: startedAt.millisecondsSinceEpoch,
      });
    // The wait ends when the user approves and the coordinator requeues the
    // task; the resumed run is the first place that can fold it in.
    clock.advance(const Duration(minutes: 45));

    final result = await loop.execute(task);

    expect(result.status, WorkAgentLoopStatus.completed);
    final execution =
        Map<String, dynamic>.from(jsonDecode(task.executionStateJson) as Map);
    expect(WorkTaskBudgetWait.startedAtOf(execution), isNull);
    expect(
      WorkTaskBudgetWait.totalFor(execution, startedAt),
      const Duration(minutes: 45),
    );
  });

  test('a wait settled before a replan cannot extend the new time budget',
      () async {
    final clock = _FakeClock();
    final model = _FakeModel()
      ..responses.add(_toolDecision())
      ..responses.add(_finishDecision());
    final tool = _FakeTool()
      ..behavior = (_) {
        clock.advance(const Duration(hours: 1));
        return const WorkToolResult.success(message: '完成一步');
      };
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(
        definitions: [_definition(AgentToolName.workspaceRead, tool)],
      ),
      clock: clock,
    );
    // The task waited an hour for an approval, then the user replanned it: the
    // fresh window starts now, so the old discount must not apply to it.
    final task = _task(id: 'superseded-wait-budget', softTimeLimitMinutes: 30)
      ..startedAt = clock.now;
    task.executionStateJson = jsonEncode(
      WorkTaskBudgetWait.settle(
        WorkTaskBudgetWait.begin(
          <String, dynamic>{},
          clock.now.subtract(const Duration(hours: 1)),
        ),
        clock.now,
        budgetStartedAt: clock.now.subtract(const Duration(hours: 1)),
      ),
    );

    final result = await loop.execute(task);

    expect(result.status, WorkAgentLoopStatus.paused);
    expect(task.softLimitReached, isTrue);
  });

  test(
      'user continuation preserves context and skips an already committed write',
      () async {
    final model = _FakeModel()
      ..responses.add(_toolDecision(
        name: AgentToolName.workspacePatch,
        path: 'result.txt',
      ))
      ..responses.add(_toolDecision(
        name: AgentToolName.workspacePatch,
        path: 'result.txt',
      ))
      ..responses.add(_finishDecision('续跑完成。'));
    final tool = _FakeTool();
    final phases = <String>[];
    final pipeline = _recordingPipeline(phases);
    tool.behavior = (_) {
      phases.add('execute');
      return const WorkToolResult.success(message: '写入成功');
    };
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(
        definitions: [
          _definition(
            AgentToolName.workspacePatch,
            tool,
            access: WorkToolAccess.mutation,
            pipeline: pipeline,
          ),
        ],
      ),
      // Keep the continuation test independent from the wall clock. The
      // checkpoint intentionally uses a fixed historical timestamp, so a
      // real clock can make the second run appear past the 60-minute limit.
      clock: _FakeClock(DateTime.utc(2026, 8, 31, 9)),
    );
    final task = _task(id: 'continue-context', actionLimit: 2);

    final first = await loop.execute(task);
    expect(first.status, WorkAgentLoopStatus.paused);
    expect(task.actionCount, 2);
    final persistedContext = task.contextSummary;
    final persistedState = task.executionStateJson;

    task
      ..actionCount = 0
      ..softLimitReached = false
      ..status = AgentTaskStatus.queued
      ..resumeRequired = false
      ..startedAt = DateTime.utc(2026, 8, 31, 9);
    final second = await loop.execute(task);

    expect(second.status, WorkAgentLoopStatus.completed);
    expect(tool.calls, 1, reason: '续跑不能重复已提交写入');
    expect(phases, ['policy', 'approval', 'snapshot', 'lock', 'execute']);
    expect(task.contextSummary, contains('续跑完成'));
    expect(task.contextSummary, contains('result.txt'));
    expect(persistedContext, contains('result.txt'));
    expect(persistedState, contains('committedActionKeys'));
    expect(task.completedOperations, hasLength(1));
  });

  test('same-run duplicate mutation result reaches the next model turn',
      () async {
    final model = _FakeModel()
      ..responses.add(_toolDecision(
        name: AgentToolName.workspacePatch,
        path: 'result.txt',
      ))
      ..responses.add(_toolDecision(
        name: AgentToolName.workspacePatch,
        path: 'result.txt',
      ))
      ..responses.add(_finishDecision());
    final tool = _FakeTool();
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(
        definitions: [
          _definition(
            AgentToolName.workspacePatch,
            tool,
            access: WorkToolAccess.mutation,
            pipeline: _recordingPipeline(<String>[]),
          ),
        ],
      ),
    );

    final result = await loop.execute(_task(id: 'same-run-duplicate'));

    expect(result.status, WorkAgentLoopStatus.completed);
    expect(tool.calls, 1);
    final thirdTurn = model.requests[2].messages
        .map((message) => message['content']?.toString() ?? '')
        .join('\n');
    expect(thirdTurn, contains('已跳过重复执行'));
  });

  test('does not replay an approved request that mismatches its checkpoint',
      () async {
    final model = _FakeModel()..responses.add(_finishDecision('重新规划完成。'));
    final tool = _FakeTool();
    final task = _task(id: 'mismatched-approval')
      ..status = AgentTaskStatus.queued
      ..pendingToolRequestJson = safeToolRequestCheckpoint(
        const ToolRequest(
          tool: AgentToolName.workspaceRead,
          reason: '读取旧文件',
          args: {'path': 'old.txt'},
        ),
      );
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(
        definitions: [_definition(AgentToolName.workspaceRead, tool)],
      ),
    );

    final result = await loop.execute(
      task,
      approvedPendingTool: const ToolRequest(
        tool: AgentToolName.workspaceRead,
        reason: '读取另一个文件',
        args: {'path': 'new.txt'},
      ),
    );

    expect(result.status, WorkAgentLoopStatus.completed);
    expect(tool.calls, 0);
    expect(model.requests, hasLength(1));
  });

  test('finish decision automatically marks task completed', () async {
    final model = _FakeModel()..responses.add(_finishDecision('自动完成'));
    final loop = _loop(model: model, registry: WorkToolRegistry());
    final task = _task(id: 'finish');

    final result = await loop.execute(task);

    expect(result.status, WorkAgentLoopStatus.completed);
    expect(task.status, AgentTaskStatus.completed);
    expect(task.resultSummary, '自动完成');
    expect(task.resumeRequired, isFalse);
  });

  test('restores handoff state from execution checkpoint', () async {
    final model = _FakeModel()
      ..responses.add(_handoffDecision(target: 'receiver'));
    final loop = _loop(model: model, registry: WorkToolRegistry());
    final task = _task(id: 'handoff-execution-fallback');
    final handoff = WorkHandoffState(
      conversationId: task.groupId,
      stages: [
        WorkHandoffStage(
          id: 'product',
          label: '产品需求',
          roleId: task.characterId,
        ),
        WorkHandoffStage(
          id: 'development',
          label: '开发实现',
          roleId: 'receiver',
        ),
      ],
    );
    WorkHandoffState.persistToTask(task, handoff);
    task.contextSummary = jsonEncode({'conversationId': task.groupId});

    final result = await loop.execute(task);

    expect(result.status, WorkAgentLoopStatus.completed);
    expect(task.status, AgentTaskStatus.completed);
    expect(task.lastError, isEmpty);
    expect(model.requests, hasLength(1));
  });

  test('checkpoint JSON never mirrors file bodies from a tool result',
      () async {
    final body = List.filled(1000, 'PRIVATE_FILE_BODY_').join();
    final model = _FakeModel()
      ..responses.add(_toolDecision())
      ..responses.add(_finishDecision(body));
    final tool = _FakeTool()
      ..behavior = (_) => WorkToolResult(
            status: WorkToolResultStatus.success,
            message: '读取完成',
            data: {'output': body, 'bytes': body.length},
          );
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(
        definitions: [_definition(AgentToolName.workspaceRead, tool)],
      ),
    );

    final task = _task(id: 'checkpoint-redaction');
    await loop.execute(task);

    expect(task.contextSummary, isNot(contains('PRIVATE_FILE_BODY_')));
    expect(task.executionStateJson, isNot(contains('PRIVATE_FILE_BODY_')));
    expect(task.resultSummary, isNot(contains('PRIVATE_FILE_BODY_')));
    expect(task.contextSummary, contains('读取完成'));
  });

  test('checkpoint keeps a validated structured command approval plan',
      () async {
    final plan = WorkChangePlan(
      taskId: 'command-plan-checkpoint',
      actionType: WorkChangeActionType.command,
      exactPaths: const [],
      knownAffectedDirectories: const ['/workspace'],
      estimatedBytes: 0,
      snapshotAvailable: false,
      reversible: false,
      command: const WorkChangeCommand(
        executable: 'insta',
        arguments: ['--token=sk-test-1234567890'],
        workingDirectory: '/workspace',
        knownFiles: [],
        possibleDirectories: ['/workspace'],
        impactUncertain: true,
      ),
      commandReason: '命令影响范围不确定。',
      riskReason: '命令影响范围不确定。',
    );
    final model = _FakeModel()..responses.add(_finishDecision());
    final task = _task(id: plan.taskId)
      ..executionStateJson = jsonEncode({'approvalPlan': plan.toJson()});

    await _loop(model: model, registry: WorkToolRegistry()).execute(task);

    final decoded = jsonDecode(task.executionStateJson) as Map;
    final persistedPlan = decoded['approvalPlan'] as Map;
    expect(persistedPlan['command'], isA<Map>());
    expect(
      (persistedPlan['command'] as Map)['arguments'],
      ['--[REDACTED]'],
    );
    final restored = approvalPlanForTask(task);
    expect(restored, isNotNull);
    expect(restored!.actionType, WorkChangeActionType.command);
    expect(restored.snapshotAvailable, isFalse);
    expect(restored.reversible, isFalse);
  });

  test('image tool results remain native multimodal content for the next turn',
      () async {
    const imageData = 'data:image/png;base64,AA==';
    final model = _FakeModel()
      ..responses.add(_toolDecision(
        name: AgentToolName.workspaceDocument,
        arguments: {'path': 'diagram.png'},
      ))
      ..responses.add(_finishDecision());
    final tool = _FakeTool()
      ..behavior = (_) => const WorkToolResult.success(
            message: '已读取 diagram.png，并发送给当前视觉模型。',
            data: {
              'content': [
                {'type': 'text', 'text': '分析图'},
                {
                  'type': 'image_url',
                  'image_url': {'url': imageData},
                },
              ],
              'fileName': 'diagram.png',
            },
          );
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(
        definitions: [
          _definition(AgentToolName.workspaceDocument, tool),
        ],
      ),
    );

    final result = await loop.execute(_task(id: 'native-image-content'));

    expect(result.status, WorkAgentLoopStatus.completed);
    final nextTurn = model.requests.last;
    final imageMessages = nextTurn.messages
        .where((message) => message['content'] is List)
        .toList(growable: false);
    expect(imageMessages, hasLength(1));
    expect(
      imageMessages.single['content'],
      contains(predicate<Map<String, dynamic>>(
        (part) => part['type'] == 'image_url',
      )),
    );
    final checkpoint = nextTurn.messages
        .where((message) => message['role'] == 'system')
        .map((message) => message['content']?.toString() ?? '')
        .join('\n');
    expect(checkpoint, contains('图片已作为多模态消息附加'));
    expect(checkpoint, isNot(contains(imageData)));
  });

  test('mutation registry enforces schema, registration and ordered pipeline',
      () async {
    final tool = _FakeTool();
    final phases = <String>[];
    final pipeline = _recordingPipeline(phases);
    tool.behavior = (_) {
      phases.add('execute');
      return const WorkToolResult.success(message: '写入成功');
    };
    final registry = WorkToolRegistry(
      definitions: [
        _definition(
          AgentToolName.workspacePatch,
          tool,
          access: WorkToolAccess.mutation,
          pipeline: pipeline,
        ),
      ],
    );
    final task = _task(id: 'registry');
    const valid = AgentToolCall(
      name: AgentToolName.workspacePatch,
      arguments: {'path': 'a.txt', 'content': 'a'},
    );
    const invalid = AgentToolCall(
      name: AgentToolName.workspacePatch,
      arguments: {'path': 42},
    );

    expect(registry.validateName('unknown.tool').isValid, isFalse);
    expect(registry.validate(invalid).isValid, isFalse);
    final result = await registry.execute(
      valid,
      context: WorkToolExecutionContext(task: task),
    );

    expect(result.status, WorkToolResultStatus.success);
    expect(tool.calls, 1);
    expect(phases, ['policy', 'approval', 'snapshot', 'lock', 'execute']);
  });

  test(
      'read-only tools execute directly and unregistered tools cannot fall back to shell',
      () async {
    final tool = _FakeTool();
    final registry = WorkToolRegistry(
      definitions: [_definition(AgentToolName.workspaceRead, tool)],
    );
    final task = _task(id: 'readonly');
    final result = await registry.execute(
      const AgentToolCall(
        name: AgentToolName.workspaceRead,
        arguments: {'path': 'a.txt'},
      ),
      context: WorkToolExecutionContext(task: task),
    );

    expect(result.status, WorkToolResultStatus.success);
    expect(tool.calls, 1);
    expect(
      registry.validateName(AgentToolName.commandRun.wireName).isValid,
      isFalse,
    );
  });

  test('user action and approval results pause without retrying', () async {
    final model = _FakeModel()
      ..responses.add(
        _toolDecision(name: AgentToolName.workspacePatch),
      );
    final tool = _FakeTool();
    final pipeline = WorkToolMutationPipeline(
      approval: (_) => const WorkToolResult.waitingForApproval(
        message: '需要用户批准',
      ),
    );
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(
        definitions: [
          _definition(
            AgentToolName.workspacePatch,
            tool,
            access: WorkToolAccess.mutation,
            pipeline: pipeline,
          ),
        ],
      ),
      maxToolRetries: 3,
    );

    final task = _task(id: 'approval-pause');
    final result = await loop.execute(task);

    expect(result.status, WorkAgentLoopStatus.waitingForApproval);
    expect(tool.calls, 0);
    expect(task.actionCount, 1, reason: '模型决策已计步，等待用户批准不再加步');
    expect(task.status, AgentTaskStatus.waitingForApproval);
  });

  test('a mutation lock wait does not consume an action budget unit', () async {
    final model = _FakeModel()
      ..responses.add(_toolDecision(name: AgentToolName.workspacePatch))
      ..responses.add(_finishDecision());
    final tool = _FakeTool();
    final lockEntered = Completer<void>();
    final releaseLock = Completer<void>();
    tool.behavior = (_) => const WorkToolResult.success(message: '已执行');
    final pipeline = WorkToolMutationPipeline(
      policy: (_) => null,
      approval: (_) => null,
      snapshot: (_) => null,
      lock: (_) async {
        if (!lockEntered.isCompleted) lockEntered.complete();
        await releaseLock.future;
        return null;
      },
    );
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(
        definitions: [
          _definition(
            AgentToolName.workspacePatch,
            tool,
            access: WorkToolAccess.mutation,
            pipeline: pipeline,
          ),
        ],
      ),
    );
    final task = _task(id: 'lock-wait');
    final run = loop.execute(task);
    await lockEntered.future;
    expect(task.actionCount, 1);
    releaseLock.complete();
    final result = await run;
    expect(result.status, WorkAgentLoopStatus.completed);
    expect(task.actionCount, 3);
  });

  test('cancellation interrupts a mutation lock wait before the handler',
      () async {
    final model = _FakeModel()
      ..responses.add(_toolDecision(
        name: AgentToolName.workspacePatch,
      ));
    final tool = _FakeTool();
    final cancellation = WorkTaskCancellation();
    final lockEntered = Completer<void>();
    final releaseLock = Completer<void>();
    final pipeline = WorkToolMutationPipeline(
      lock: (_) async {
        if (!lockEntered.isCompleted) lockEntered.complete();
        await releaseLock.future;
        return null;
      },
    );
    final loop = _loop(
      model: model,
      registry: WorkToolRegistry(
        definitions: [
          _definition(
            AgentToolName.workspacePatch,
            tool,
            access: WorkToolAccess.mutation,
            pipeline: pipeline,
          ),
        ],
      ),
    );
    final task = _task(id: 'cancel-lock-wait');
    final run = loop.execute(task, cancellation: cancellation);
    await lockEntered.future;
    cancellation.cancel();
    final result = await run.timeout(const Duration(seconds: 1));
    releaseLock.complete();

    expect(result.status, WorkAgentLoopStatus.cancelled);
    expect(task.status, AgentTaskStatus.interrupted);
    expect(task.actionCount, 1);
    expect(tool.calls, 0);
  });
}

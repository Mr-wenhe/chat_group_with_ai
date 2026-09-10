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
}) {
  return WorkToolDefinition(
    name: name,
    access: access,
    schema: const WorkToolSchema(
      fields: {
        'path': WorkToolValueType.string,
        'content': WorkToolValueType.string,
      },
      required: {'path'},
    ),
    handler: fake.call,
    mutationPipeline: pipeline,
  );
}

WorkAgentLoop _loop({
  required _FakeModel model,
  required WorkToolRegistry registry,
  _FakeClock? clock,
  List<WorkTaskEvent>? events,
  Future<void> Function(Duration)? sleep,
  int? maxModelRetries,
  int? maxToolRetries,
}) {
  return WorkAgentLoop(
    model: model.call,
    registry: registry,
    clock: clock?.call,
    sleep: sleep ?? (_) async {},
    maxModelRetries: maxModelRetries,
    maxToolRetries: maxToolRetries,
    onEvent: events == null
        ? null
        : (event) {
            events.add(event);
          },
  );
}

void main() {
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
    expect(task.contextSummary, isNot(contains('不是 JSON')));
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

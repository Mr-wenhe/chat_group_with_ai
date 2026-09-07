import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/agentic/tool_request.dart';
import 'package:chat_group/features/work_mode/work_agent_loop.dart';
import 'package:chat_group/features/work_mode/work_failure.dart';
import 'package:chat_group/features/work_mode/work_task_coordinator.dart';
import 'package:chat_group/features/work_mode/work_task_event.dart';
import 'package:chat_group/features/work_mode/work_task_event_store.dart';
import 'package:chat_group/features/work_mode/work_tool_registry.dart';
import 'package:chat_group/features/work_mode/presentation/work_task_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

class _ModelQueue {
  final Queue<Object> responses = Queue<Object>();

  Future<Map<String, dynamic>> call(WorkAgentModelRequest request) async {
    if (responses.isEmpty) throw StateError('model queue empty');
    final next = responses.removeFirst();
    if (next is Exception) throw next;
    if (next is Error) throw next;
    if (next is! Map) throw StateError('model queue item is not a map');
    return Map<String, dynamic>.from(next);
  }
}

class _ToolQueue {
  final Queue<WorkToolResult> results = Queue<WorkToolResult>();
  int calls = 0;

  Future<WorkToolResult> call(WorkToolInvocation invocation) async {
    calls++;
    return results.isEmpty
        ? const WorkToolResult.success(message: '工具完成')
        : results.removeFirst();
  }
}

AgentTask _task(String id) => AgentTask(
      id: id,
      groupId: 'failure-conversation',
      characterId: 'worker',
      userRequest: '完成失败恢复测试',
      workModeTask: true,
    )
      ..completedOperations = <String>['已完成：读取项目结构']
      ..queuedUserRequests = <String>['后续追问保留']
      ..resultSummary = '已完成读取项目结构。'
      ..lastArtifactPaths = <String>['/workspace/report.md'];

Map<String, dynamic> _toolDecision({
  AgentToolName tool = AgentToolName.workspaceRead,
}) =>
    <String, dynamic>{
      'success': true,
      'content': jsonEncode(<String, dynamic>{
        'action': 'tool',
        'public_update': '正在执行工具。',
        'tool': <String, dynamic>{
          'name': tool.wireName,
          'arguments': <String, dynamic>{'path': 'report.md'},
        },
        'completion': null,
      }),
    };

Map<String, dynamic> _finishDecision() => <String, dynamic>{
      'success': true,
      'content': jsonEncode(<String, dynamic>{
        'action': 'finish',
        'public_update': '已完成。',
        'tool': null,
        'completion': <String, dynamic>{
          'summary': '恢复完成。',
          'evidence': <String>['检查点已恢复'],
        },
      }),
    };

WorkToolDefinition _definition(AgentToolName name, _ToolQueue tool) =>
    WorkToolDefinition(
      name: name,
      access: WorkToolAccess.readOnly,
      schema: const WorkToolSchema(
        fields: <String, WorkToolValueType>{'path': WorkToolValueType.string},
        required: <String>{'path'},
      ),
      handler: tool.call,
    );

WorkAgentLoop _loop(_ModelQueue model, WorkToolRegistry registry) =>
    WorkAgentLoop(
      model: model.call,
      registry: registry,
      maxModelRetries: 0,
      maxToolRetries: 0,
      sleep: (_) async {},
    );

void main() {
  group('WorkFailure classification and checkpoint recovery', () {
    test('keeps the fixed ten-category matrix serializable', () {
      expect(WorkFailureType.values.map((item) => item.name), <String>[
        'retryableNetwork',
        'modelProtocol',
        'permissionDenied',
        'authorizationLost',
        'fileConflict',
        'snapshotUnavailable',
        'toolMissing',
        'commandFailed',
        'userActionRequired',
        'internal',
      ]);
      for (final type in WorkFailureType.values) {
        final failure = WorkFailure.defaults(type);
        final restored = WorkFailure.fromJson(failure.toJson());
        expect(restored.type, type);
        expect(restored.title, isNotEmpty);
        expect(restored.reason, isNotEmpty);
        expect(restored.technicalDetail, isNotEmpty);
        expect(restored.suggestedAction, isNotEmpty);
      }
    });

    test('classifies model 429, 5xx, timeout, empty stream and protocol errors',
        () async {
      final cases = <String, Object>{
        '429': <String, dynamic>{
          'success': false,
          'statusCode': 429,
          'message': '服务限流',
        },
        '5xx': <String, dynamic>{
          'success': false,
          'statusCode': 500,
          'message': '服务故障',
        },
        'timeout': TimeoutException('模型超时'),
        '401 exception': StateError('HTTP 401'),
        '403 exception': StateError('HTTP 403'),
        'empty stream': <String, dynamic>{
          'success': true,
          'content': '',
          'reasoning_content': '',
        },
        'empty failed response': <String, dynamic>{
          'success': false,
          'content': '',
          'reasoning_content': '',
        },
        'protocol': <String, dynamic>{
          'success': true,
          'content': 'not-json',
        },
      };
      for (final entry in cases.entries) {
        final model = _ModelQueue();
        if (entry.key == 'protocol') {
          model.responses
            ..add(entry.value)
            ..add(entry.value);
        } else {
          model.responses.add(entry.value);
        }
        final task = _task('model-${entry.key}');
        final result = await _loop(model, WorkToolRegistry()).execute(task);
        expect(result.failure, isNotNull, reason: entry.key);
        final expectedType = switch (entry.key) {
          'protocol' ||
          'empty stream' ||
          'empty failed response' =>
            WorkFailureType.modelProtocol,
          '401 exception' => WorkFailureType.authorizationLost,
          '403 exception' => WorkFailureType.permissionDenied,
          _ => WorkFailureType.retryableNetwork,
        };
        expect(result.failure!.type, expectedType, reason: entry.key);
        expect(
          task.status,
          entry.key == '401 exception' || entry.key == '403 exception'
              ? AgentTaskStatus.paused
              : AgentTaskStatus.failed,
        );
        expect(task.completedOperations, contains('已完成：读取项目结构'));
        expect(task.contextSummary, contains('已完成读取项目结构'));
        expect(task.queuedUserRequests, <String>['后续追问保留']);
        expect(task.contextSummary, contains('后续追问保留'));
        expect(task.executionStateJson, contains('workFailure'));
        expect(task.executionStateJson, isNot(contains('模型超时')),
            reason: '技术细节必须脱敏');
      }
    });

    test('keeps command exit codes out of the HTTP retry category', () {
      final commandFailure = WorkFailure.fromError(
        StateError('process exited with code 500'),
        scope: 'command',
      );
      expect(commandFailure.type, WorkFailureType.commandFailed);
      expect(commandFailure.retryable, isFalse);
    });

    test('classifies tool, file, snapshot, command and browser failures',
        () async {
      final cases = <String, WorkToolResult>{
        'permission': const WorkToolResult.permissionDenied(message: '权限拒绝'),
        'authorization': const WorkToolResult.paused(
          message: '目录已失效',
          failureCode: 'authorizationLost',
        ),
        'conflict': const WorkToolResult.failed(
          message: '文件被外部修改',
          failureCode: 'fileConflict',
        ),
        'snapshot': const WorkToolResult.waitingForApproval(
          message: '快照创建失败',
          failureCode: 'snapshotUnavailable',
        ),
        'disk': const WorkToolResult.failed(
          message: 'No space left on device',
          failureCode: 'commandFailed',
        ),
        'command-timeout': const WorkToolResult.failed(
          message: '命令执行超时',
          failureCode: 'commandFailed',
        ),
        'missing-tool': const WorkToolResult.paused(
          message: '缺失工具',
          failureCode: 'toolMissing',
        ),
        'browser': const WorkToolResult.paused(
          message: '浏览器等待人工介入',
          failureCode: 'userActionRequired',
        ),
      };
      final expected = <String, WorkFailureType>{
        'permission': WorkFailureType.permissionDenied,
        'authorization': WorkFailureType.authorizationLost,
        'conflict': WorkFailureType.fileConflict,
        'snapshot': WorkFailureType.snapshotUnavailable,
        'disk': WorkFailureType.snapshotUnavailable,
        'command-timeout': WorkFailureType.commandFailed,
        'missing-tool': WorkFailureType.toolMissing,
        'browser': WorkFailureType.userActionRequired,
      };
      for (final entry in cases.entries) {
        final model = _ModelQueue()..responses.add(_toolDecision());
        final tool = _ToolQueue()..results.add(entry.value);
        final task = _task('tool-${entry.key}');
        final result = await _loop(
          model,
          WorkToolRegistry(
            definitions: [_definition(AgentToolName.workspaceRead, tool)],
          ),
        ).execute(task);
        expect(result.failure?.type, expected[entry.key], reason: entry.key);
        expect(task.completedOperations, contains('已完成：读取项目结构'));
        expect(task.contextSummary, contains('已完成读取项目结构'));
        expect(task.queuedUserRequests, <String>['后续追问保留']);
        expect(task.contextSummary, contains('后续追问保留'));
        expect(task.executionStateJson, contains('workFailure'));
        expect(
          task.status,
          entry.key == 'snapshot' ||
                  entry.key == 'permission' ||
                  entry.key == 'authorization' ||
                  entry.key == 'missing-tool' ||
                  entry.key == 'browser'
              ? anyOf(
                  AgentTaskStatus.paused,
                  AgentTaskStatus.waitingForApproval,
                )
              : AgentTaskStatus.failed,
        );
      }
    });

    test('unknown missing tools give manual guidance without an install CTA',
        () {
      final failure = WorkFailure.fromToolResult(
        const WorkToolResult.paused(
          message: '缺少工具：insta。',
          data: <String, dynamic>{
            'installSuggestion': <String, dynamic>{
              'executable': 'insta',
              'purpose': '运行用户声明的本机命令',
              'trustedSource': 'insta 官方文档',
              'message': '无法安全自动安装，请从官方文档手动处理。',
            },
          },
          failureCode: 'toolMissing',
        ),
      );

      expect(failure.type, WorkFailureType.toolMissing);
      expect(failure.suggestedAction, contains('官方文档'));
      expect(failure.suggestedAction, isNot(contains('帮助安装工具')));
    });

    test('restored missing-tool checkpoints do not resurrect an install CTA',
        () {
      final task = _task('legacy-missing-tool')
        ..status = AgentTaskStatus.paused
        ..contextSummary = jsonEncode(<String, dynamic>{
          'recentToolResults': <Map<String, dynamic>>[
            <String, dynamic>{
              'data': <String, dynamic>{
                'installSuggestion': <String, dynamic>{
                  'executable': 'insta',
                  'trustedSource': 'insta 官方文档',
                },
              },
            },
          ],
        });
      WorkFailure.persistOnTask(
        task,
        WorkFailure.defaults(WorkFailureType.toolMissing),
      );

      expect(task.workFailure, isNotNull);
      expect(task.workFailure!.suggestedAction, contains('官方文档'));
      expect(task.workFailure!.suggestedAction, isNot(contains('帮助安装工具')));
    });

    test('restored known missing-tool checkpoints keep the install CTA', () {
      final task = _task('known-missing-tool')
        ..status = AgentTaskStatus.paused
        ..contextSummary = jsonEncode(<String, dynamic>{
          'recentToolResults': <Map<String, dynamic>>[
            <String, dynamic>{
              'data': <String, dynamic>{
                'installSuggestion': <String, dynamic>{
                  'executable': 'rg',
                  'installCommand': <String, dynamic>{
                    'executable': 'brew',
                    'arguments': <String>['install', 'ripgrep'],
                  },
                },
              },
            },
          ],
        });
      WorkFailure.persistOnTask(
        task,
        WorkFailure.defaults(WorkFailureType.toolMissing),
      );

      expect(task.workFailure!.suggestedAction, contains('帮助安装工具'));
    });

    test('retries from a checkpoint without repeating a committed mutation',
        () async {
      final model = _ModelQueue()
        ..responses.add(_toolDecision())
        ..responses.add(<String, dynamic>{
          'success': false,
          'statusCode': 503,
          'message': '暂时不可用',
        });
      final tool = _ToolQueue()
        ..results.add(const WorkToolResult.success(message: '写入完成'));
      final registry = WorkToolRegistry(
        definitions: [
          WorkToolDefinition(
            name: AgentToolName.workspaceRead,
            access: WorkToolAccess.mutation,
            schema: const WorkToolSchema(
              fields: <String, WorkToolValueType>{
                'path': WorkToolValueType.string,
              },
              required: <String>{'path'},
            ),
            handler: tool.call,
            mutationPipeline: const WorkToolMutationPipeline(),
          ),
        ],
      );
      final loop = _loop(model, registry);
      final task = _task('mutation-retry');
      final first = await loop.execute(task);
      expect(first.failure?.type, WorkFailureType.retryableNetwork);
      expect(task.completedOperations, hasLength(2));
      final callsAfterFirst = tool.calls;
      model.responses.add(_toolDecision());
      model.responses.add(_finishDecision());
      task
        ..status = AgentTaskStatus.queued
        ..resumeRequired = false;
      final second = await loop.execute(task);
      expect(second.status, WorkAgentLoopStatus.completed);
      expect(tool.calls, callsAfterFirst,
          reason: 'retry must skip committed mutation');
      expect(task.executionStateJson, isNot(contains('workFailure')));
      expect(task.contextSummary, contains('恢复完成'));
    });

    test(
        'retries snapshot bookkeeping after a committed write without replaying it',
        () async {
      final model = _ModelQueue()..responses.add(_toolDecision());
      final tool = _ToolQueue()
        ..results.add(
          const WorkToolResult.failed(
            message: '文件已写入，但撤销记录未完成。',
            data: <String, dynamic>{
              'path': 'report.md',
              'mutationCommitted': true
            },
            failureCode: 'snapshotUnavailable',
            committed: true,
          ),
        );
      final registry = WorkToolRegistry(
        definitions: [
          WorkToolDefinition(
            name: AgentToolName.workspaceRead,
            access: WorkToolAccess.mutation,
            schema: const WorkToolSchema(
              fields: <String, WorkToolValueType>{
                'path': WorkToolValueType.string,
              },
              required: <String>{'path'},
            ),
            handler: tool.call,
            mutationPipeline: const WorkToolMutationPipeline(),
          ),
        ],
      );
      final loop = _loop(model, registry);
      final task = _task('committed-snapshot-retry');
      final first = await loop.execute(task);
      expect(first.failure?.type, WorkFailureType.snapshotUnavailable);
      expect(first.failure?.retryable, isTrue);
      expect(task.completedOperations, hasLength(2));
      expect(task.executionStateJson, contains('committedActionKeys'));
      expect(task.queuedUserRequests, <String>['后续追问保留']);

      model.responses
        ..add(_toolDecision())
        ..add(_finishDecision());
      task
        ..status = AgentTaskStatus.queued
        ..resumeRequired = false;
      final second = await loop.execute(task);
      expect(second.status, WorkAgentLoopStatus.completed);
      expect(tool.calls, 1, reason: 'committed write must not be replayed');
      expect(task.contextSummary, contains('恢复完成'));
      expect(task.queuedUserRequests, <String>['后续追问保留']);
    });
  });

  group('WorkTaskPanel recovery actions', () {
    AgentTask panelTask(WorkFailureType type, {bool retryable = false}) {
      final task = _task('panel-${type.name}')..status = AgentTaskStatus.failed;
      final failure = WorkFailure(
        type: type,
        title: WorkFailure.defaults(type).title,
        reason: '测试失败原因',
        technicalDetail: 'safe detail',
        completedContent: const <String>['已完成一步'],
        retryable: retryable,
        suggestedAction: '测试下一步',
      );
      WorkFailure.persistOnTask(task, failure);
      return task;
    }

    Future<void> pumpPanel(
      WidgetTester tester,
      AgentTask task, {
      WorkTaskAction? onRetry,
      WorkTaskAction? onReauthorize,
      WorkTaskAction? onViewConflict,
      WorkTaskAction? onContinue,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WorkTaskPanel(
              tasks: <AgentTask>[task],
              eventStreamFor: (_) => const Stream<WorkTaskEvent>.empty(),
              onSelectTask: (_) {},
              onStop: (_) {},
              onContinue: onContinue ?? (_) {},
              onRetry: onRetry,
              onReauthorize: onReauthorize,
              onViewConflict: onViewConflict,
              onOpenConversation: (_) {},
              onCollapse: () {},
              onClose: () {},
            ),
          ),
        ),
      );
    }

    testWidgets('only exposes retry for retryable failures', (tester) async {
      var retries = 0;
      final task = panelTask(WorkFailureType.retryableNetwork, retryable: true);
      await pumpPanel(tester, task, onRetry: (_) async => retries++);
      expect(find.byKey(const Key('work-task-retry')), findsOneWidget);
      expect(find.byKey(const Key('work-task-reauthorize')), findsNothing);
      expect(find.byKey(const Key('work-task-view-conflict')), findsNothing);
      expect(find.byKey(const Key('work-task-continue')), findsNothing);
      await tester.tap(find.byKey(const Key('work-task-retry')));
      expect(retries, 1);
    });

    testWidgets('only exposes reauthorize for permission/auth failures',
        (tester) async {
      var calls = 0;
      final task = panelTask(WorkFailureType.authorizationLost);
      await pumpPanel(tester, task, onReauthorize: (_) async => calls++);
      expect(find.byKey(const Key('work-task-reauthorize')), findsOneWidget);
      expect(find.byKey(const Key('work-task-retry')), findsNothing);
      expect(find.byKey(const Key('work-task-continue')), findsNothing);
      await tester.tap(find.byKey(const Key('work-task-reauthorize')));
      expect(calls, 1);
    });

    testWidgets('only exposes conflict viewer for file conflicts',
        (tester) async {
      var calls = 0;
      final task = panelTask(WorkFailureType.fileConflict);
      await pumpPanel(tester, task, onViewConflict: (_) async => calls++);
      expect(find.byKey(const Key('work-task-view-conflict')), findsOneWidget);
      expect(find.byKey(const Key('work-task-reauthorize')), findsNothing);
      expect(find.byKey(const Key('work-task-continue')), findsNothing);
      await tester.tap(find.byKey(const Key('work-task-view-conflict')));
      expect(calls, 1);
    });

    testWidgets('only exposes continue for user-action pauses', (tester) async {
      final task = panelTask(WorkFailureType.userActionRequired)
        ..status = AgentTaskStatus.paused
        ..resumeRequired = true;
      await pumpPanel(tester, task, onContinue: (_) async {});
      final continueButton = tester.widget<FilledButton>(
        find.byKey(const Key('work-task-continue')),
      );
      expect(continueButton.onPressed, isNotNull);
      expect(find.byKey(const Key('work-task-retry')), findsNothing);
    });
  });

  test('restore marks an app restart as user action and keeps the queue',
      () async {
    final directory = await Directory.systemTemp.createTemp('work-failure-');
    addTearDown(() async {
      await Hive.close();
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    Hive.init(directory.path);
    if (!Hive.isAdapterRegistered(12)) {
      Hive.registerAdapter(AgentTaskStatusAdapter());
    }
    if (!Hive.isAdapterRegistered(13)) Hive.registerAdapter(AgentTaskAdapter());
    final box = await Hive.openBox<AgentTask>('work-failure-task-box');
    final task = _task('restart')
      ..status = AgentTaskStatus.runningTool
      ..queuedUserRequests = <String>['继续检查'];
    await box.put(task.id, task);
    final eventStore = WorkTaskEventStore(
      appSupportDirectory: Directory('${directory.path}/support'),
    );
    final coordinator = WorkTaskCoordinator(
      taskBox: box,
      eventStore: eventStore,
      runner: _NoopRunner(),
    );
    await coordinator.restore();
    final restored = box.get(task.id)!;
    expect(restored.status, AgentTaskStatus.interrupted);
    expect(restored.workFailure?.type, WorkFailureType.userActionRequired);
    expect(restored.queuedUserRequests, <String>['继续检查']);
    expect(restored.contextSummary, contains('继续检查'));
    await coordinator.dispose();
    await eventStore.close();
  });
}

class _NoopRunner implements WorkTaskRunner {
  @override
  Future<void> run(AgentTask task, WorkTaskCancellation cancellation) async {}
}

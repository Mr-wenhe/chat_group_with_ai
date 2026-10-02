part of 'default_work_task_runner_stage02_test.dart';

const _p7Scenarios = [
  'software',
  'startup',
  'portable-import',
  'document',
  'refusal',
  'fake-signature',
  'silent',
  'member-lost',
  'content-change',
  'old-evidence',
  'late-input',
  'late-copy-input',
  'retest-failure',
  'assertion-change',
  'tool-missing',
  'tool-failure',
  'coverage-missing',
  'assertion-tool-write',
  'manual',
  'manual-no-tester',
  'waiver',
  'deferred',
  'delivery-failure',
  'cancel',
  'lock'
];

const _p7BlockedToolCases = {
  'assertion-change',
  'tool-missing',
  'tool-failure',
  'coverage-missing',
  'assertion-tool-write'
};

class _P7Gateway extends AiRequestGateway {
  final AgentTask Function() task;
  final bool document;
  final String scenario;
  final Map<String, int> calls = {};
  final List<String> actors = [];
  _P7Gateway(this.task, {this.document = false, this.scenario = 'software'})
      : super(store: MemoryGovernanceStore(), client: _UnusedClient());
  @override
  Future<Map<String, dynamic>> sendChatMessageStreamed(
      {required String apiKey,
      required ApiProvider provider,
      ApiProtocol apiProtocol = ApiProtocol.defaultValue,
      String? customBaseUrl,
      required String model,
      required List<Map<String, dynamic>> messages,
      required AiRequestPurpose purpose,
      required String conversationId,
      required String characterId,
      double temperature = 0.85,
      int maxTokens = 1024,
      Duration receiveTimeout = const Duration(seconds: 120),
      int maxRetries = 5,
      CancelToken? cancelToken,
      bool requiresTools = false,
      bool userInitiated = false,
      void Function(ChatStreamEvent event)? onEvent}) async {
    final state =
        WorkDiscussionState.fromExecutionState(task().executionStateJson)!
            .collaboration!;
    final binding = (jsonDecode(task().executionStateJson)
        as Map)['workItemExecution'] as Map;
    final key = '${binding['stage']}:${state.requestRevision}';
    final call = calls.update(key, (n) => n + 1, ifAbsent: () => 1);
    actors.add(characterId);
    final tool = call == 1;
    final manual = state.acceptances
        .every((a) => {'manual', 'waived'}.contains(a['status']));
    final stage = binding['stage'];
    final failed = scenario != 'coverage-missing' &&
        state.iterations.length - (scenario == 'portable-import' ? 1 : 0) <=
            (scenario == 'retest-failure' ? 2 : 1);
    final conclusion = {
      'method': manual
          ? '保留用户人工结论并复核当前文件'
          : document
              ? '正文与格式审查'
              : '受控交互测试',
      'result': failed ? 'failed' : 'passed',
      'acceptanceIds': ['qa'],
      'report': failed
          ? document
              ? '正文缺少来源与日期，完整问题在报告中。'
              : '按钮连续点击会增加两次，预期只增加一次。'
          : '原复现和相关回归均通过。',
      'defects': [
        if (failed)
          {
            'acceptanceId': 'qa',
            'reproduction': document ? '读取报告正文与来源部分' : '连续点击按钮',
            'expected': document ? '正文有来源与更新日期' : '只增加一次',
            'actual': document ? '来源和日期缺失' : '增加两次',
            'retestCondition': '原复现与相关回归均通过'
          }
      ]
    };
    return {
      'success': true,
      'message': jsonEncode({
        'action': tool ? 'tool' : 'finish',
        'public_update': tool
            ? '我处理当前工作项。'
            : failed && stage == 'verify'
                ? '连续点击有问题，复现和全部明细在报告中。'
                : '本项已核对，交给下一位。',
        'tool': !tool
            ? null
            : stage == 'verify' && scenario == 'assertion-tool-write'
                ? {
                    'name': 'workspace.patch',
                    'arguments': {
                      'path': 'work.md',
                      'content': '删除失败断言',
                      'overwrite': true
                    }
                  }
                : stage == 'verify'
                    ? {
                        'name': document || manual
                            ? 'workspace.read'
                            : 'command.run',
                        'arguments': document || manual
                            ? {'path': document ? 'report.txt' : 'report.html'}
                            : {
                                'executable': 'pwd',
                                'workingDirectory': '',
                                'arguments': [],
                                'declaredImpact': ['.']
                              }
                      }
                    : {
                        'name': 'workspace.patch',
                        'arguments': {
                          'path': stage == 'material'
                              ? 'work.md'
                              : document
                                  ? 'report.txt'
                                  : 'report.html',
                          'content': stage == 'material'
                              ? document
                                  ? '文档目标：说明范围、引用来源与更新日期；审查正文结构与格式。'
                                  : '需求：连续点击只执行一次。技术：事件锁。测试：原复现、边界与回归。'
                              : document
                                  ? (state.iterations.isEmpty
                                      ? '报告 r001 正文缺来源'
                                      : '报告 r002 正文有来源与日期')
                                  : '<html><body>${state.iterations.length - (scenario == 'portable-import' ? 1 : 0) < (scenario == 'retest-failure' ? 2 : 1) ? 'broken-${state.iterations.length}' : 'fixed'} game<button>roll</button></body></html>',
                          'overwrite': true
                        }
                      },
        'completion': tool
            ? null
            : {
                'summary': stage == 'verify'
                    ? conclusion['report']
                    : '当前工作项已完成，详细依据在文件中。',
                'evidence': [
                  stage == 'verify' ? jsonEncode(conclusion) : 'work.md'
                ]
              }
      })
    };
  }
}

class _P7Command extends WorkCommandRunner {
  final AgentTask Function() task;
  int runs = 0;
  final String scenario;
  _P7Command(this.task, String root, {this.scenario = 'software'})
      : super(policy: WorkCommandPolicy(authorizedRoots: [root]));
  @override
  Future<WorkCommandResult> run(WorkCommand command,
      {required String taskId,
      bool approvalGranted = false,
      bool? approved,
      bool userExplicitlyRequested = false,
      bool acceptancePlanAuthorized = false,
      bool includeUserHome = false,
      Future<void>? cancellation,
      bool Function()? isCancelled}) async {
    runs++;
    if ({'tool-missing', 'tool-failure', 'manual', 'waiver'}
        .contains(scenario)) {
      return WorkCommandResult(
          command: command,
          status: scenario == 'tool-missing'
              ? WorkCommandRunStatus.toolMissing
              : WorkCommandRunStatus.failed,
          message: '受控测试工具不可用或执行失败',
          stdout: '',
          stderr: 'test runner unavailable',
          exitCode: {'manual', 'waiver'}.contains(scenario) ? 1 : null,
          elapsed: Duration.zero,
          outputTruncated: false,
          policy: policy.evaluate(command, taskId: taskId));
    }

    final state =
        WorkDiscussionState.fromExecutionState(task().executionStateJson)!
            .collaboration!;
    final actual =
        await File('${command.workingDirectory}/report.html').readAsString();
    final failed = actual.contains('broken');
    return WorkCommandResult(
        command: command,
        status: WorkCommandRunStatus.completed,
        message: '受控测试已运行',
        stdout: jsonEncode({
          'artifactDigest': state.currentIteration!['artifactDigest'],
          'tests': [
            if (scenario != 'coverage-missing')
              {
                'id': 'qa',
                'status': failed ? 'failed' : 'passed',
                'method': 'command',
                'reproduction': '连续点击按钮与边界回归',
                'expected': '只增加一次',
                'actual': failed ? '增加两次' : '只增加一次'
              }
          ]
        }),
        stderr: '',
        exitCode: 0,
        elapsed: Duration.zero,
        outputTruncated: false,
        policy: policy.evaluate(command, taskId: taskId));
  }
}

Future<void> _p7AssertBlocked(String scenario, bool injected, AgentTask work,
    CandidateTestDatabase db, Directory root, WorkTaskEventStore events) async {
  if (scenario == 'assertion-tool-write') {
    expect(await File('${root.path}/work.md').readAsString(), contains('测试'));
  }

  if (scenario == 'deferred') {
    expect(
        WorkTaskDecision.forTask(work).single.reminderKind, 'remainderReady');
    expect(
        WorkDiscussionState.fromExecutionState(work.executionStateJson)!
            .collaboration!
            .workItems
            .where((i) => i['id'] != 'later')
            .every((i) => i['status'] == 'done'),
        isTrue);
  }
  expect(injected || _p7BlockedToolCases.contains(scenario), isTrue);
  expect(work.status, isNot(AgentTaskStatus.completed));
  if (scenario == 'late-copy-input') {
    expect(work.userRequest, contains('附件投递期间补充'));
    expect(
        db.messageBox.values
            .singleWhere((m) => m.workDelivery?['kind'] == 'final')
            .content,
        contains('未正式完成'));
  } else {
    expect(
        db.messageBox.values.where((m) => m.workDelivery?['kind'] == 'final'),
        isEmpty);
  }
  expect(
      (await events.read(work.id))
          .events
          .where((e) => e.kind == WorkTaskEventKind.completed),
      isEmpty);
}

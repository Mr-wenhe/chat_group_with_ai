import 'dart:convert';
import 'package:chat_group/features/agentic/tool_request.dart';
import 'package:chat_group/features/work_mode/agent_decision.dart';
import 'package:chat_group/features/work_mode/work_tool_registry.dart';
import 'package:chat_group/features/work_mode/work_collaboration_state.dart';
import 'package:chat_group/features/work_mode/work_usage_receipt.dart';
import 'package:flutter_test/flutter_test.dart';
import 'work_candidate_test_support.dart';

void main() {
  test('群审查浏览器通过总闸门后仍执行策略流水线，写文件仍被拒绝', () async {
    final task =
        candidateTestTask(candidateTestState(type: 'software', format: 'html'));
    final execution =
        jsonDecode(task.executionStateJson) as Map<String, dynamic>;
    execution['workItemExecution'] = {'stage': 'verify'};
    task.executionStateJson = jsonEncode(execution);
    final phases = <String>[];
    final registry = WorkToolRegistry(definitions: [
      for (final name in [
        AgentToolName.browserContext,
        AgentToolName.workspacePatch
      ])
        WorkToolDefinition(
            name: name,
            access: WorkToolAccess.mutation,
            schema: const WorkToolSchema(fields: {}, required: {}),
            mutationPipeline: WorkToolMutationPipeline(policy: (_) async {
              phases.add('policy');
              return null;
            }),
            handler: (_) async {
              phases.add('execute');
              return const WorkToolResult.success(message: 'ok');
            }),
    ]);
    final result = await registry.execute(
        const AgentToolCall(name: AgentToolName.browserContext, arguments: {}),
        context: WorkToolExecutionContext(task: task));
    expect(result.succeeded, isTrue, reason: result.message);
    expect(phases, ['policy', 'execute']);
    final denied = await registry.execute(
        const AgentToolCall(name: AgentToolName.workspacePatch, arguments: {}),
        context: WorkToolExecutionContext(task: task));
    expect(denied.failureCode, 'discussionPhaseDenied');
    expect(phases, ['policy', 'execute']);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('独立浏览器审查只接受当前成员候选的完整业务断言，保留真实失败', () {
    final raw = candidateTestState(type: 'software', format: 'html').toJson()
      ..['autonomyPolicy'] = WorkCollaborationAutonomy.policyFor(['a', 'b'])
      ..['usageEvidenceRefs'] = []
      ..['coordinatorDecisions'] = []
      ..['usageAssignments'] = [
        for (final member in ['a', 'b'])
          {
            'memberId': member,
            'scenarioId': 'scene-$member',
            'goal': '测试',
            'preconditions': '独立数据',
            'stepGoals': ['点击'],
            'expectedResult': '红方获胜',
            'acceptanceIds': ['qa'],
            'requiredCapabilities': ['browser.context'],
            'resetMethod': '重新开始',
            'requestRevision': 1,
          }
      ]
      ..['acceptances'] = [
        for (final a in candidateTestState().acceptances)
          {...a, 'requiredCapability': 'browser.context'}
      ]
      ..['iterations'] = [
        {
          'id': 'r001',
          'artifactDigest': 'digest',
          'requestRevision': 1,
          'teamRevision': 1,
          'manifestRef': 'manifest',
          'reviewRef': '',
          'status': 'candidate'
        }
      ];
    final state = WorkCollaborationState.tryParse(raw)!;
    WorkUsageObservation observation(
            {String actor = 'b',
            String digest = 'digest',
            String operation = 'assert',
            bool verified = true}) =>
        WorkUsageObservation(
            taskId: state.taskId,
            conversationId: state.conversationId,
            actorId: actor,
            scenarioId: 'scene-$actor',
            iterationId: 'r001',
            artifactDigest: digest,
            planDigest: state.usagePlanDigest,
            verificationRevision: state.verificationRevision,
            runtime: 'macos-webkit',
            sessionRef: 'session',
            operation: operation,
            beforeRef: 'before',
            afterRef: 'after',
            outputRefs: ['evidence'],
            verifiedAcceptanceIds: verified ? ['qa'] : [],
            businessResultVerified: verified);
    String? result(WorkUsageObservation o,
            {bool matched = true, bool truncated = false}) =>
        o.browserReviewResult(state, 'b', 'qa',
            matched: matched, textTruncated: truncated);
    expect(result(observation()), 'passed');
    expect(result(observation(verified: false), matched: false), 'failed');
    expect(result(observation(actor: 'a')), isNull);
    expect(result(observation(digest: 'old')), isNull);
    expect(result(observation(operation: 'click')), isNull);
    expect(result(observation(verified: false)), isNull);
    expect(result(observation(), truncated: true), isNull);
  }, timeout: const Timeout(Duration(seconds: 30)));
}

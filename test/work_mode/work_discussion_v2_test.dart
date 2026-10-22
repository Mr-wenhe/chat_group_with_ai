import 'package:chat_group/core/models/media_attachment.dart';
import 'package:chat_group/features/work_mode/work_task_completion_choice.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:chat_group/core/models/permanent_memory.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/models/api_protocol.dart';
import 'package:chat_group/features/ai_governance/ai_request_gateway.dart';
import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/services/chat_api_service.dart';
import 'package:chat_group/core/streaming/chat_stream_event.dart';
import 'package:dio/dio.dart';
import '../helpers/memory_governance_store.dart';
import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/tool_permission.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/features/work_mode/default_work_task_runner.dart';
import 'package:chat_group/features/work_mode/work_discussion_runner.dart';
import 'package:chat_group/features/work_mode/work_discussion_state.dart';
import 'package:chat_group/features/work_mode/work_collaboration_state.dart';
import 'package:chat_group/features/work_mode/work_context_boundary.dart';
import 'package:chat_group/features/work_mode/work_discussion_v2_protocol.dart';
import 'package:chat_group/features/work_mode/work_discussion_v2_protocol_text.dart';
import 'package:chat_group/features/work_mode/work_discussion_v2_stage.dart';
import 'package:chat_group/features/chat_group/roundtable_news_role_service.dart'
    show RoundtableNewsRoleService, roundtableNewsRoleId;
import 'package:chat_group/features/work_mode/work_public_update_stream.dart';
import 'package:chat_group/features/work_mode/agent_decision.dart';
import 'package:chat_group/features/agentic/tool_request.dart';
import 'package:chat_group/features/work_mode/work_tool_registry.dart';
import 'package:chat_group/features/work_mode/work_role_router.dart';
import 'package:chat_group/features/work_mode/work_folder_grant_service.dart';
import 'package:chat_group/features/work_mode/work_mode_directory_service.dart';
import 'package:chat_group/features/work_mode/work_mode_workspace_service.dart';
import 'package:chat_group/features/work_mode/work_task_coordinator.dart';
import 'package:chat_group/features/work_mode/work_task_event_store.dart';
import 'package:chat_group/features/work_mode/work_artifact_delivery_notice.dart';
import 'package:crypto/crypto.dart';
import 'package:chat_group/features/work_mode/workspace_path_policy.dart';
import 'package:chat_group/features/work_mode/workspace_file_service.dart';
import 'package:chat_group/features/work_mode/workspace_mutation_service.dart';
import 'package:chat_group/features/work_mode/work_snapshot_service.dart';
import 'package:flutter_test/flutter_test.dart';
import '../helpers/lifecycle_hive.dart';

part 'work_discussion_v2_test_support.dart';

part 'work_discussion_v2_regressions.dart';
part 'work_discussion_v2_autonomy_test_cases.dart';

void main() {
  test('提示预算只压缩可选聊天预览，不丢个人记忆和协作义务', () {
    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': '固定协议'},
      {
        'role': 'user',
        'content': '【当前成员个人上下文】稳定偏好_dev',
      },
      {
        'role': 'user',
        'content': jsonEncode({
          'userRequest': '继续检查',
          'collaboration': {
            'acceptances': ['must-preserve']
          },
          'recentChatMessages': ['旧消息' * 200, '新消息'],
          'recentDiscussion': ['旧讨论' * 200, '新讨论'],
        }),
      },
    ];
    final compacted = compactDiscussionOptionalPreviews(messages, 300);
    expect(compacted[1]['content'], contains('稳定偏好_dev'));
    final context = jsonDecode(compacted[2]['content'] as String) as Map;
    expect(context['collaboration']['acceptances'], ['must-preserve']);
    expect(context['userRequest'], '继续检查');
    expect(context['recentChatMessages'], ['新消息']);
    expect(context['recentDiscussion'], ['新讨论']);
  });

  _registerDiscussionHistoryRegressions();
  _registerAutonomousDiscussionTests();

  test(
      'REREVIEW2 reused historical delivery event cannot be externally re-signed',
      () async {
    await db.agentTaskBox.put(task.id, task);
    await modelRunner(confirm)
        .runCollaboration(task, WorkTaskCancellation(), apply);
    final before =
        WorkDiscussionState.fromExecutionState(task.executionStateJson)!;
    final current = before.collaboration!;
    const event = 'old-delivery-event-dev';
    final oldSignature = {
      'eventId': event,
      'memberId': 'dev',
      'kind': 'delivery',
      'subjectId': 'r001',
      'requestRevision': current.requestRevision,
      'teamRevision': current.teamRevision,
      'verificationRevision': current.verificationRevision,
      'iterationId': 'r001',
      'artifactDigest': 'digest-r001',
      'approved': true,
      'evidenceRef': 'old-delivery-reply',
      'source': 'memberModel'
    };
    final raw = current.toJson()
      ..['phase'] = 'reviewing'
      ..['verificationRevision'] = current.verificationRevision + 1
      ..['iterations'] = [
        {
          'id': 'r001',
          'artifactDigest': 'digest-r001',
          'requestRevision': current.requestRevision,
          'teamRevision': current.teamRevision,
          'manifestRef': 'candidate:r001',
          'reviewRef': 'report-new',
          'status': 'reviewed'
        }
      ]
      ..['acceptances'] = [
        for (final a in current.acceptances)
          {
            ...a,
            'status': 'passed',
            'evidenceRef': 'report-new',
            'verificationRevision': current.verificationRevision + 1
          }
      ]
      ..['approvals'] = [...current.approvals, oldSignature]
      ..['appliedEventIds'] = [for (var i = 0; i < 64; i++) 'later-event-$i'];
    final checkpoint = WorkCollaborationState.tryParse(raw)!;
    expect(checkpoint.deliveryReady, isFalse);
    expect(checkpoint.appliedEventIds.contains(event), isFalse);
    final root = jsonDecode(task.executionStateJson) as Map<String, dynamic>;
    root[WorkDiscussionState.jsonKey] =
        before.copyWith(collaboration: checkpoint).toJson();
    task.executionStateJson = jsonEncode(root);
    task.status = AgentTaskStatus.paused;
    await db.agentTaskBox.put(task.id, task);
    final next = checkpoint.toJson()
      ..['revision'] = checkpoint.revision + 1
      ..['approvals'] = [
        ...checkpoint.approvals,
        {
          ...oldSignature,
          'verificationRevision': checkpoint.verificationRevision
        }
      ]
      ..['appliedEventIds'] = [...checkpoint.appliedEventIds.skip(1), event];
    final forged = WorkCollaborationState.tryParse(next);
    expect(forged, isNotNull);
    final coordinator = WorkTaskCoordinator(
        taskBox: db.agentTaskBox, runner: execution, eventStore: events);
    addTearDown(coordinator.dispose);
    await expectLater(
        coordinator.applyCollaborationUpdate(WorkCollaborationUpdate(
            taskId: task.id,
            conversationId: task.groupId,
            expectedRevision: checkpoint.revision,
            eventId: event,
            sourceRole: 'member',
            sourceId: 'dev',
            next: forged!)),
        throwsStateError,
        reason: '复用已存在的老签字 eventId 并改成新验证版本，也必须被外部代签门禁拒绝');
  }, timeout: const Timeout(Duration(seconds: 30)));

  for (final (scenario, supplement, expected) in [
    ('negative-ba', '不要把game.html改名为game2.html。', 'game.html'),
    ('negative-jiang', '不能将game.html改名为game2.html。', 'game.html'),
    ('negative-english', "Do not rename game.html to game2.html.", 'game.html'),
    ('evaluate-only', '先讨论把game.html改名为game2.html是否合适，不要实际改名。', 'game.html'),
    (
      'preserve-content-and-rename',
      '在保持内容不变的前提下，把game.html改名为game2.html。',
      'game2.html'
    ),
    (
      'preserve-content-no-comma',
      '在保持内容不变的前提下把game.html改名为game2.html。',
      'game2.html'
    ),
  ]) {
    test('REREVIEW2 contract intent $scenario', () async {
      await db.agentTaskBox.put(task.id, task);
      final coordinator = WorkTaskCoordinator(
          taskBox: db.agentTaskBox, runner: execution, eventStore: events);
      addTearDown(coordinator.dispose);
      await coordinator.enqueueFollowUp(task.id, supplement,
          sourceMessageId: 'rereview2-$scenario');
      final discussion = modelRunner((member, context) async {
        final current =
            Map<String, dynamic>.from(context['collaboration'] as Map);
        if ((current['plan'] as String).isEmpty) {
          final next = proposal(current);
          next['workItems'] = [
            {
              'id': 'implementation',
              'ownerId': current['coordinatorId'],
              'dependencies': <String>[]
            }
          ];
          next['artifactContract'] = {
            ...current['artifactContract'] as Map,
            'location': 'game2.html'
          };
          return _turn('propose', proposal: next);
        }
        return _turn('approve', approval: approval(current));
      });
      await discussion.runCollaboration(task, WorkTaskCancellation(), apply);
      final current =
          WorkDiscussionState.fromExecutionState(task.executionStateJson)!
              .collaboration!;
      expect(current.artifactContract['location'], expected,
          reason: '$supplement; ${task.lastError}');
    }, timeout: const Timeout(Duration(seconds: 30)));
  }
  test('REREVIEW2 stored source contract resumes discussion', () async {
    final root = jsonDecode(task.executionStateJson) as Map<String, dynamic>;
    root[WorkDiscussionState.jsonKey]['collaboration']['artifactContract']
        ['type'] = 'source';
    task.executionStateJson = jsonEncode(root);
    await db.agentTaskBox.put(task.id, task);
    await modelRunner(confirm)
        .runCollaboration(task, WorkTaskCancellation(), apply);
    expect(
        WorkDiscussionState.fromExecutionState(task.executionStateJson)!
            .collaboration!
            .artifactContract['type'],
        'software');
  }, timeout: const Timeout(Duration(seconds: 30)));
  test('REREVIEW2 stored ready source cannot bypass software contract',
      () async {
    await db.agentTaskBox.put(task.id, task);
    final discussion = modelRunner(confirm);
    await discussion.runCollaboration(task, WorkTaskCancellation(), apply);
    final before =
        WorkDiscussionState.fromExecutionState(task.executionStateJson)!
            .collaboration!;
    expect(before.productionReady, isTrue);
    expect(before.artifactContract['files'], isNull);
    expect(before.artifactContract['verificationCommands'], isNull);
    final root = jsonDecode(task.executionStateJson) as Map<String, dynamic>;
    root[WorkDiscussionState.jsonKey]['collaboration']['artifactContract']
        ['type'] = 'source';
    task.executionStateJson = jsonEncode(root);
    await db.agentTaskBox.put(task.id, task);
    await discussion.runCollaboration(task, WorkTaskCancellation(), apply);
    final prepared = await execution.prepareCollaborationWork(task);
    expect(prepared, isFalse,
        reason:
            '缺软件 files/verificationCommands 的旧 source 任务不应进入制作：${task.executionStateJson}');
  }, timeout: const Timeout(Duration(seconds: 30)));

  setUp(_openFixture);
  tearDown(_closeFixture);

  test('协调者返修正式方案时收到全部未决口径问题清单', () async {
    await modelRunner(confirm)
        .runCollaboration(task, WorkTaskCancellation(), apply);
    final shell =
        WorkDiscussionState.fromExecutionState(task.executionStateJson)!;
    final before = shell.collaboration!;
    final raw = before.toJson()
      ..['phase'] = 'clarifying'
      ..['revision'] = before.revision + 1
      ..['verificationRevision'] = before.verificationRevision + 1
      ..['issues'] = [
        ...before.issues,
        for (final entry in const [
          ('plan-count-gap', 'A-02 步数不匹配', '逐项重算固定骰点路径'),
          ('plan-assertion-gap', '步骤合并多个断言', '每步只保留一条断言'),
        ])
          {
            'id': entry.$1,
            'sourceId': 'qa',
            'kind': 'defect',
            'status': 'open',
            'target': 'plan',
            'problem': entry.$2,
            'evidenceRef': 'review-${entry.$1}',
            'resolution': '',
            'resolutionRef': '',
            'retestCondition': entry.$3,
            'requestRevision': before.requestRevision - 1,
          }
      ];
    final updated = WorkCollaborationState.tryParse(raw)!;
    task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
      task.executionStateJson,
      shell.copyWith(collaboration: updated),
      expectedCollaborationRevision: before.revision,
    );

    final turns = <({String memberId, Map<String, dynamic> focus})>[];
    await modelRunner((member, context) async {
      turns.add((
        memberId: member.id,
        focus: Map<String, dynamic>.from(context['turnFocus'] as Map),
      ));
      if (turns.length == 1) {
        return _turn('respond', text: '正式方案仍有缺口，请协调者集中修订。');
      }
      return _turn('decide', decision: {
        'kind': 'question',
        'targetId': '',
        'reason': '隔离夹具停止后续讨论',
        'evidence': '已核对返修清单',
        'impact': '不执行制作',
        'options': <Map<String, dynamic>>[],
      });
    }).runCollaboration(task, WorkTaskCancellation(), apply);

    expect(turns.map((turn) => turn.memberId).take(2),
        ['qa', before.coordinatorId]);
    final checklist =
        (turns.last.focus['formalPlanRevisionChecklist'] as List).cast<Map>();
    expect(checklist.map((issue) => issue['id']),
        ['plan-count-gap', 'plan-assertion-gap']);
    expect(
        checklist.map((issue) => issue['problem']), ['A-02 步数不匹配', '步骤合并多个断言']);
    expect(checklist.map((issue) => issue['retestCondition']),
        ['逐项重算固定骰点路径', '每步只保留一条断言']);
  }, timeout: const Timeout(Duration(seconds: 30)));

  for (final scenario in ['granted', 'revoked', 'defect', 'other-task']) {
    test('目录授权证据来自当前授权服务且不代替执行证据：$scenario', () async {
      await modelRunner(confirm, workspaceService: execution.workspaceService)
          .runCollaboration(task, WorkTaskCancellation(), apply);
      final shell =
          WorkDiscussionState.fromExecutionState(task.executionStateJson)!;
      final before = shell.collaboration!;
      final raw = before.toJson()
        ..['phase'] = 'clarifying'
        ..['revision'] = before.revision + 1
        ..['issues'] = [
          {
            'id': 'folder-question',
            'sourceId': 'dev',
            'kind': scenario == 'defect' ? 'defect' : 'decision',
            'status': 'open',
            'target': '交付目录授权',
            'problem': '历史提醒说尚未授权',
            'evidenceRef':
                'work-task-action:${scenario == 'other-task' ? 'other' : task.id}:folderAuthorization:1',
            'resolution': '',
            'resolutionRef': '',
            'retestCondition': '核对实际授权状态',
            'requestRevision': before.requestRevision,
          }
        ];
      task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
        task.executionStateJson,
        shell.copyWith(collaboration: WorkCollaborationState.tryParse(raw)),
        expectedCollaborationRevision: before.revision,
      );
      Map<String, dynamic>? capturedAuthorization;
      Map<String, dynamic>? original;
      String? reference;
      await modelRunner((member, context) async {
        if (context.containsKey('originalFinal')) return original!;
        if (original == null) {
          capturedAuthorization = Map<String, dynamic>.from(
              context['collaboration']['folderAuthorization'] as Map);
          reference = (context['availableResolutionEvidence'] as List)
                  .cast<Map>()
                  .firstWhere((e) => e['kind'] == 'folder-authorization')['ref']
              as String;
          if (scenario == 'revoked') {
            await execution.folderGrantService!
                .removeDirectory(capturedAuthorization!['rootPath'] as String);
          }
          original = _turn('respond', resolutions: [
            {
              'id': 'folder-question',
              'resolution': '当前授权服务已确认目录可写',
              'evidenceRef': reference,
            }
          ]);
          return original!;
        }
        return _turn('decide', decision: {
          'kind': 'question',
          'targetId': '',
          'reason': '隔离夹具停止',
          'evidence': '只验证目录授权证据边界',
          'impact': '不制作文件',
          'options': [],
        });
      }, workspaceService: execution.workspaceService)
          .runCollaboration(task, WorkTaskCancellation(), apply);
      final after =
          WorkDiscussionState.fromExecutionState(task.executionStateJson)!
              .collaboration!;
      expect(capturedAuthorization?['status'], 'granted');
      expect(after.issues.single['status'],
          scenario == 'granted' ? 'resolved' : 'open');
      expect(after.acceptances.every((a) => a['status'] == 'pending'), isTrue);
      expect(after.iterations, isEmpty);
      final detail =
          await events.readDiscussionDetail(task.id, reference!.substring(13));
      expect(jsonDecode(detail)['status'], 'granted');
      expect(
          'folder-grant:${sha256.convert(utf8.encode(detail)).toString().substring(0, 24)}',
          reference);
    }, timeout: const Timeout(Duration(seconds: 30)));
  }

  for (final scenario in [
    'author',
    'other-member',
    'code',
    'unchanged-plan',
    'superseded-candidate',
    'current-candidate'
  ]) {
    test('正式方案证据仅关闭提出者的修订前方案问题：$scenario', () async {
      await modelRunner(confirm)
          .runCollaboration(task, WorkTaskCancellation(), apply);
      final shell =
          WorkDiscussionState.fromExecutionState(task.executionStateJson)!;
      final before = shell.collaboration!;
      final raw = before.toJson()
        ..['phase'] = 'clarifying'
        ..['requestRevision'] = scenario == 'superseded-candidate'
            ? before.requestRevision + 1
            : before.requestRevision
        ..['revision'] = before.revision + 1
        ..['iterations'] =
            {'superseded-candidate', 'current-candidate'}.contains(scenario)
                ? [
                    {
                      'id': 'r004',
                      'artifactDigest': 'old-candidate-digest',
                      'requestRevision': before.requestRevision,
                      'teamRevision': before.teamRevision,
                      'manifestRef': 'candidate:r004',
                      'reviewRef': 'old-report',
                      'status': 'reviewed',
                    }
                  ]
                : before.iterations
        ..['issues'] = [
          {
            'id': 'plan-clarity',
            'sourceId':
                scenario == 'other-member' ? 'original-reviewer' : 'dev',
            'kind': 'defect',
            'status': 'open',
            'target': scenario == 'code' ? 'code' : 'plan',
            'problem': '选子步骤需要明确',
            'evidenceRef': 'original-review',
            'resolution': '',
            'resolutionRef': '',
            'retestCondition': '提出者核对修订后的完整正式方案',
            'requestRevision': scenario == 'unchanged-plan'
                ? before.requestRevision
                : scenario == 'superseded-candidate'
                    ? before.requestRevision
                    : before.requestRevision - 1,
          }
        ];
      final updated = WorkCollaborationState.tryParse(raw)!;
      task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
          task.executionStateJson,
          shell.copyWith(
              collaboration: updated, requestRevision: updated.requestRevision),
          expectedCollaborationRevision: before.revision);
      var attempted = false;
      Map<String, dynamic>? original;
      String? reference;
      final runner = modelRunner((member, context) async {
        if (context.containsKey('originalFinal')) return original!;
        if (!attempted) {
          attempted = true;
          final evidence =
              (context['availableResolutionEvidence'] as List).cast<Map>();
          if (scenario == 'current-candidate') {
            expect(
                evidence.any((item) => item['kind'] == 'formal-plan'), isFalse);
            return _turn('decide', decision: {
              'kind': 'question',
              'targetId': '',
              'reason': '保留当前候选的正式验收流程',
              'evidence': '当前版本候选仍需通过软件测试关闭问题。',
              'impact': '不执行制作',
              'options': <Map<String, dynamic>>[],
            });
          }
          reference = evidence
              .firstWhere((e) => e['kind'] == 'formal-plan')['ref'] as String;
          original = _turn('respond', resolutions: [
            {
              'id': 'plan-clarity',
              'resolution': '本人已核对修订后的正式方案，点击步骤明确。',
              'evidenceRef': reference,
            }
          ]);
          return original!;
        }
        return _turn('decide', decision: {
          'kind': 'question',
          'targetId': '',
          'reason': '隔离夹具停止后续讨论',
          'evidence': '保留本次解决项采纳结果',
          'impact': '不执行制作',
          'options': <Map<String, dynamic>>[],
        });
      });
      await runner.runCollaboration(task, WorkTaskCancellation(), apply);
      final after =
          WorkDiscussionState.fromExecutionState(task.executionStateJson)!
              .collaboration!;
      expect(attempted, isTrue);
      expect(
          after.issues.single['status'],
          {'author', 'superseded-candidate'}.contains(scenario)
              ? 'resolved'
              : 'open');
      expect(after.acceptances.every((a) => a['status'] == 'pending'), isTrue);
      expect(
          after.iterations.map((item) => item['id']),
          {'superseded-candidate', 'current-candidate'}.contains(scenario)
              ? ['r004']
              : isEmpty);
      if (reference != null) {
        final detail =
            await events.readDiscussionDetail(task.id, reference!.substring(5));
        expect(
            'plan:${sha256.convert(utf8.encode(detail)).toString().substring(0, 24)}',
            reference);
        expect(jsonDecode(detail)['plan'], before.plan);
      }
    }, timeout: const Timeout(Duration(seconds: 30)));
  }

  for (final stale in [false, true]) {
    test('待审提案完整上下文与过期修订路由：$stale', () async {
      await db.agentTaskBox.put(task.id, task);
      final shell = WorkDiscussionState.fromExecutionState(
        task.executionStateJson,
      )!;
      final current = shell.collaboration!;
      final candidate = proposal(current.toJson())
        ..['plan'] = '候选方案正文，含五条实际试玩步骤。'
        ..['artifactContract'] = {
          ...current.artifactContract,
          'verificationCommands': [
            jsonEncode({'executable': 'true', 'arguments': <String>[]})
          ],
        };
      final serialized = jsonEncode(candidate);
      final digest =
          sha256.convert(utf8.encode(serialized)).toString().substring(0, 24);
      await events.writeDiscussionDetail(task.id, digest, serialized);
      const issueId = 'pending-proposal-review';
      final raw = current.toJson()
        ..['revision'] = current.revision + 1
        ..['requestRevision'] = current.requestRevision + (stale ? 1 : 0)
        ..['verificationRevision'] = current.verificationRevision + 1
        ..['issues'] = [
          {
            'id': 'earlier-open-defect',
            'sourceId': 'qa',
            'kind': 'defect',
            'status': 'open',
            'target': 'verification',
            'problem': '已有缺陷仍待解决。',
            'evidenceRef': 'existing-test-evidence',
            'resolution': '',
            'resolutionRef': '',
            'retestCondition': '保留缺陷并让成员核对完整候选提案。',
            'requestRevision': current.requestRevision,
          },
          ...current.issues,
          {
            'id': issueId,
            'sourceId': 'dev',
            'kind': 'idea',
            'status': 'open',
            'target': 'plan',
            'problem': '核对完整候选方案及独立验证命令。',
            'evidenceRef': 'proposal-request',
            'resolution': 'scope-proposal',
            'resolutionRef': 'proposal:$digest',
            'retestCondition': '成员依据完整候选方案逐项审阅。',
            'requestRevision': current.requestRevision,
          }
        ];
      String? invalidSection;
      final pending = WorkCollaborationState.tryParse(
        raw,
        onInvalid: (section) => invalidSection = section,
      );
      expect(pending, isNotNull, reason: '协作状态字段：$invalidSection');
      task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
        task.executionStateJson,
        shell.copyWith(
            requestRevision: pending!.requestRevision, collaboration: pending),
        expectedCollaborationRevision: current.revision,
      );
      await db.agentTaskBox.put(task.id, task);

      final contexts = <Map<String, dynamic>>[];
      final focuses = <Map<String, dynamic>>[];
      final speakers = <String>[];
      final runner = modelRunner((member, context) async {
        focuses.add(Map<String, dynamic>.from(context['turnFocus'] as Map));
        speakers.add(member.id);
        contexts
            .add(Map<String, dynamic>.from(context['collaboration'] as Map));
        if (contexts.length == 1) {
          return {'success': true, 'message': 'not-json'};
        }
        if (stale && contexts.length == 2) {
          return _turn('propose', issue: issueId, proposal: candidate);
        }
        if (stale && context['collaboration']['pendingProposal'] != null) {
          return _turn('approve', approval: {
            ...approval(
                Map<String, dynamic>.from(context['collaboration'] as Map)),
            'kind': 'idea',
            'subjectId': issueId,
          });
        }
        return _turn('decide', decision: {
          'kind': 'question',
          'targetId': issueId,
          'reason': '测试在读取候选后暂停。',
          'evidence': '只验证请求上下文，不裁定候选。',
          'impact': '保留当前正式方案。',
          'options': <Map<String, dynamic>>[],
        });
      });
      await runner.runCollaboration(task, WorkTaskCancellation(), apply);

      expect(contexts.length, stale ? greaterThan(3) : 2,
          reason: '过期提案必须重新提交并逐人认可，正常提案只请求一次协议修复。');
      for (var index = 0; index < 2; index++) {
        if (stale) {
          expect(speakers[index], contexts[index]['coordinatorId']);
          expect(focuses[index]['stage'],
              WorkDiscussionStage.prepareProposal.name);
          expect(focuses[index]['issueId'], issueId);
        } else {
          expect(focuses[index]['approvalIdentifiers']['subjectId'], issueId);
        }
      }
      for (final captured in contexts.take(2)) {
        expect(captured['plan'], current.plan);
        expect(captured['artifactContract']['verificationCommands'],
            current.artifactContract['verificationCommands']);
        expect(captured['issues'].first['id'], 'earlier-open-defect');
        final key = stale ? 'previousProposal' : 'pendingProposal';
        expect(captured[key]['issueId'], issueId);
        expect(captured[key]['proposal'], candidate);
        expect(captured[key]['requestRevision'], current.requestRevision);
        expect(
            captured
                .containsKey(stale ? 'pendingProposal' : 'previousProposal'),
            isFalse);
      }
      expect(
        WorkDiscussionState.fromExecutionState(task.executionStateJson)!
            .collaboration!
            .plan,
        stale ? candidate['plan'] : current.plan,
        reason: '提案仅进入评审上下文，不能提前改写正式方案。',
      );
      expect(await events.readDiscussionDetail(task.id, digest), serialized,
          reason: '修订不能改写旧提案证据。');
    }, timeout: const Timeout(Duration(seconds: 30)));
  }

  test('待审提案缺少详情引用时暂停而不回退到旧方案', () async {
    await db.agentTaskBox.put(task.id, task);
    final shell = WorkDiscussionState.fromExecutionState(
      task.executionStateJson,
    )!;
    final current = shell.collaboration!;
    final raw = current.toJson()
      ..['revision'] = current.revision + 1
      ..['issues'] = [
        ...current.issues,
        {
          'id': 'proposal-without-reference',
          'sourceId': 'dev',
          'kind': 'idea',
          'status': 'open',
          'target': 'plan',
          'problem': '候选方案详情没有可核验的引用。',
          'evidenceRef': 'proposal-request',
          'resolution': 'scope-proposal',
          'resolutionRef': '',
          'retestCondition': '恢复完整提案后再逐人评审。',
          'requestRevision': current.requestRevision,
        }
      ];
    final pending = WorkCollaborationState.tryParse(raw);
    expect(pending, isNotNull);
    task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
      task.executionStateJson,
      shell.copyWith(collaboration: pending),
      expectedCollaborationRevision: current.revision,
    );
    await db.agentTaskBox.put(task.id, task);

    var calls = 0;
    final runner = modelRunner((member, context) async {
      calls++;
      return _turn('respond', text: '不应在缺少提案时评审旧方案。');
    });
    await runner.runCollaboration(task, WorkTaskCancellation(), apply);

    final after = WorkDiscussionState.fromExecutionState(
      task.executionStateJson,
    )!
        .collaboration!;
    expect(calls, 0);
    expect(after.plan, current.plan);
    expect(after.hasPendingDecision, isTrue);
    expect(
      after.decisions.last['reason'],
      contains('没有关联可核验的完整详情'),
    );
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('同轮新增问题后保留证据并跳过旧验证版本认可', () async {
    await db.agentTaskBox.put(task.id, task);
    final before =
        WorkDiscussionState.fromExecutionState(task.executionStateJson)!
            .collaboration!;
    var responses = 0;
    final runner = modelRunner((member, context) async {
      responses++;
      if (responses == 1) {
        return _turn(
          'approve',
          text: '我记录了问题，认可需在问题处理后重新确认。',
          issues: [
            {
              'id': 'same-turn-defect',
              'kind': 'defect',
              'target': 'dev',
              'problem': '本轮测试发现待处理问题。',
              'evidenceRef': '',
              'retestCondition': '责任人修复后由测试成员复现。',
            }
          ],
          approval: approval(context['collaboration'] as Map<String, dynamic>),
        );
      }
      return _turn('decide', decision: {
        'kind': 'question',
        'targetId': 'same-turn-defect',
        'reason': '测试夹具暂停后续缺陷处理。',
        'evidence': '保留本轮真实问题记录。',
        'impact': '等待后续修复与复测。',
        'options': <Map<String, dynamic>>[],
      });
    });
    await runner.runCollaboration(task, WorkTaskCancellation(), apply);

    final after =
        WorkDiscussionState.fromExecutionState(task.executionStateJson)!
            .collaboration!;
    expect(responses, greaterThanOrEqualTo(2));
    expect(after.approvals.length, before.approvals.length,
        reason: '同轮问题更新验证版本后，旧版本认可不能落盘。');
    final defect =
        after.issues.singleWhere((issue) => issue['id'] == 'same-turn-defect');
    expect(defect['evidenceRef'], isNotEmpty);
    final response = db.messageBox.get(defect['evidenceRef']);
    expect(response?.content, contains('我记录了问题'));
    expect(response?.content, isNot(contains('【未采纳】')),
        reason: '已经被问题引用的原始证据不被改写。');
    expect(
      db.messageBox.values
          .any((message) => message.content.contains('本轮认可未写入')),
      isTrue,
      reason: '群内要明确说明本轮认可没有生效及原因。',
    );
    expect(task.lastError, isNot(contains('认可版本已过期')));
  }, timeout: const Timeout(Duration(seconds: 30)));

  for (final proposedPath in [r'c:\WORK\output', 'D:/unauthorized']) {
    test('Windows pinned location preserves authorization: $proposedPath',
        () async {
      await db.agentTaskBox.put(task.id, task);
      final root = jsonDecode(task.executionStateJson) as Map<String, dynamic>;
      final collaboration = root[WorkDiscussionState.jsonKey]['collaboration']
          as Map<String, dynamic>;
      collaboration['scope'] = r'请在 C:\work\output 保存文件。';
      collaboration['artifactContract']['location'] = 'C:/work/output';
      task.executionStateJson = jsonEncode(root);
      var rejected = false;
      final discussion = modelRunner((member, context) async {
        final state =
            Map<String, dynamic>.from(context['collaboration'] as Map);
        rejected = rejected ||
            context['lastValidationError'].toString().contains('用户产物合同不可覆盖');
        if ((state['plan'] as String).isEmpty) {
          final next = proposal(state);
          next['artifactContract'] = {
            ...state['artifactContract'] as Map,
            'location': proposedPath
          };
          return _turn('propose', text: '按合同保存文件。', proposal: next);
        }
        return _turn('approve', approval: approval(state));
      });
      await discussion.runCollaboration(task, WorkTaskCancellation(), apply);
      final after =
          WorkDiscussionState.fromExecutionState(task.executionStateJson)!
              .collaboration!;
      if (proposedPath.startsWith('D:')) {
        expect(after.artifactContract['location'], 'C:/work/output');
        expect(rejected, isTrue);
      } else {
        expect(after.artifactContract['location'], proposedPath,
            reason: task.lastError);
        expect(after.plan, isNotEmpty, reason: task.lastError);
        expect(rejected, isFalse);
      }
    }, timeout: const Timeout(Duration(seconds: 30)));
  }

  test('推导出来的 location 允许协调成员提案改写', () async {
    await db.agentTaskBox.put(task.id, task);
    final root = jsonDecode(task.executionStateJson) as Map<String, dynamic>;
    final collaboration = root[WorkDiscussionState.jsonKey]['collaboration']
        as Map<String, dynamic>;
    // 现场形态：用户给的是目录路径，合同里的 desktop 是兜底推导值。
    collaboration['scope'] = '在 /Users/fengye/Desktop/chat_group_out 这个文件夹中'
        '创建一个目录，目录中的内容生成一份 飞行棋游戏的HTML';
    collaboration['artifactContract']['location'] = 'desktop';
    task.executionStateJson = jsonEncode(root);
    final discussion = modelRunner((member, context) async {
      final state = Map<String, dynamic>.from(context['collaboration'] as Map);
      if ((state['plan'] as String).isEmpty) {
        final next = proposal(state);
        next['artifactContract'] = {
          ...state['artifactContract'] as Map,
          'location': '/Users/fengye/Desktop/chat_group_out/flight-chess'
        };
        return _turn('propose', text: '按用户给出的目录补齐位置。', proposal: next);
      }
      return _turn('approve', approval: approval(state));
    });
    await discussion.runCollaboration(task, WorkTaskCancellation(), apply);
    final after =
        WorkDiscussionState.fromExecutionState(task.executionStateJson)!
            .collaboration!;
    expect(after.artifactContract['location'],
        '/Users/fengye/Desktop/chat_group_out/flight-chess',
        reason: task.lastError);
    expect(after.requestRevision, greaterThan(1),
        reason: '改写合同必须一并递增需求版本，否则 _validateBaselineChanges 会拒绝这次增量');
    expect(
        after.acceptances
            .every((a) => a['requestRevision'] == after.requestRevision),
        isTrue,
        reason: '旧需求版本的验收必须随需求版本递增而失效');
    expect(
        after.workItems
            .every((i) => i['requestRevision'] == after.requestRevision),
        isTrue,
        reason: '旧需求版本的工作项必须随需求版本递增而失效');
  }, timeout: const Timeout(Duration(seconds: 30)));
  test('目录型请求的 unspecified location 由成员补齐后仍能进入方案', () async {
    await db.agentTaskBox.put(task.id, task);
    final root = jsonDecode(task.executionStateJson) as Map<String, dynamic>;
    final collaboration = root[WorkDiscussionState.jsonKey]['collaboration']
        as Map<String, dynamic>;
    // 目录型请求（用户给的是目录、不是文件）在词元判据之后 location 落
    // unspecified，而 planReady 要求它非 unspecified：必须由成员补齐。
    collaboration['scope'] = '在 /Users/fengye/Desktop/chat_group_out 这个文件夹中'
        '创建一个目录，目录中的内容生成一份 飞行棋游戏的HTML';
    collaboration['artifactContract']['location'] = 'unspecified';
    task.executionStateJson = jsonEncode(root);
    final discussion = modelRunner((member, context) async {
      final state = Map<String, dynamic>.from(context['collaboration'] as Map);
      if ((state['plan'] as String).isEmpty) {
        final next = proposal(state);
        next['artifactContract'] = {
          ...state['artifactContract'] as Map,
          'location': '/Users/fengye/Desktop/chat_group_out/flight-chess'
        };
        return _turn('propose', text: '按用户给出的目录补齐交付位置。', proposal: next);
      }
      return _turn('approve', approval: approval(state));
    });
    await discussion.runCollaboration(task, WorkTaskCancellation(), apply);
    final after =
        WorkDiscussionState.fromExecutionState(task.executionStateJson)!;
    expect(after.collaboration!.artifactContract['location'],
        '/Users/fengye/Desktop/chat_group_out/flight-chess');
    expect(after.isPlanReady, isTrue,
        reason: 'location 补齐后必须能过 planReady 门禁：${task.lastError}');
  }, timeout: const Timeout(Duration(seconds: 30)));
  test('用户用中文说的格式仍不可覆盖', () async {
    await db.agentTaskBox.put(task.id, task);
    final root = jsonDecode(task.executionStateJson) as Map<String, dynamic>;
    final collaboration = root[WorkDiscussionState.jsonKey]['collaboration']
        as Map<String, dynamic>;
    // 「网页」不在 formatAliases 里，但它就是路由自己认的 html 格式词：用户
    // 用中文点名了格式，合同里的 html 属于用户声明，模型不得改写。
    collaboration['scope'] = '做一个飞行棋的网页';
    collaboration['artifactContract']['format'] = 'html';
    task.executionStateJson = jsonEncode(root);
    var sawRejection = false;
    final discussion = modelRunner((member, context) async {
      sawRejection = sawRejection ||
          context['lastValidationError'].toString().contains('用户产物合同不可覆盖');
      final state = Map<String, dynamic>.from(context['collaboration'] as Map);
      if ((state['plan'] as String).isEmpty) {
        final next = proposal(state);
        next['artifactContract'] = {
          ...state['artifactContract'] as Map,
          'format': 'docx'
        };
        return _turn('propose', text: '换个交付格式。', proposal: next);
      }
      return _turn('approve', approval: approval(state));
    });
    await discussion.runCollaboration(task, WorkTaskCancellation(), apply);
    expect(sawRejection, isTrue, reason: '「网页」就是用户点名的 html 格式');
    expect(
        WorkDiscussionState.fromExecutionState(task.executionStateJson)!
            .collaboration!
            .artifactContract['format'],
        'html');
  }, timeout: const Timeout(Duration(seconds: 30)));
  test('用户亲口说出的 location 仍不可覆盖', () async {
    await db.agentTaskBox.put(task.id, task);
    final root = jsonDecode(task.executionStateJson) as Map<String, dynamic>;
    final collaboration = root[WorkDiscussionState.jsonKey]['collaboration']
        as Map<String, dynamic>;
    collaboration['scope'] = '生成一份飞行棋游戏的HTML，保存到桌面';
    collaboration['artifactContract']['location'] = 'desktop';
    task.executionStateJson = jsonEncode(root);
    var sawRejection = false;
    final discussion = modelRunner((member, context) async {
      sawRejection = sawRejection ||
          context['lastValidationError'].toString().contains('用户产物合同不可覆盖');
      final state = Map<String, dynamic>.from(context['collaboration'] as Map);
      if ((state['plan'] as String).isEmpty) {
        final next = proposal(state);
        next['artifactContract'] = {
          ...state['artifactContract'] as Map,
          'location': '/tmp/elsewhere'
        };
        return _turn('propose', text: '换个位置。', proposal: next);
      }
      return _turn('approve', approval: approval(state));
    });
    await discussion.runCollaboration(task, WorkTaskCancellation(), apply);
    expect(sawRejection, isTrue, reason: '用户说过"保存到桌面"，模型不得改写这个值');
    expect(
        WorkDiscussionState.fromExecutionState(task.executionStateJson)!
            .collaboration!
            .artifactContract['location'],
        'desktop');
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('合同值不在 scope 里时判为推导值', () async {
    await db.agentTaskBox.put(task.id, task);
    final root = jsonDecode(task.executionStateJson) as Map<String, dynamic>;
    final collaboration = root[WorkDiscussionState.jsonKey]['collaboration']
        as Map<String, dynamic>;
    // 与"补充要求超过 4096 字符被丢弃"、"location 已被脱敏成 [本地路径]"
    // 相同的可观测形态：合同里有一个原话从未点过的值。
    collaboration['scope'] = '生成一份飞行棋游戏的HTML';
    collaboration['artifactContract']['location'] = '[本地路径]';
    collaboration['artifactContract']['revisionTarget'] = '';
    task.executionStateJson = jsonEncode(root);
    final discussion = modelRunner((member, context) async {
      final state = Map<String, dynamic>.from(context['collaboration'] as Map);
      if ((state['plan'] as String).isEmpty) {
        final next = proposal(state);
        next['artifactContract'] = {
          ...state['artifactContract'] as Map,
          'location': 'flight-chess.html'
        };
        return _turn('propose', text: '补齐实际交付位置。', proposal: next);
      }
      return _turn('approve', approval: approval(state));
    });
    await discussion.runCollaboration(task, WorkTaskCancellation(), apply);
    expect(
        WorkDiscussionState.fromExecutionState(task.executionStateJson)!
            .collaboration!
            .artifactContract['location'],
        'flight-chess.html',
        reason: task.lastError);
  }, timeout: const Timeout(Duration(seconds: 30)));
  test('用户明确改名后合同随之修订，模型擅改仍被拒', () async {
    await db.agentTaskBox.put(task.id, task);
    final coordinator = WorkTaskCoordinator(
        taskBox: db.agentTaskBox, runner: execution, eventStore: events);
    addTearDown(coordinator.dispose);
    await coordinator.enqueueFollowUp(
        task.id, '请将输出文件从 game.html 改名为 game2.html，内容与验收要求沿用原方案。',
        sourceMessageId: 'review-user-output-rename');
    var renameProposalCalls = 0;
    var sawPinnedContractRejection = false;
    final discussion = modelRunner((member, context) async {
      renameProposalCalls++;
      // 模型这次提案仍按旧合同被拒（它是在旧版本下写的）：用户授权只由用户身份
      // 落盘，模型不能借"用户授权"之名改合同。
      sawPinnedContractRejection = sawPinnedContractRejection ||
          context['lastValidationError'].toString().contains('用户产物合同不可覆盖');
      final state = Map<String, dynamic>.from(context['collaboration'] as Map);
      if ((state['plan'] as String).isEmpty) {
        final next = proposal(state);
        next['workItems'] = [
          {
            'id': 'implementation',
            'ownerId': state['coordinatorId'],
            'dependencies': <String>[]
          }
        ];
        next['artifactContract'] = {
          ...state['artifactContract'] as Map,
          'location': 'game2.html'
        };
        return _turn('propose', text: '按用户补充改名，保持原功能与验收要求。', proposal: next);
      }
      return _turn('approve', approval: approval(state));
    });
    await discussion.runCollaboration(task, WorkTaskCancellation(), apply);
    expect(renameProposalCalls, greaterThan(0));
    expect(sawPinnedContractRejection, isTrue,
        reason:
            jsonEncode(db.messageBox.values.map((m) => m.content).toList()));
    expect(
        WorkDiscussionState.fromExecutionState(task.executionStateJson)!
            .collaboration!
            .artifactContract['location'],
        'game2.html',
        reason: '$renameProposalCalls model calls; ${task.lastError}');
  }, timeout: const Timeout(Duration(seconds: 30)));
  test('用户明确改格式后合同随之修订，别名拼写也算点名', () async {
    await db.agentTaskBox.put(task.id, task);
    final coordinator = WorkTaskCoordinator(
        taskBox: db.agentTaskBox, runner: execution, eventStore: events);
    addTearDown(coordinator.dispose);
    // 用户写 "Word"，合同里存的是 `docx`：同一个交付格式的两种拼写，必须算用户
    // 点过名，否则格式调整永远被旧合同钉住。
    await coordinator.enqueueFollowUp(
        task.id, '请把输出格式从 html 改成 Word（.docx），其余要求沿用原方案。',
        sourceMessageId: 'review-user-output-format');
    final discussion = modelRunner((member, context) async {
      final state = Map<String, dynamic>.from(context['collaboration'] as Map);
      if ((state['plan'] as String).isEmpty) {
        final next = proposal(state);
        next['workItems'] = [
          {
            'id': 'implementation',
            'ownerId': state['coordinatorId'],
            'dependencies': <String>[]
          }
        ];
        next['artifactContract'] = {
          ...state['artifactContract'] as Map,
          'format': 'docx'
        };
        return _turn('propose', text: '按用户补充换输出格式。', proposal: next);
      }
      return _turn('approve', approval: approval(state));
    });
    await discussion.runCollaboration(task, WorkTaskCancellation(), apply);
    expect(
        WorkDiscussionState.fromExecutionState(task.executionStateJson)!
            .collaboration!
            .artifactContract['format'],
        'docx',
        reason: task.lastError);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('模型用 v1 的 source 别名提案，合同仍收敛成 software', () async {
    // 合同条目只有一个词表：等价校验会放行 `source`/`software`，但原样落盘会让
    // 软件材料、测试覆盖与独立审查资格整段失效。
    await db.agentTaskBox.put(task.id, task);
    final discussion = modelRunner((member, context) async {
      final current =
          Map<String, dynamic>.from(context['collaboration'] as Map);
      if ((current['plan'] as String).isEmpty) {
        final next = proposal(current);
        next['artifactContract'] = {
          ...current['artifactContract'] as Map,
          'type': 'source'
        };
        return _turn('propose', proposal: next);
      }
      return _turn('approve', approval: approval(current));
    });
    await discussion.runCollaboration(task, WorkTaskCancellation(), apply);
    expect(
        WorkDiscussionState.fromExecutionState(task.executionStateJson)!
            .collaboration!
            .artifactContract['type'],
        'software',
        reason: task.lastError);
  }, timeout: const Timeout(Duration(seconds: 30)));

  for (final (scenario, supplement, expected) in [
    // 名称共现不是授权：两个名称都在，却是用户禁止改名。
    ('禁止改名', '保持 game.html 文件名，不要改成 game2.html。', 'game.html'),
    // 否定也可能只出现在目标之后。
    ('后置否定', '把 game.html 改成 game2.html 是不允许的。', 'game.html'),
    // 中文里名称与汉字直接相邻不需要空格，这是正常的改名句式。
    ('无空格改名', '把game.html改名为game2.html，其余要求不变。', 'game2.html'),
  ]) {
    test('用户补充里的改名授权判定：$scenario', () async {
      await db.agentTaskBox.put(task.id, task);
      final coordinator = WorkTaskCoordinator(
          taskBox: db.agentTaskBox, runner: execution, eventStore: events);
      addTearDown(coordinator.dispose);
      await coordinator.enqueueFollowUp(task.id, supplement,
          sourceMessageId: 'user-rename-$scenario');
      var proposed = 0;
      final discussion = modelRunner((member, context) async {
        final current =
            Map<String, dynamic>.from(context['collaboration'] as Map);
        if ((current['plan'] as String).isEmpty) {
          proposed++;
          final next = proposal(current);
          next['workItems'] = [
            {
              'id': 'implementation',
              'ownerId': current['coordinatorId'],
              'dependencies': <String>[]
            }
          ];
          next['artifactContract'] = {
            ...current['artifactContract'] as Map,
            'location': 'game2.html'
          };
          return _turn('propose', proposal: next);
        }
        return _turn('approve', approval: approval(current));
      });
      await discussion.runCollaboration(task, WorkTaskCancellation(), apply);
      expect(proposed, greaterThan(0));
      expect(
          WorkDiscussionState.fromExecutionState(task.executionStateJson)!
              .collaboration!
              .artifactContract['location'],
          expected);
    }, timeout: const Timeout(Duration(seconds: 30)));
  }

  _registerDocumentInvestigationTest();
  _registerProgressGuardTest();
  _registerFailureBoundaryTest();
  _registerScopeBoundaryTest();
  for (final reads in [0, 1, 97]) {
    test('不同成员真实接线：$reads 次读取后当前方案逐人认可', () async {
      for (final id in ['dev', 'qa']) {
        db.aiCharacterBox.get(id)!.personalityTags = [
          id == 'dev' ? '直接' : '谨慎'
        ];
        await db.permanentMemoryBox.put(
            'preference-$id',
            PermanentMemory(
              observerCharacterId: id,
              kind: MemoryKind.preference,
              content: '用户对读取报告的稳定偏好_$id',
              subjectIds: ['user'],
              status: MemoryStatus.active,
              originType: MemoryOriginType.manual,
              originNameSnapshot: '用户明确维护的偏好',
            ));
        await db.relationshipStateBox.put(
            'relation-$id',
            RelationshipState(
              id: 'rel:$id:user:global',
              groupId: 'global',
              sourceCharacterId: id,
              targetId: 'user',
              targetType: RelationshipTargetType.user,
              recentMood: RelationshipMood.warm,
              recentMoodAt: DateTime.now()
                  .subtract(Duration(minutes: id == 'dev' ? 1 : 60)),
            ));
      }
      var calls = 0;
      var readCount = 0;
      final identities = <String>[];
      // 断言必须留在回调之外：回调里抛出的异常会被 `_request` 的
      // `on Object catch` 收成"成员请求失败"，断言不会报出它自己的原因。
      final wiring = <({
        String characterId,
        String configId,
        String systemContent,
        String personal,
      })>[];
      final evidenceBodies = <String>[];
      final runner = WorkDiscussionRunner(
          database: db,
          credentials: _Credentials(),
          eventStore: events,
          investigate: execution.investigate,
          workspaceService: execution.workspaceService,
          completion: (
              {required character,
              required config,
              required apiKey,
              required provider,
              required conversationId,
              required messages,
              required timeout,
              cancelToken}) async {
            calls++;
            identities.add(character.id);
            wiring.add((
              characterId: character.id,
              configId: config.id,
              systemContent: messages.first['content'] as String,
              personal: messages[1]['content'] as String,
            ));
            final context = jsonDecode(messages.last['content'] as String)
                as Map<String, dynamic>;
            final s =
                Map<String, dynamic>.from(context['collaboration'] as Map);
            if (reads > 0 && (s['issues'] as List).isEmpty) {
              return _turn('respond', text: '连点是否重复移动？我先检查真实代码。', issues: [
                {
                  'id': 'double',
                  'kind': 'defect',
                  'target': 'code',
                  'problem': '连点是否重复移动',
                  'evidenceRef': '',
                  'retestCondition': '查明移动锁'
                }
              ]);
            }
            if (readCount < reads) {
              return _turn('investigate',
                  text: '我查下移动锁的实现。',
                  issue: 'double',
                  tool: {
                    'name': 'workspace.read',
                    'arguments': {'path': 'source${readCount++}.dart'}
                  });
            }
            if ((s['issues'] as List).any((i) => i['status'] == 'open')) {
              final receipts = context['evidence'] as Map;
              evidenceBodies.add(jsonEncode(receipts.values.last));
              return _turn('propose',
                  text: '源码声明了移动锁；按这个机制制定实现和验收。',
                  resolutions: [
                    {
                      'id': 'double',
                      'resolution': '读取真实代码确认移动锁声明',
                      'evidenceRef': receipts.keys.last
                    }
                  ],
                  proposal: proposal(s));
            }
            if ((s['plan'] as String).isEmpty) {
              return _turn('propose',
                  text: '移动时禁用按钮，并验证连点行为。', proposal: proposal(s));
            }
            return _turn('approve', approval: approval(s));
          });
      await db.agentTaskBox.put(task.id, task);
      await runner.runCollaboration(task, WorkTaskCancellation(), apply);
      final state =
          WorkDiscussionState.fromExecutionState(task.executionStateJson)!;
      expect(state.isPlanReady, isTrue);
      expect(state.isExecutionReady, isFalse);
      expect(state.collaboration!.activeMembers.toSet(), {'dev', 'qa'});
      expect(identities, containsAll(['dev', 'qa']));
      expect(wiring, isNotEmpty);
      for (final call in wiring) {
        final id = call.characterId;
        expect(call.configId, 'config-$id');
        expect(call.systemContent, contains('我是$id'));
        expect(call.systemContent, contains('风格例句只示范接话'));
        expect(call.systemContent, contains('共享证据注明成员来源'));
        expect(call.personal, contains('稳定偏好_$id'));
        expect(call.personal,
            isNot(contains('稳定偏好_${id == 'dev' ? 'qa' : 'dev'}')));
        expect(call.personal, contains(id == 'dev' ? '直接' : '谨慎'));
        expect(
            call.personal, contains(id == 'dev' ? '最近情绪warm' : '最近情绪neutral'));
      }
      for (final body in evidenceBodies) {
        expect(body, contains('diceGuard${reads - 1}'));
      }
      expect(identities, isNot(contains('extra')));
      expect(readCount, reads);
      final methods = db.permanentMemoryBox.values
          .where((m) => m.workSource?['type'] == 'verifiedMethod')
          .toList();
      if (reads > 0) {
        expect(methods, hasLength(1));
        expect(methods.single.participantIds,
            [methods.single.observerCharacterId]);
        expect(methods.single.content, isNot(contains('diceGuard')));
        expect(methods.single.workSource!['evidenceRef'],
            startsWith('investigation:'));
        expect(methods.single.sourceMessageIds, isNotEmpty);
      } else {
        expect(methods, isEmpty);
      }
      if (reads > 0) {
        final receipts = (await events.read(task.id))
            .events
            .where((e) => e.safeMetadata['phase'] == 'investigation')
            .toList();
        expect(receipts.length, reads);
        final sourceFiles = db.messageBox.values
            .expand((m) => m.media ?? [])
            .where((a) => a.fileName == '调查来源与结果.json')
            .toList();
        expect(sourceFiles.length, reads);
        final details =
            jsonDecode(await File(sourceFiles.last.localPath).readAsString())
                as Map;
        expect(
            receipts.any((e) =>
                e.safeMetadata['evidenceRef'] == details['evidenceRef'] &&
                e.safeMetadata['memberId'] == details['memberId']),
            true);
        expect(jsonEncode(details['result']), contains('diceGuard'));
      }
      if (reads == 0) expect(calls, 3);
      if (reads == 97) expect(calls, greaterThan(97));
      expect(
          db.messageBox.values.every((m) =>
              !m.content.contains('职责意见：') && !m.content.contains('理解进度')),
          isTrue);
    }, timeout: const Timeout(Duration(seconds: 30)));
  }
  for (final choice in ['qa', 'human-review']) {
    test('缺人经 P3 $choice 确认后恢复真实讨论，未确认不调用角色库成员', () async {
      final current = db.chatGroupBox.get(task.groupId)!;
      await db.chatGroupBox.put(
          current.id,
          ChatGroup(
              id: current.id,
              name: current.name,
              theme: current.theme,
              aiCharacterIds: const ['dev']));
      final called = <String>[];
      final discussion = modelRunner((m, c) async {
        called.add(m.id);
        final response = await confirm(m, c);
        final body = jsonDecode(response['message'] as String) as Map;
        if (choice == 'human-review' && body['proposal'] is Map) {
          final proposal = body['proposal'] as Map;
          proposal['workItems'] = (proposal['workItems'] as List)
              .where((i) => i['ownerId'] == 'dev')
              .toList();
          response['message'] = jsonEncode(body);
        }
        return response;
      });
      final coordinator = WorkTaskCoordinator(
          taskBox: db.agentTaskBox,
          eventStore: events,
          runner: execution,
          discussionRunner: discussion);
      try {
        await coordinator.submit(task);
        await waitFor(() =>
            WorkDiscussionState.fromExecutionState(task.executionStateJson)!
                .collaboration!
                .hasPendingDecision);
        expect(called, isEmpty);
        final decision =
            WorkDiscussionState.fromExecutionState(task.executionStateJson)!
                .collaboration!
                .decisions
                .first;
        expect(
            (decision['options'] as List).any((o) => o['id'] == 'qa'), isTrue);
        await coordinator.respondToDecision(task.id,
            decisionId: decision['id'] as String,
            revision: decision['revision'] as int,
            answer: '',
            choiceId: choice);
        await waitFor(() {
          final collaboration =
              WorkDiscussionState.fromExecutionState(task.executionStateJson)
                  ?.collaboration;
          // 讨论已经恢复，并在当前需求版本上收敛到就绪。software 合同的软件交付
          // 要求（材料/实现工作项 + 验证命令）如果没在方案里补齐，production 门禁
          // 随后会把任务退回群讨论并请用户补齐——那是设计好的下一步，不是"讨论
          // 还没跑完"，所以这里只认"已经就绪过"这一个单调事实。
          //
          // 就绪与"已经退回暂停"不是同一时刻：协调器在讨论返回后还会把任务置为
          // queued 并调度一次，由 production 门禁读取工作区和项目文件后才写回暂停。
          // 只等 phase 会在那个 queued 窗口里提前返回（CI 负载下必现），所以状态必须
          // 与阶段一起等。
          return collaboration != null &&
              collaboration.phase == 'ready' &&
              task.status == AgentTaskStatus.paused;
        });
        expect(called.contains('qa'), choice == 'qa');
        if (choice == 'human-review') {
          final state =
              WorkDiscussionState.fromExecutionState(task.executionStateJson)!
                  .collaboration!;
          expect(state.activeMembers, ['dev']);
          expect(
              state.acceptances.every((a) => a['status'] == 'pending'), isTrue);
        }
        expect(db.chatGroupBox.get(current.id)!.aiCharacterIds, const ['dev']);
        expect(task.status, AgentTaskStatus.paused);
      } finally {
        await coordinator.dispose();
      }
    }, timeout: const Timeout(Duration(seconds: 30)));
  }
  test('成员删除保留原责任并阻塞，不能隐式剔除', () async {
    final discussion = modelRunner(confirm);
    await discussion.runCollaboration(task, WorkTaskCancellation(), apply);
    await db.aiCharacterBox.delete('qa');
    await discussion.runCollaboration(task, WorkTaskCancellation(), apply);
    final s = WorkDiscussionState.fromExecutionState(task.executionStateJson)!
        .collaboration!;
    expect(
        s.team.singleWhere((m) => m['memberId'] == 'qa')['available'], isFalse);
    expect(s.planReady, isFalse);
    expect(s.hasPendingDecision, isTrue);
  });
  test('文档中的 HTML 游戏测试不扩大交付；明确要求开发才增加能力', () {
    final members = db.aiCharacterBox.values.toList();
    final document = WorkRoleRouter.selectTeam(
        request: '仅编写 HTML 游戏测试需求文档', characters: members);
    expect(
        document.team.where(
            (m) => {'development', 'frontend', 'testing'}.contains(m['role'])),
        isEmpty);
    expect(
        WorkRoleRouter.requestsSoftwareImplementation('编写需求文档，并开发软件'), isTrue);
    expect(
        WorkRoleRouter.requestsSoftwareImplementation('编写开发游戏的需求文档'), isFalse);
    // 「生成/创建」是与「制作」等价的实现动词，漏掉它们会让整类请求丢掉测试阶段。
    expect(WorkRoleRouter.requestsSoftwareImplementation('生成一份 飞行棋游戏的HTML'),
        isTrue);
    expect(
        WorkRoleRouter.requestsSoftwareImplementation(
            '创建一个目录，目录中的内容生成一份 飞行棋游戏的HTML'),
        isTrue);
  });
  test('ready 前即便已有授权或命令伪装只读也不会进入 handler', () async {
    var invoked = 0;
    final registry = WorkToolRegistry(definitions: [
      for (final name in [
        AgentToolName.commandRun,
        AgentToolName.workspacePatch
      ])
        WorkToolDefinition(
            name: name,
            access: WorkToolAccess.readOnly,
            schema: const WorkToolSchema(allowAdditional: true),
            handler: (_) {
              invoked++;
              return const WorkToolResult.success(message: 'unexpected');
            })
    ]);
    for (final name in [
      AgentToolName.commandRun,
      AgentToolName.workspacePatch
    ]) {
      final result = await registry.execute(
          AgentToolCall(name: name, arguments: const {}),
          context: WorkToolExecutionContext(task: task));
      expect(result.succeeded, isFalse);
      expect(result.failureCode, 'discussionPhaseDenied');
    }
    expect(invoked, 0);
    expect(await File('${dir.path}/project/probe').exists(), isFalse);
  });
  for (final agree in [true, false]) {
    test('新范围全员认可或分歧路径：$agree，旧方案认可失效', () async {
      var stage = 0;
      final discussion = modelRunner((m, c) async {
        final s = Map<String, dynamic>.from(c['collaboration'] as Map);
        if (stage == 0) {
          stage++;
          return _turn('propose', proposal: proposal(s));
        }
        if (stage == 1 && (s['approvals'] as List).isEmpty) {
          return _turn('approve', approval: approval(s));
        }
        if (stage == 1) {
          stage++;
          return _turn('respond', issues: [
            {
              'id': 'idea',
              'kind': 'idea',
              'target': 'development',
              'problem': '增加键盘操作',
              'evidenceRef': '',
              'retestCondition': '团队确认新增交互'
            }
          ]);
        }
        final issue =
            (s['issues'] as List).firstWhere((i) => i['id'] == 'idea') as Map;
        if (issue['resolutionRef'] == '') {
          final p = proposal(s)
            ..['scope'] = '${s['scope']}；增加键盘操作'
            ..['plan'] = '保留移动锁，同时规划键盘操作及测试';
          return _turn('propose', issue: 'idea', proposal: p);
        }
        if (issue['status'] == 'open') {
          return _turn('approve', approval: {
            ...approval(s),
            'kind': 'idea',
            'subjectId': 'idea',
            'approved': agree || m.id == 'dev'
          });
        }
        return _turn('approve', approval: approval(s));
      });
      await discussion.runCollaboration(task, WorkTaskCancellation(), apply);
      final s = WorkDiscussionState.fromExecutionState(task.executionStateJson)!
          .collaboration!;
      if (agree) {
        expect(s.planReady, isTrue);
        expect(s.scope, contains('键盘'));
        expect(
            s.approvals
                .where((a) =>
                    a['kind'] == 'plan' &&
                    a['requestRevision'] == s.requestRevision)
                .length,
            2);
      } else {
        expect(s.planReady, isFalse);
        expect(s.scope, isNot(contains('键盘')));
        expect(s.decisions.last['kind'], 'dispute');
      }
      final attachments =
          db.messageBox.values.expand((m) => m.media ?? []).toList();
      expect(attachments, isNotEmpty);
      for (final file in attachments) {
        expect(await File(file.localPath).exists(), isTrue);
        final detail = Map<String, dynamic>.from(
            jsonDecode(await File(file.localPath).readAsString()) as Map);
        final savedProposal =
            Map<String, dynamic>.from(detail['proposal'] as Map);
        expect(savedProposal, contains('acceptances'));
        expect(detail['requestRevision'], isA<int>());
        expect(detail['teamRevision'], isA<int>());
        expect(detail['verificationRevision'], isA<int>());
      }
      final proposalDetails = <Map<String, dynamic>>[];
      for (final file
          in attachments.where((file) => file.fileName == '方案与验收详情.json')) {
        proposalDetails.add(Map<String, dynamic>.from(
            jsonDecode(await File(file.localPath).readAsString()) as Map));
      }
      final pendingDetail = proposalDetails.firstWhere((detail) =>
          (detail['proposal']['scope'] as String).contains('增加键盘操作'));
      final issue = (pendingDetail['issues'] as List)
          .cast<Map>()
          .singleWhere((issue) => issue['id'] == 'idea');
      expect(issue['status'], 'open');
      expect(issue['resolution'], contains('等待'));
      expect(issue['resolution'], contains('尚未改变正式方案'));
    }, timeout: const Timeout(Duration(seconds: 30)));
  }
  for (final adopt in [false, true]) {
    test('分歧由 P3 用户明确裁决后重新确认方案：adopt=$adopt', () async {
      final disagree = modelRunner((m, c) async {
        final s = Map<String, dynamic>.from(c['collaboration'] as Map);
        final issues = s['issues'] as List;
        if (issues.isEmpty) {
          return _turn('respond', issues: [
            {
              'id': 'idea',
              'kind': 'idea',
              'target': 'development',
              'problem': '增加键盘操作',
              'evidenceRef': '',
              'retestCondition': '确认完整新范围'
            }
          ]);
        }
        if (issues.first['resolutionRef'] == '') {
          final p = proposal(s)..['scope'] = '${s['scope']}；增加键盘操作';
          return _turn('propose', issue: 'idea', proposal: p);
        }
        return _turn('approve', approval: {
          ...approval(s),
          'kind': 'idea',
          'subjectId': 'idea',
          'approved': m.id == 'dev'
        });
      });
      await disagree.runCollaboration(task, WorkTaskCancellation(), apply);
      final old =
          WorkDiscussionState.fromExecutionState(task.executionStateJson)!
              .collaboration!;
      final d = old.decisions.last;
      final choice = (d['options'] as List).firstWhere((o) => adopt
          ? (o['id'] as String).startsWith('adopt:')
          : o['id'] == 'reject-idea') as Map;
      final coordinator = WorkTaskCoordinator(
          taskBox: db.agentTaskBox,
          eventStore: events,
          runner: execution,
          discussionRunner: modelRunner(confirm));
      try {
        await coordinator.submit(task);
        await coordinator.respondToDecision(task.id,
            decisionId: d['id'] as String,
            revision: d['revision'] as int,
            answer: '',
            choiceId: choice['id'] as String);
        await waitFor(() =>
            WorkDiscussionState.fromExecutionState(task.executionStateJson)!
                .isPlanReady);
        final current =
            WorkDiscussionState.fromExecutionState(task.executionStateJson)!
                .collaboration!;
        expect(current.scope.contains('键盘'), adopt);
        expect(
            current.issues.single['status'], adopt ? 'resolved' : 'rejected');
        expect(
            current.approvals.any((a) =>
                a['kind'] == 'idea' &&
                a['memberId'] == 'qa' &&
                a['approved'] == false),
            isTrue);
        expect(current.requestRevision, greaterThan(old.requestRevision));
      } finally {
        await coordinator.dispose();
      }
    }, timeout: const Timeout(Duration(seconds: 30)));
  }
  test('重复名称、指定成员不合格、两个缺失 API 配置一次收集', () async {
    final current = db.aiCharacterBox.values.toList();
    final wrong = WorkRoleRouter.selectTeam(
        request: '由 @extra 开发软件', characters: current);
    expect(wrong.errors, isNotEmpty);
    final duplicate = AICharacter(
        id: 'another-dev',
        name: 'dev',
        avatar: 'D',
        age: 30,
        role: '软件开发工程师',
        personalityTags: const [],
        systemPrompt: '开发',
        apiKey: '',
        apiProvider: 'deepseek',
        modelName: 'deepseek-chat',
        apiConfigId: 'config-dev');
    expect(
        WorkRoleRouter.selectTeam(
            request: '@dev 开发软件',
            characters: [...current, duplicate]).errors.join(),
        contains('重名'));
    await db.apiConfigBox.delete('config-dev');
    await db.apiConfigBox.delete('config-qa');
    var invoked = 0;
    final runner = modelRunner((m, c) async {
      invoked++;
      return confirm(m, c);
    });
    await runner.runCollaboration(task, WorkTaskCancellation(), apply);
    final s = WorkDiscussionState.fromExecutionState(task.executionStateJson)!
        .collaboration!;
    expect(invoked, 0);
    expect(s.decisions.where((d) => d['kind'] == 'member').length, 2);
    expect(s.team.length, 2);
    expect(s.planReady, isFalse);
  });
  for (final smallWindow in [false, true]) {
    test('必要讨论超过旧字符上限只按真实模型窗口阻塞：$smallWindow', () async {
      task.userRequest += '；${'完整且必须保留的任务约束。' * 2200}';
      final governance = MemoryGovernanceStore();
      if (smallWindow) {
        for (final id in ['dev', 'qa']) {
          final config = db.apiConfigBox.get('config-$id')!
            ..modelName = 'small-$id';
          await db.apiConfigBox.put(config.id, config);
          await governance.saveCustomCapability(
              'deepseek',
              config.modelName,
              const CustomModelCapability(
                  contextWindow: 8192, maxOutput: 2048));
        }
      }
      var calls = 0;
      final userRequests = <({Object? actual, Object? expected})>[];
      final client = _ModelClient((context, model) async {
        calls++;
        // 断言必须留在回调之外：讨论 runner 的 `_request` 用 `on Object catch`
        // 把回调异常收成"成员请求失败"，断言不会报出它自己的原因。
        userRequests
            .add((actual: context['userRequest'], expected: task.userRequest));
        return confirm(db.aiCharacterBox.get(context['memberId'])!, context);
      });
      final gateway = AiRequestGateway(store: governance, client: client);
      await WorkDiscussionRunner(
              database: db,
              credentials: _Credentials(),
              eventStore: events,
              gateway: gateway,
              investigate: execution.investigate)
          .runCollaboration(task, WorkTaskCancellation(), apply);
      final result =
          WorkDiscussionState.fromExecutionState(task.executionStateJson)!;
      expect(result.isPlanReady, !smallWindow);
      expect(result.collaboration!.hasPendingDecision, smallWindow);
      expect(calls, smallWindow ? 0 : greaterThanOrEqualTo(3));
      expect(client.contractViolations, isEmpty,
          reason: '经治理网关发出的请求必须带上测试凭据并通过输入窗口预检');
      for (final request in userRequests) {
        expect(request.actual, request.expected);
      }
    });
  }
  for (final budget in [2048, 16384, 65536]) {
    test('讨论按模型能力预留输入窗口但不发送输出上限：$budget', () async {
      final governance = MemoryGovernanceStore();
      for (final id in ['dev', 'qa']) {
        final config = db.apiConfigBox.get('config-$id')!
          ..modelName = 'declared-$id';
        await db.apiConfigBox.put(config.id, config);
        await governance.saveCustomCapability('deepseek', config.modelName,
            CustomModelCapability(contextWindow: 262144, maxOutput: budget));
      }
      var calls = 0;
      final client = _ModelClient((context, model) async {
        calls++;
        return confirm(db.aiCharacterBox.get(context['memberId'])!, context);
      }, expectedMaxTokens: 0);
      final gateway = AiRequestGateway(store: governance, client: client);
      await WorkDiscussionRunner(
              database: db,
              credentials: _Credentials(),
              eventStore: events,
              gateway: gateway,
              investigate: execution.investigate)
          .runCollaboration(task, WorkTaskCancellation(), apply);
      expect(calls, greaterThanOrEqualTo(3));
      expect(client.contractViolations, isEmpty,
          reason: '讨论请求保留输入预算校验，但不向可选协议发送 maxTokens');
      expect(
          WorkDiscussionState.fromExecutionState(task.executionStateJson)!
              .isPlanReady,
          isTrue);
    });
  }
  test('生产 gateway 实际接收不同角色自己的模型配置', () async {
    final seen = <String, String>{};
    final governance = MemoryGovernanceStore();
    final client = _ModelClient((c, model) async {
      seen[c['memberId'] as String] = model;
      return confirm(db.aiCharacterBox.get(c['memberId'])!, c);
    });
    final gateway = AiRequestGateway(store: governance, client: client);
    final runner = WorkDiscussionRunner(
        database: db,
        credentials: _Credentials(),
        eventStore: events,
        gateway: gateway,
        investigate: execution.investigate);
    await runner.runCollaboration(task, WorkTaskCancellation(), apply);
    expect(seen, {'dev': 'deepseek-chat', 'qa': 'deepseek-reasoner'});
    expect(client.contractViolations, isEmpty);
    expect(
        WorkDiscussionState.fromExecutionState(task.executionStateJson)!
            .isPlanReady,
        isTrue);
    expect(governance.ledgerEntries, isNotEmpty);
  });
  test('通过真实生产 gateway 形状接收各成员模型，长解释与全部问题完整保存', () async {
    final models = <String, String>{};
    var stage = 0;
    final longText = '需要说明这个边界：${'必要证据解释。' * 400}';
    final issueCounts = <int>[];
    final client = _ModelClient((c, model) async {
      models[c['memberId'] as String] = model;
      final s = Map<String, dynamic>.from(c['collaboration'] as Map);
      if (stage++ == 0) {
        return _turn('respond', text: longText, issues: [
          for (var i = 0; i < 3; i++)
            {
              'id': 'question$i',
              'kind': 'decision',
              'target': 'general',
              'problem': '需要确认规则 $i',
              'evidenceRef': '',
              'retestCondition': '用户明确选择规则 $i'
            }
        ]);
      }
      final turn = _turn('silent', text: '');
      final body =
          jsonDecode(turn['message'] as String) as Map<String, dynamic>;
      body['action'] = 'decide';
      body['public_update'] = '这三项玩法规则需要你确认，问题详情已完整保存。';
      body['decision'] = {
        'kind': 'question',
        'targetId': 'question0',
        'reason': '三个玩法规则尚未确定',
        'evidence': '成员收集了全部三个问题',
        'impact': '等待确认后再收敛方案',
        'options': <Map<String, dynamic>>[]
      };
      // 断言必须留在回调之外：讨论 runner 的 `_request` 用 `on Object catch`
      // 把回调异常收成"成员请求失败"，断言不会报出它自己的原因。
      issueCounts.add((s['issues'] as List).length);
      return {'success': true, 'message': jsonEncode(body)};
    });
    final gateway =
        AiRequestGateway(store: MemoryGovernanceStore(), client: client);
    final discussion = WorkDiscussionRunner(
        database: db,
        credentials: _Credentials(),
        eventStore: events,
        gateway: gateway,
        investigate: execution.investigate);
    await discussion.runCollaboration(task, WorkTaskCancellation(), apply);
    final s = WorkDiscussionState.fromExecutionState(task.executionStateJson)!
        .collaboration!;
    expect(s.issues.length, 3);
    expect(s.hasPendingDecision, isTrue);
    expect(s.planReady, isFalse);
    // 长解释不再原样进气泡——气泡有发言纪律的长度上限——但一个字都不能丢：
    // 完整正文随这条消息转存为详情附件。
    final bubble = db.messageBox.values
        .map((m) => m.content)
        .firstWhere((c) => c.startsWith('需要说明这个边界：'));
    expect(bubble, contains('已截断，原文 ${longText.length} 字'));
    final detail = db.messageBox.values
        .expand((m) => m.media ?? [])
        .singleWhere((a) => a.fileName == '完整公开正文.json');
    expect(await File(detail.localPath).readAsString(), contains(longText));
    expect(models['dev'], 'deepseek-chat');
    expect(client.contractViolations, isEmpty);
    expect(issueCounts, isNotEmpty);
    expect(issueCounts.every((count) => count == 3), isTrue,
        reason: '每个成员都要看到全部三个未决问题');
  });
  test('原生应用合同失败时诊断包含 nativeBundle 的完整约束', () {
    final invalidProposal = {
      'scope': '交付一个 macOS 应用',
      'plan': '构建并验证应用',
      'artifactContract': {
        'type': 'software',
        'format': 'macOS app',
        'location': '临时目录',
        'revisionTarget': '',
        'files': ['ExpenseLedger.app', 'ExpenseLedger.zip'],
        'nativeBundle': {
          'schemaVersion': 1,
          'appPath': 'ExpenseLedger.app',
          'archivePath': 'ExpenseLedger.zip',
        },
      },
      'workItems': <Map<String, dynamic>>[],
      'acceptances': <Map<String, dynamic>>[],
    };
    String? diagnostic;

    expect(
      WorkDiscussionV2Turn.parse(
        _turn('propose', proposal: invalidProposal),
        onInvalid: (reason) => diagnostic = reason,
      ),
      isNull,
    );
    expect(diagnostic, contains('nativeBundle'));
    expect(diagnostic, contains('files 只能包含 archivePath'));
  });

  test('issues 协议诊断指出多余字段和超长字段', () {
    String reasonFor(Map<String, dynamic> issue) {
      String? reason;
      expect(
        WorkDiscussionV2Turn.parse(
          _turn('respond', issues: [issue]),
          onInvalid: (value) => reason = value,
        ),
        isNull,
      );
      return reason!;
    }

    final validIssue = <String, dynamic>{
      'id': 'i1',
      'kind': 'defect',
      'target': 'proposal',
      'problem': '缺少可核验证据',
      'evidenceRef': '',
      'retestCondition': '补齐证据后复测',
    };
    expect(
      reasonFor({...validIssue, 'status': 'open'}),
      contains('issues[0] 必须且只能包含'),
    );
    expect(
        reasonFor({...validIssue, 'status': 'open'}), contains('多余字段：status'));
    final missingField = {...validIssue}..remove('retestCondition');
    expect(reasonFor(missingField), contains('缺少字段：retestCondition'));
    expect(reasonFor({...validIssue, '未信任字段正文': '不应回显'}),
        contains('多余字段：unknown'));
    expect(
      reasonFor({...validIssue, 'problem': 'p' * 4097}),
      contains('issues[0].problem'),
    );
  });

  test('验收方法超过长度限制时诊断要求拆分验收项', () {
    final invalidProposal = {
      'scope': '交付一份文档',
      'plan': '生成并验证文档',
      'artifactContract': {
        'type': 'document',
        'format': 'md',
        'location': '临时目录',
        'revisionTarget': '',
        'files': ['report.md'],
      },
      'workItems': <Map<String, dynamic>>[],
      'acceptances': [
        {
          'id': 'long-method',
          'method': '验收' * 65,
          'requiredCapability': 'document',
        },
      ],
    };
    String? diagnostic;

    expect(
      WorkDiscussionV2Turn.parse(
        _turn('propose', proposal: invalidProposal),
        onInvalid: (reason) => diagnostic = reason,
      ),
      isNull,
    );
    expect(diagnostic, contains('method 必须非空且最多 128 字符'));
  });

  test('旧回复、他人签字、100% 和错误提案均不形成协议', () {
    expect(
        WorkDiscussionV2Turn.parse(
            {'success': true, 'content': '{"understanding_percent":100}'}),
        isNull);
    final forged = _turn('approve', approval: {
      'kind': 'plan',
      'subjectId': task.id,
      'approved': true,
      'requestRevision': 1,
      'teamRevision': 1,
      'verificationRevision': 1,
      'memberId': 'qa'
    });
    expect(WorkDiscussionV2Turn.parse(forged), isNull);
  });
}

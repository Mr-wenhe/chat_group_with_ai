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
import 'package:chat_group/features/work_mode/work_discussion_v2_protocol.dart';
import 'package:chat_group/features/work_mode/work_public_update_stream.dart';
import 'package:chat_group/features/work_mode/agent_decision.dart';
import 'package:chat_group/features/agentic/tool_request.dart';
import 'package:chat_group/features/work_mode/work_tool_registry.dart';
import 'package:chat_group/features/work_mode/work_role_router.dart';
import 'package:chat_group/features/work_mode/work_folder_grant_service.dart';
import 'package:chat_group/features/work_mode/work_mode_workspace_service.dart';
import 'package:chat_group/features/work_mode/work_task_coordinator.dart';
import 'package:chat_group/features/work_mode/work_task_event_store.dart';
import 'package:crypto/crypto.dart';
import 'package:chat_group/features/work_mode/workspace_path_policy.dart';
import 'package:chat_group/features/work_mode/workspace_file_service.dart';
import 'package:chat_group/features/work_mode/workspace_mutation_service.dart';
import 'package:flutter_test/flutter_test.dart';
import '../helpers/lifecycle_hive.dart';

part 'work_discussion_v2_test_support.dart';

part 'work_discussion_v2_regressions.dart';

void main() {
  _registerDiscussionHistoryRegressions();

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
            expect(config.id, 'config-${character.id}');
            expect(messages.first['content'], contains('我是${character.id}'));
            final personal = messages[1]['content'] as String;
            expect(personal, contains('稳定偏好_${character.id}'));
            expect(
                personal,
                isNot(
                    contains('稳定偏好_${character.id == 'dev' ? 'qa' : 'dev'}')));
            expect(personal, contains(character.id == 'dev' ? '直接' : '谨慎'));
            expect(personal,
                contains(character.id == 'dev' ? '最近情绪warm' : '最近情绪neutral'));
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
              expect(jsonEncode(receipts.values.last),
                  contains('diceGuard${reads - 1}'));
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
        expect(jsonDecode(await File(file.localPath).readAsString()),
            contains('acceptances'));
      }
    });
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
      final gateway = AiRequestGateway(
          store: governance,
          client: _ModelClient((context, model) async {
            calls++;
            expect(context['userRequest'], task.userRequest);
            return confirm(
                db.aiCharacterBox.get(context['memberId'])!, context);
          }));
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
    });
  }
  for (final budget in [2048, 16384, 65536]) {
    test('讨论请求遵守模型能力输出预算及绝对上限：$budget', () async {
      final governance = MemoryGovernanceStore();
      for (final id in ['dev', 'qa']) {
        final config = db.apiConfigBox.get('config-$id')!
          ..modelName = 'declared-$id';
        await db.apiConfigBox.put(config.id, config);
        await governance.saveCustomCapability('deepseek', config.modelName,
            CustomModelCapability(contextWindow: 262144, maxOutput: budget));
      }
      var calls = 0;
      final gateway = AiRequestGateway(
          store: governance,
          client: _ModelClient((context, model) async {
            calls++;
            return confirm(
                db.aiCharacterBox.get(context['memberId'])!, context);
          }, expectedMaxTokens: budget > 32768 ? 32768 : budget));
      await WorkDiscussionRunner(
              database: db,
              credentials: _Credentials(),
              eventStore: events,
              gateway: gateway,
              investigate: execution.investigate)
          .runCollaboration(task, WorkTaskCancellation(), apply);
      expect(calls, greaterThanOrEqualTo(3));
      expect(
          WorkDiscussionState.fromExecutionState(task.executionStateJson)!
              .isPlanReady,
          isTrue);
    });
  }
  test('生产 gateway 实际接收不同角色自己的模型配置', () async {
    final seen = <String, String>{};
    final governance = MemoryGovernanceStore();
    final gateway = AiRequestGateway(
        store: governance,
        client: _ModelClient((c, model) async {
          seen[c['memberId'] as String] = model;
          return confirm(db.aiCharacterBox.get(c['memberId'])!, c);
        }));
    final runner = WorkDiscussionRunner(
        database: db,
        credentials: _Credentials(),
        eventStore: events,
        gateway: gateway,
        investigate: execution.investigate);
    await runner.runCollaboration(task, WorkTaskCancellation(), apply);
    expect(seen, {'dev': 'deepseek-chat', 'qa': 'deepseek-reasoner'});
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
    final gateway = AiRequestGateway(
        store: MemoryGovernanceStore(),
        client: _ModelClient((c, model) async {
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
          expect((s['issues'] as List).length, 3);
          return {'success': true, 'message': jsonEncode(body)};
        }));
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

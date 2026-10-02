part of 'default_work_task_runner_stage02_test.dart';

/// Ticks the drive-loop below waits before giving up. Each tick sleeps 10ms and
/// hands the event loop back to the coordinator, whose own retry, review and
/// delivery stages advance on wall-clock timers — so the tick count a scenario
/// needs grows with machine load even though its logic never changes. Idle, the
/// scenarios need 28-96 ticks (`retest-failure` is the slowest at 96); on a
/// contended CI runner each needs roughly three times its idle count, which put
/// `retest-failure` at the old 300-tick edge and made it fail intermittently
/// with `runningTool` still in flight. 600 keeps a ~2x margin over that while
/// staying well inside the 30s per-test budget.
const _p7DriveAttempts = 600;

void _registerP7RunnerTests(Directory Function() hive,
    Directory Function() root, WorkTaskEventStore Function() events) {
  for (final scenario in _p7Scenarios) {
    final document = scenario == 'document';
    final negative = !{
      'software',
      'startup',
      'portable-import',
      'document',
      'retest-failure',
      'manual',
      'manual-no-tester',
      'waiver',
      'delivery-failure',
      'lock'
    }.contains(scenario);
    test(
        'P7 actual coordinator/default loop $scenario failure repair retest signatures delivery',
        () async {
      final db = CandidateTestDatabase(hive());
      final grants = WorkFolderGrantService(
          box: db.appSettingsBox,
          directoryValidator: (_) async => true,
          writeDirectoryValidator: (_) async => true,
          isWindows: false);
      await grants.authorizeDirectory(root().path, consent: (_) async => true);
      await grants.setOrdinaryWriteConfirmation(false);
      final policy = WorkspacePathPolicy(grantService: grants);
      for (final id in ['a', 'b']) {
        final config = ApiConfig(
            id: 'p7-$id',
            name: id,
            provider: 'deepseek',
            modelName: 'deepseek-chat',
            hasCredential: true);
        await db.apiConfigBox.put(config.id, config);
        await db.aiCharacterBox.put(
            id,
            AICharacter(
                id: id,
                name: id,
                avatar: id,
                age: 30,
                role: document
                    ? '文档编辑'
                    : id == 'a'
                        ? '软件开发工程师'
                        : '测试工程师',
                personalityTags: [],
                systemPrompt: '成员 $id',
                apiKey: '',
                apiProvider: 'deepseek',
                modelName: 'deepseek-chat',
                apiConfigId: config.id,
                toolPermissions: [
                  ToolPermission.workspaceRead,
                  ToolPermission.workspacePatch,
                  ToolPermission.commandRun
                ]));
      }
      await db.chatGroupBox.put(
          'group-a',
          ChatGroup(
              id: 'group-a',
              name: 'P7',
              theme: '任务',
              aiCharacterIds: ['a', 'b']));
      await db.workModeWorkspaceBox.put(
          'group-a',
          WorkModeWorkspace(
              conversationId: 'group-a',
              conversationType: 'group',
              workDirPath: root().path,
              projectScopeId: 'scope-a'));
      final raw = candidateTestState(
              type: document ? 'document' : 'software',
              format: document ? 'txt' : 'html')
          .toJson()
        ..['plan'] = ''
        ..['phase'] = 'clarifying'
        ..['approvals'] = [];
      if (scenario == 'manual-no-tester') {
        raw['team'] =
            (raw['team'] as List).where((m) => m['memberId'] == 'a').toList();
      }
      if (document) {
        raw['team'] = [
          for (final m in raw['team'] as List) {...m as Map, 'role': 'document'}
        ];
      }
      if (scenario == 'deferred') {
        raw['decisions'] = [
          {
            'id': 'later-question',
            'revision': 1,
            'status': 'pending',
            'kind': 'question',
            'targetId': 'later',
            'reason': '稍后工作缺条件',
            'evidence': '尚未执行',
            'answer': '',
            'impact': '只阻塞 later',
            'responseRef': ''
          }
        ];
      }
      if (scenario == 'portable-import') {
        raw
          ..['projectScopeId'] = 'portable-unbound'
          ..['plan'] = '旧设备已有方案，必须在本机重新核对'
          ..['phase'] = 'reviewing'
          ..['team'] = [
            for (final m in raw['team'] as List)
              {...m as Map, 'available': false}
          ]
          ..['approvals'] = candidateTestState().approvals
          ..['workItems'] = [
            {
              'id': 'old-production',
              'ownerId': 'a',
              'dependencies': [],
              'kind': 'produce',
              'status': 'done',
              'requestRevision': 1
            }
          ]
          ..['iterations'] = [
            {
              'id': 'r007',
              'artifactDigest': '0123456789abcdef' * 4,
              'requestRevision': 1,
              'teamRevision': 1,
              'manifestRef': '',
              'reviewRef': '',
              'status': 'delivered'
            }
          ];
      }
      final work = candidateTestTask(WorkCollaborationState.tryParse(raw)!);
      work.userRequest =
          document ? '仅制作并审查软件需求文档 report.txt；不开发软件。' : '制作并测试 report.html 游戏';
      final gateway =
          _P7Gateway(() => work, document: document, scenario: scenario);
      final command = _P7Command(() => work, root().path, scenario: scenario);
      final locks = WorkResourceLockManager();
      var deliveryFailures = 0;
      late WorkTaskCoordinator coordinator;
      var injected = false;
      final runner = DefaultWorkTaskRunner(
          database: db,
          eventStore: events(),
          gateway: gateway,
          credentials: _TestCredentials(),
          folderGrantService: grants,
          workspaceService:
              WorkModeWorkspaceService(db: db, grantService: grants),
          workspaceFileService: WorkspaceFileService(pathPolicy: policy),
          mutationService: WorkspaceMutationService(
              pathPolicy: policy,
              snapshotPort: WorkSnapshotService(
                  appSupportDirectory: Directory('${hive().path}/p7-support'),
                  pathPolicy: policy)),
          resourceLockManager: locks,
          commandRunner: command,
          mediaCopier:
              !{'delivery-failure', 'late-copy-input'}.contains(scenario)
                  ? null
                  : (source, type, {fileName}) async {
                      if (scenario == 'late-copy-input' &&
                          !injected &&
                          db.messageBox.values
                              .any((m) => m.workDelivery?['kind'] == 'final')) {
                        injected = true;
                        unawaited(coordinator.enqueueFollowUp(
                            work.id, '附件投递期间补充键盘交互验收',
                            sourceMessageId: 'p7-copy-input'));
                      }
                      if (scenario == 'delivery-failure' &&
                          db.messageBox.values
                              .any((m) => m.workDelivery?['kind'] == 'final') &&
                          deliveryFailures++ == 0) {
                        throw StateError('受控附件投递失败');
                      }
                      return db.copyToMedia(source, type, fileName: fileName);
                    });
      final signatures = <String>[];
      final discussion = WorkDiscussionRunner(
          database: db,
          eventStore: events(),
          credentials: _TestCredentials(),
          investigate: runner.investigate,
          workspaceService: runner.workspaceService,
          completion: (
              {required character,
              required config,
              required apiKey,
              required provider,
              required conversationId,
              required messages,
              required timeout,
              cancelToken}) async {
            final state =
                WorkDiscussionState.fromExecutionState(work.executionStateJson)!
                    .collaboration!;
            final open =
                state.issues.where((i) => i['status'] == 'open').firstOrNull;
            String action = 'approve';
            Map<String, dynamic>? proposal;
            Map<String, dynamic>? approval;
            Map<String, dynamic>? tool;
            List<Map<String, dynamic>> resolutions = [];
            if (open != null) {
              if (!(open['evidenceRef'] as String)
                  .startsWith('investigation:')) {
                action = 'investigate';
                tool = {
                  'name': 'workspace.read',
                  'arguments': {'path': document ? 'report.txt' : 'report.html'}
                };
              } else {
                action = 'respond';
                resolutions = [
                  {
                    'id': open['id'],
                    'resolution':
                        document ? '补全来源、更新日期并复审正文与格式。' : '修复事件锁，保留原验收与回归。',
                    'evidenceRef': open['evidenceRef']
                  }
                ];
              }
            } else if (state.plan.isEmpty ||
                state.acceptances.any((a) => a['status'] == 'failed') ||
                state.workItems.any(
                    (i) => i['requestRevision'] != state.requestRevision)) {
              action = 'propose';
              proposal = {
                'scope': state.scope,
                'plan': '需求与边界已明确；写工作说明，实现事件锁；独立测试连点与回归。',
                'artifactContract': {
                  ...state.artifactContract,
                  'files': ['work.md', document ? 'report.txt' : 'report.html'],
                  if (!document)
                    'verificationCommands': [
                      jsonEncode({'executable': 'pwd', 'arguments': []})
                    ]
                },
                'workItems': [
                  if (scenario == 'deferred')
                    {
                      'id': 'later',
                      'ownerId': 'a',
                      'dependencies': [],
                      'kind': 'produce'
                    },
                  {
                    'id': 'materials',
                    'ownerId': 'a',
                    'dependencies': [],
                    'kind': 'material'
                  },
                  {
                    'id': 'implementation',
                    'ownerId': 'a',
                    'dependencies': ['materials'],
                    'kind': 'produce'
                  }
                ],
                'acceptances': [
                  {
                    'id': 'qa',
                    'method': scenario == 'assertion-change' &&
                            state.iterations.isNotEmpty
                        ? '删掉连点，只检查标签'
                        : document
                            ? '正文与来源格式审查'
                            : '连点、边界、回归',
                    'requiredCapability': document ? 'read' : 'command'
                  }
                ]
              };
            } else {
              final delivery = state.phase == 'reviewing';
              if (delivery &&
                  character.id == 'b' &&
                  !injected &&
                  negative &&
                  scenario != 'late-copy-input') {
                injected = true;
                final candidate =
                    (await (await runner.candidatePublisher(work)).recover())
                        .last;
                switch (scenario) {
                  case 'member-lost':
                    db.aiCharacterBox.get('b')!.isActive = false;
                    await db.aiCharacterBox
                        .put('b', db.aiCharacterBox.get('b')!);
                  case 'content-change':
                    await candidate
                        .file('report.html')
                        .writeAsString('changed after testing');
                  case 'old-evidence':
                    final attempt =
                        (state.currentIteration!['reviewRef'] as String)
                            .split(':')[2];
                    await File(
                            '${candidate.directory.path}/reviews/$attempt/report.json')
                        .writeAsString('{}');
                  case 'late-input':
                    await coordinator.enqueueFollowUp(
                        work.id, '临交付要求：增加新的键盘交互验收。',
                        sourceMessageId: 'p7-late');
                  default:
                    break;
                }
              }
              if (delivery && character.id == 'b' && scenario == 'silent') {
                return {'success': true, 'message': '{}'};
              }

              if (delivery) {
                signatures
                    .add('${state.currentIteration!['id']}:${character.id}');
              }
              approval = {
                'kind': delivery ? 'delivery' : 'plan',
                'subjectId': delivery ? state.currentIteration!['id'] : work.id,
                'approved':
                    !(delivery && character.id == 'b' && scenario == 'refusal'),
                if (delivery &&
                    character.id == 'b' &&
                    scenario == 'fake-signature')
                  'memberId': 'a',
                'requestRevision': state.requestRevision,
                'teamRevision': state.teamRevision,
                'verificationRevision': state.verificationRevision,
                if (delivery) 'iterationId': state.currentIteration!['id'],
                if (delivery)
                  'artifactDigest': state.currentIteration!['artifactDigest']
              };
            }
            return {
              'success': true,
              'message': jsonEncode({
                'schemaVersion': 2,
                'action': action,
                'public_update':
                    action == 'approve' ? '我认可当前版本和验证依据。' : '保留复现与验收条件，按此修订。',
                'issue_id': open?['id'] ?? '',
                'next_member_id': '',
                'issues': [],
                'resolutions': resolutions,
                'proposal': proposal,
                'approval': approval,
                'decision': null,
                'tool': tool
              })
            };
          });
      coordinator = WorkTaskCoordinator(
          taskBox: db.agentTaskBox,
          runner: runner,
          discussionRunner: discussion,
          eventStore: events(),
          resourceLockManager: locks);
      addTearDown(coordinator.dispose);
      final competing = scenario == 'lock'
          ? await locks.acquire(
              'competing', [WorkResourceLockRequest.treeWrite(root().path)])
          : null;
      if (scenario == 'portable-import') {
        work.status = AgentTaskStatus.paused;
        work.resumeRequired = true;
        await db.agentTaskBox.put(work.id, work);
        await coordinator.restore();
        expect(gateway.actors, isEmpty);
        await coordinator.resumeByUser(work.id);
      } else if (scenario == 'startup') {
        work.status = AgentTaskStatus.planning;
        await db.agentTaskBox.put(work.id, work);
        await coordinator.restore();
        await coordinator
            .restore(); // One startup dispatch, even on repeated reads.
      } else {
        await coordinator.submit(work);
      }
      if (scenario == 'deferred') {
        await coordinator.respondToDecision(work.id,
            decisionId: 'later-question',
            revision: 1,
            answer: '此项先放着，独立工作继续',
            disposition: 'defer');
        injected = true;
      }
      if (competing != null) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(gateway.actors, isEmpty);
        await competing.release();
      }

      for (var attempt = 0;
          attempt < _p7DriveAttempts &&
              !{AgentTaskStatus.completed, AgentTaskStatus.cancelled}
                  .contains(work.status);
          attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        final state =
            WorkDiscussionState.fromExecutionState(work.executionStateJson)!
                .collaboration!;
        if ({'manual', 'manual-no-tester', 'waiver'}.contains(scenario) &&
            !injected &&
            state.decisions.isNotEmpty) {
          final decision = state.decisions.last;
          if (decision['kind'] == 'acceptance' &&
              decision['status'] == 'pending') {
            injected = true;
            await coordinator.respondToDecision(work.id,
                decisionId: decision['id'] as String,
                revision: decision['revision'] as int,
                answer: '我已对当前候选核对原复现与回归；保留全部记录。',
                disposition: scenario != 'waiver' ? 'manual' : 'waive');
          }
        }
        if (scenario == 'cancel' && gateway.actors.isNotEmpty && !injected) {
          injected = true;
          await coordinator.stop(work.id);
        }
        if (scenario == 'deferred' &&
            work.status == AgentTaskStatus.paused &&
            state.workItems
                .where((i) => i['id'] != 'later')
                .every((i) => i['status'] == 'done') &&
            state.workItems.isNotEmpty) {
          break;
        }
        if (negative &&
            scenario != 'deferred' &&
            (injected || _p7BlockedToolCases.contains(scenario)) &&
            (state.hasPendingDecision || work.resumeRequired)) {
          break;
        }
      }
      if (negative) {
        await _p7AssertBlocked(scenario, injected, work, db, root(), events());
        return;
      }
      expect(work.status, AgentTaskStatus.completed,
          reason: '${work.lastError}\n${work.executionStateJson}');
      if ({'manual', 'manual-no-tester', 'waiver'}.contains(scenario)) {
        final state =
            WorkDiscussionState.fromExecutionState(work.executionStateJson)!
                .collaboration!;
        expect(state.acceptances.single['status'],
            scenario != 'waiver' ? 'manual' : 'waived');
        expect(state.acceptances.single['evidenceRef'],
            state.decisions.last['responseRef']);
      }
      if ({'manual', 'manual-no-tester', 'waiver'}.contains(scenario)) {
        final review = db.messageBox.values
            .lastWhere((m) => m.workDelivery?['kind'] == 'review');
        expect(review.senderId, 'user');
        expect(review.senderType, 'user');
      }
      final candidates =
          await (await runner.candidatePublisher(work)).recover();
      expect(
          candidates.map((c) => c.iterationId),
          scenario == 'portable-import'
              ? ['r008', 'r009']
              : scenario == 'retest-failure'
                  ? ['r001', 'r002', 'r003']
                  : ['r001', 'r002']);
      expect(
          signatures,
          scenario == 'portable-import'
              ? ['r009:a', 'r009:b']
              : scenario == 'retest-failure'
                  ? ['r003:a', 'r003:b']
                  : scenario == 'manual-no-tester'
                      ? ['r002:a']
                      : ['r002:a', 'r002:b']);
      if (!document) {
        expect(
            command.runs,
            {'manual', 'manual-no-tester', 'waiver'}.contains(scenario)
                ? scenario == 'manual-no-tester'
                    ? 0
                    : 1
                : scenario == 'retest-failure'
                    ? 3
                    : 2);
      }
      expect(
          db.messageBox.values.where((m) => m.workDelivery?['kind'] == 'final'),
          hasLength(1));
      if (scenario == 'delivery-failure') {
        expect(work.resumeRequired, isTrue);
        final callsBeforeResend = gateway.actors.length;
        await coordinator.retry(work.id);
        for (var attempt = 0;
            attempt < _p7DriveAttempts &&
                work.status != AgentTaskStatus.completed;
            attempt++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(work.status, AgentTaskStatus.completed);
        expect(work.resumeRequired, isFalse);
        expect(gateway.actors.length, callsBeforeResend);
        expect((await (await runner.candidatePublisher(work)).recover()),
            hasLength(2));
      }
      final log = (await events().read(work.id)).events;
      expect(log.where((e) => e.kind == WorkTaskEventKind.completed),
          hasLength(1));
      expect(
          log
              .lastWhere((e) => e.kind == WorkTaskEventKind.completed)
              .timestamp
              .isBefore(db.messageBox.values
                  .where((m) => m.workDelivery?['kind'] == 'final')
                  .single
                  .timestamp),
          isFalse);
    }, timeout: const Timeout(Duration(seconds: 30)));
  }
}

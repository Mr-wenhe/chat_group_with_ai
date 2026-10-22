part of 'default_work_task_runner_stage02_test.dart';

void _registerP8RunnerTests(Directory Function() hive,
    Directory Function() root, WorkTaskEventStore Function() events) {
  Future<DefaultWorkTaskRunner> recoveryRunner(AiRequestGateway gateway,
      {bool browserContext = false}) async {
    final db = CandidateTestDatabase(hive());
    final grants = WorkFolderGrantService(
        box: db.appSettingsBox,
        directoryValidator: (_) async => true,
        writeDirectoryValidator: (_) async => true,
        isWindows: false);
    await grants.authorizeDirectory(root().path, consent: (_) async => true);
    await grants.setOrdinaryWriteConfirmation(false);
    for (final id in ['a', 'b']) {
      final config = ApiConfig(
          id: 'p8-$id',
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
              role: id == 'a' ? '软件开发工程师' : '测试工程师',
              personalityTags: [],
              systemPrompt: id,
              apiKey: '',
              apiProvider: 'deepseek',
              modelName: 'deepseek-chat',
              apiConfigId: config.id,
              toolPermissions: [
                ToolPermission.workspaceRead,
                ToolPermission.workspacePatch,
                ToolPermission.commandRun,
                if (browserContext) ToolPermission.browserContext,
              ]));
    }
    await db.chatGroupBox.put(
        'group-a',
        ChatGroup(
            id: 'group-a',
            name: 'P8',
            theme: '恢复',
            aiCharacterIds: ['a', 'b']));
    await db.workModeWorkspaceBox.put(
        'group-a',
        WorkModeWorkspace(
            conversationId: 'group-a',
            conversationType: 'group',
            workDirPath: root().path,
            projectScopeId: 'scope-a'));
    final policy = WorkspacePathPolicy(grantService: grants);
    return DefaultWorkTaskRunner(
        database: db,
        eventStore: events(),
        credentials: _TestCredentials(),
        folderGrantService: grants,
        workspaceService:
            WorkModeWorkspaceService(db: db, grantService: grants),
        mutationService: WorkspaceMutationService(
            pathPolicy: policy,
            snapshotPort: WorkSnapshotService(
                appSupportDirectory: Directory('${hive().path}/p8-support'),
                pathPolicy: policy)),
        gateway: gateway,
        workspaceFileService: WorkspaceFileService(
            pathPolicy: WorkspacePathPolicy(grantService: grants)));
  }

  WorkTaskCoordinator coordinator(DefaultWorkTaskRunner runner) {
    final instance = WorkTaskCoordinator(
        taskBox: runner.database.agentTaskBox,
        eventStore: events(),
        runner: runner,
        autoResumeRoundTimeout: const Duration(milliseconds: 10),
        discussionRunner: WorkDiscussionRunner(
            database: runner.database, credentials: _TestCredentials()));
    addTearDown(instance.dispose);
    return instance;
  }

  for (final resize in [false, true]) {
    test('P8 浏览器会话可由新责任成员先核实关闭再打开候选 resize=$resize', () async {
      if (!Platform.isMacOS) return;
      final browserCalls = <Map<String, dynamic>>[];
      final openedRefs = <String>[];
      final closedRefs = <String>[];
      final gateway =
          _BrowserSessionRecoveryGateway(openedRefs, resize: resize);
      final runner = await recoveryRunner(gateway, browserContext: true);
      const channel = MethodChannel('com.chatgroup/browser_test');
      TestWidgetsFlutterBinding.ensureInitialized();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        final arguments = Map<String, dynamic>.from(call.arguments as Map);
        browserCalls.add(arguments);
        final operation = arguments['operation'];
        final sessionRef = arguments['sessionRef'] as String;
        Map<String, dynamic> snapshot() => {
              'result': jsonEncode({
                'title': '飞行棋',
                'readyState': 'complete',
                'viewport': {'width': 800, 'height': 600},
                'visibleText': '飞行棋 测试页面',
                'textTruncated': false,
                'controls': [],
                'controlsTruncated': false,
              }),
              'content': [
                {'type': 'text', 'text': '受控浏览器截图'},
                {
                  'type': 'image_url',
                  'image_url': {'url': 'data:image/png;base64,iVBORw0KGgo='}
                }
              ]
            };
        if (operation == 'open') {
          openedRefs.add(sessionRef);
          return {'snapshot': snapshot()};
        }
        if (operation == 'click') {
          return {
            'result': jsonEncode({'ok': true})
          };
        }
        if (operation == 'assert') {
          return {
            'result': jsonEncode({'matched': true, 'textTruncated': false})
          };
        }
        if (operation == 'resize') return {'snapshot': snapshot()};
        if (operation == 'observe') {
          return {'snapshot': snapshot()};
        }
        if (operation == 'close') {
          closedRefs.add(sessionRef);
          return {'closed': true};
        }
        throw StateError('意外的浏览器操作：$operation');
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));

      final raw = candidateTestState(type: 'software', format: 'html').toJson()
        ..['plan'] = '保留冻结候选；由独立成员在离线浏览器实测。'
        ..['artifactContract'] = {
          ...candidateTestState(type: 'software', format: 'html')
              .artifactContract,
          'files': ['game.html'],
        }
        ..['workItems'] = [
          {
            'id': 'make-game',
            'ownerId': 'a',
            'kind': 'produce',
            'dependencies': [],
            'status': 'done',
            'requestRevision': 1,
            'resultRef': 'proposal:producer-result',
          }
        ]
        ..['autonomyPolicy'] = WorkCollaborationAutonomy.policyFor(['a', 'b'])
        ..['usageEvidenceRefs'] = []
        ..['coordinatorDecisions'] = [
          {
            'eventId': 'plan-ruling',
            'coordinatorId': 'a',
            'kind': 'plan',
            'subjectId': 'task-a',
            'requestRevision': 1,
            'teamRevision': 1,
            'verificationRevision': 1,
            'iterationId': '',
            'artifactDigest': '',
            'opinionEventIds': ['plan-a-1', 'plan-b-1'],
            'reason': '已收齐两名成员的方案认可。',
            'responseRef': 'plan-ruling-message',
          }
        ]
        ..['usageAssignments'] = [
          for (final member in ['a', 'b'])
            {
              'memberId': member,
              'scenarioId': 'scene-$member',
              'goal': '$member 在离线浏览器核对当前候选',
              'preconditions': '打开冻结候选并观察页面',
              'stepGoals': ['打开后关闭隔离浏览器会话'],
              'expectedResult': '只允许操作与关闭本成员场景的会话',
              'acceptanceIds': ['qa'],
              'requiredCapabilities': ['browser.context'],
              'resetMethod': '关闭当前隔离会话',
              'requestRevision': 1,
            }
        ]
        ..['acceptances'] = [
          for (final acceptance
              in candidateTestState(type: 'software', format: 'html')
                  .acceptances)
            {
              ...acceptance,
              'method': '在隔离浏览器打开并关闭当前候选',
              'requiredCapability': 'browser.context',
            }
        ];
      final initial = WorkCollaborationState.tryParse(raw);
      expect(initial, isNotNull);
      expect(initial!.teamQualified, isTrue);
      expect(initial.usagePlanReady, isTrue);
      expect(initial.singleMakerReady, isTrue);
      expect(initial.issuesResolved, isTrue);
      expect(initial.opinionsSettled('plan', 'task-a'), isTrue);
      expect(initial.planReady, isTrue);
      final task = candidateTestTask(initial)
        ..userRequest = '制作并测试离线 HTML 飞行棋'
        ..status = AgentTaskStatus.queued;
      final html = await File('${root().path}/game.html').writeAsString(
          '<!doctype html><html><head><title>飞行棋</title></head><body>游戏</body></html>');
      task.lastArtifactPaths = [html.path];
      await runner.database.workModeWorkspaceBox.put(
          task.groupId,
          WorkModeWorkspace(
              conversationId: task.groupId,
              conversationType: 'group',
              workDirPath: root().path,
              projectScopeId: 'scope-a'));
      await runner.database.agentTaskBox.put(task.id, task);
      final candidate = await runner.publishCandidate(task,
          publicationId: 'browser-session-recovery',
          requiredPaths: [html.path]);

      void bind(String member) {
        final state =
            WorkDiscussionState.fromExecutionState(task.executionStateJson)!
                .collaboration!;
        final execution = Map<String, dynamic>.from(
            jsonDecode(task.executionStateJson) as Map);
        final previousBinding = execution['workItemExecution'] as Map?;
        if (previousBinding?['actorId'] != member) {
          execution.remove('v2UsageObservationRef');
        }
        execution['workItemExecution'] = {
          'stage': 'usage',
          'workItemId': 'scene-$member',
          'iterationId': candidate.iterationId,
          'requestRevision': state.requestRevision,
          'teamRevision': state.teamRevision,
          'verificationRevision': state.verificationRevision,
          'actorId': member,
        };
        task.executionStateJson = jsonEncode(execution);
        task.characterId = member;
      }

      bind('a');
      await runner.run(task, WorkTaskCancellation());
      expect(task.status, AgentTaskStatus.paused);
      expect(openedRefs, hasLength(1));
      expect(closedRefs, isEmpty);
      expect(
          browserCalls.map((call) => call['operation']).toList(),
          resize
              ? ['open', 'resize', 'assert', 'observe']
              : ['open', 'click', 'observe', 'assert', 'observe']);
      final execution = jsonDecode(task.executionStateJson) as Map;
      final observation = jsonDecode(await events().readDiscussionDetail(
          task.id, execution['v2UsageObservationRef'] as String)) as Map;
      expect(
          (observation['observations'] as List).cast<Map>().firstWhere(
              (o) => o['operation'] == 'assert')['businessResultVerified'],
          isTrue);
      if (resize) {
        final modelEvents = (await events().read(task.id))
            .events
            .where((event) => event.safeMetadata['firstTokenMs'] is int);
        expect(modelEvents, isNotEmpty,
            reason: 'generation activity must retain first-token timing');
      }

      browserCalls.clear();
      bind('b');
      task
        ..status = AgentTaskStatus.queued
        ..resumeRequired = false
        ..lastError = ''
        ..pendingToolRequestJson = '';
      await runner.run(task, WorkTaskCancellation());

      expect(gateway.staleSessionRefReachedModel, isTrue);
      expect(openedRefs, hasLength(2));
      expect(closedRefs, openedRefs, reason: task.lastError);
      expect(browserCalls.map((call) => call['operation']).toList(),
          ['close', 'open', 'close']);
      expect(task.status, AgentTaskStatus.paused);
      expect(
          WorkDiscussionState.fromExecutionState(task.executionStateJson)!
              .collaboration!
              .currentIteration!['artifactDigest'],
          candidate.digest);
    }, timeout: const Timeout(Duration(seconds: 30)));
  }
  test('浏览器不确定操作仅在原生确认无会话后恢复，不放行其他副作用', () async {
    final runner = await recoveryRunner(_HangingModelGateway());
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('com.chatgroup/browser_test');
    var active = 1;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect((call.arguments as Map)['operation'], 'session-status');
      return {'activeSessionCount': active};
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final task = candidateTestTask(candidateTestState());
    await runner.database.agentTaskBox.put(task.id, task);
    void intent(String tool) {
      final root = jsonDecode(task.executionStateJson) as Map<String, dynamic>;
      root['uncertainAction'] = {'tool': tool, 'operationKey': 'uncommitted'};
      task.executionStateJson = jsonEncode(root);
    }

    intent('browser.context');
    if (Platform.isMacOS) {
      expect(await runner.validateRecovery(task), contains('仍未确认关闭'));
      active = 0;
      expect(await runner.validateRecovery(task), isNull);
      expect(
          (jsonDecode(task.executionStateJson) as Map)
              .containsKey('uncertainAction'),
          isFalse);
    } else {
      expect(await runner.validateRecovery(task), contains('无法证明结果'));
      expect(
          (jsonDecode(task.executionStateJson) as Map)
              .containsKey('uncertainAction'),
          isTrue);
    }
    intent('command.run');
    expect(await runner.validateRecovery(task), contains('无法证明结果'));
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('P1 逐成员串行试用切换 actor，不改用户钉定 executor 或借前人上下文', () async {
    final runner = await recoveryRunner(_HangingModelGateway());
    final raw = candidateTestState().toJson()
      ..['autonomyPolicy'] = WorkCollaborationAutonomy.policyFor(['a', 'b'])
      ..['usageAssignments'] = [
        for (final member in ['a', 'b'])
          {
            'memberId': member,
            'scenarioId': 'scene-$member',
            'goal': '使用场景 $member',
            'preconditions': '独立测试数据',
            'stepGoals': ['完成场景 $member'],
            'expectedResult': '场景 $member 预期结果',
            'acceptanceIds': ['qa'],
            'requiredCapabilities': ['native'],
            'resetMethod': '清理独立数据',
            'requestRevision': 1,
          }
      ]
      ..['usageEvidenceRefs'] = []
      ..['coordinatorDecisions'] = [
        {
          'eventId': 'plan-ruling',
          'coordinatorId': 'a',
          'kind': 'plan',
          'subjectId': 'task-a',
          'requestRevision': 1,
          'teamRevision': 1,
          'verificationRevision': 1,
          'iterationId': '',
          'artifactDigest': '',
          'opinionEventIds': ['plan-a-1', 'plan-b-1'],
          'reason': '已听取各成员意见',
          'responseRef': 'ruling-message',
        }
      ]
      ..['phase'] = 'reviewing'
      ..['workItems'] = [
        {
          'id': 'make',
          'ownerId': 'a',
          'kind': 'produce',
          'dependencies': [],
          'status': 'done',
          'requestRevision': 1
        }
      ]
      ..['iterations'] = [
        {
          'id': 'r001',
          'artifactDigest': 'digest-a',
          'requestRevision': 1,
          'teamRevision': 1,
          'manifestRef': 'manifest',
          'reviewRef': 'review',
          'status': 'reviewed'
        }
      ]
      ..['acceptances'] = [
        for (final a in candidateTestState().acceptances)
          {...a, 'status': 'passed', 'evidenceRef': 'report'}
      ];
    final state = WorkCollaborationState.tryParse(raw)!;
    final task = candidateTestTask(state);
    final nativeEvidence =
        await events().writeNativeEvidence(task.id, 'png', [1, 2, 3]);
    final shell =
        WorkDiscussionState.fromExecutionState(task.executionStateJson)!
            .copyWith(
      executorId: 'a',
      deliverableContract: WorkRoleRouter.deliverableContractForRequest(
              task.userRequest,
              explicitExecutorId: 'a')
          .toJson(),
    );
    task.executionStateJson = jsonEncode({'discussionState': shell.toJson()});
    await runner.database.agentTaskBox.put(task.id, task);
    expect(await runner.prepareCollaborationWork(task), isTrue);
    expect(task.characterId, 'a');
    final receiptState = state.toJson()
      ..['revision'] = 2
      ..['appliedEventIds'] = ['used-a'];
    final receiptRef = await WorkUsageReceiptStore(events()).record(
        state: state,
        actorId: 'a',
        feedbackRef: 'feedback-a',
        observations: [
          WorkUsageObservation(
            taskId: task.id,
            conversationId: task.groupId,
            actorId: 'a',
            scenarioId: 'scene-a',
            iterationId: 'r001',
            artifactDigest: 'digest-a',
            planDigest: state.usagePlanDigest,
            verificationRevision: 1,
            runtime: 'macos-native',
            sessionRef: 'session-a',
            operation: 'click',
            beforeRef: 'before-a',
            afterRef: 'after-a',
            outputRefs: [nativeEvidence],
            verifiedAcceptanceIds: ['qa'],
            businessResultVerified: true,
          )
        ]);
    receiptState['usageEvidenceRefs'] = [
      {
        'taskId': task.id,
        'conversationId': task.groupId,
        'memberId': 'a',
        'scenarioId': 'scene-a',
        'requestRevision': 1,
        'teamRevision': 1,
        'iterationId': 'r001',
        'artifactDigest': 'digest-a',
        'planDigest': state.usagePlanDigest,
        'verificationRevision': 1,
        'receiptRef': receiptRef,
        'feedbackRef': 'feedback-a',
        'status': 'passed',
      }
    ];
    final next = state.apply(WorkCollaborationUpdate(
        taskId: task.id,
        conversationId: task.groupId,
        expectedRevision: 1,
        eventId: 'used-a',
        sourceRole: 'usage',
        sourceId: 'a',
        next: WorkCollaborationState.tryParse(receiptState)!));
    task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
        task.executionStateJson, shell.copyWith(collaboration: next),
        expectedCollaborationRevision: 1);
    final rootState =
        jsonDecode(task.executionStateJson) as Map<String, dynamic>;
    task.executionStateJson = jsonEncode({
      ...rootState,
      'lastToolResult': {'message': 'a 的观察'}
    });
    expect(await runner.prepareCollaborationWork(task), isTrue);
    expect(task.characterId, 'b');
    final after =
        WorkDiscussionState.fromExecutionState(task.executionStateJson)!;
    expect(after.executorId, 'a');
    final reassigned = after.collaboration!.toJson()
      ..['workItems'] = [
        for (final item in after.collaboration!.workItems)
          {...item, if (item['kind'] == 'produce') 'ownerId': 'b'}
      ];
    expect(
        after
            .copyWith(
                collaboration: WorkCollaborationState.tryParse(reassigned)!)
            .isProductionExecutorConsistent,
        isFalse);
    final binding = (jsonDecode(task.executionStateJson)
        as Map)['workItemExecution'] as Map;
    expect(binding['stage'], 'usage');
    expect(binding['actorId'], 'b');
    expect(binding['workItemId'], 'scene-b');
    expect(
        (jsonDecode(task.executionStateJson) as Map)
            .containsKey('lastToolResult'),
        isFalse);
    expect(after.collaboration!.deliveryReady, isFalse);
  });

  test(
      'P8 recovery proves overwrite postcondition or retains uncertain operation',
      () async {
    final runner = await recoveryRunner(_HangingModelGateway());
    final task = candidateTestTask(candidateTestState());
    final file =
        await File('${root().path}/result.txt').writeAsString('committed');
    final intent = {
      'operationKey': 'overwrite-1',
      'tool': 'workspace.patch',
      'path': file.path,
      'expectedSha256': sha256.convert(utf8.encode('committed')).toString()
    };
    final original =
        jsonDecode(task.executionStateJson) as Map<String, dynamic>;
    task.executionStateJson =
        jsonEncode({...original, 'uncertainAction': intent});
    await runner.database.agentTaskBox.put(task.id, task);
    expect(await runner.validateRecovery(task), isNull);
    expect(
        (jsonDecode(task.executionStateJson) as Map)
            .containsKey('uncertainAction'),
        isFalse);
    expect(await events().hasCommittedAction(task.id, 'overwrite-1'), isTrue);
    await file.writeAsString('external change');
    task.executionStateJson = jsonEncode({
      ...original,
      'uncertainAction': {...intent, 'operationKey': 'overwrite-2'}
    });
    expect(await runner.validateRecovery(task), contains('不符合预期摘要'));
    expect(
        (jsonDecode(task.executionStateJson) as Map)
            .containsKey('uncertainAction'),
        isTrue);
    expect(await file.readAsString(), 'external change');
  });

  test('P8 unprovable command releases slot and asks user without replay',
      () async {
    final gateway = _HangingModelGateway();
    final runner = await recoveryRunner(gateway);
    final task = candidateTestTask(candidateTestState())
      ..status = AgentTaskStatus.runningTool;
    task.executionStateJson = jsonEncode({
      ...jsonDecode(task.executionStateJson) as Map,
      'uncertainAction': {
        'tool': 'command.run',
        'operationKey': 'external-command'
      }
    });
    await runner.database.agentTaskBox.put(task.id, task);
    final owner = coordinator(runner);
    await owner.restore();
    for (var i = 0; i < 100 && task.status != AgentTaskStatus.paused; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(task.status, AgentTaskStatus.paused);
    expect(task.resumeRequired, isTrue);
    expect(task.lastError, contains('无法证明结果'));
    expect(owner.runningTaskCount, 0);
    expect(gateway.requestTokens, isEmpty);
    expect(
        WorkTaskUserAction.forTask(task)
            .any((a) => a.blockerId == 'uncertainAction'),
        isTrue);
  });

  test('P8 durable commit receipt survives reopen and is task scoped',
      () async {
    await events().recordCommittedAction('task-a', 'command-1');
    final reopened =
        WorkTaskEventStore(appSupportDirectory: events().appSupportDirectory);
    addTearDown(reopened.close);
    expect(await reopened.hasCommittedAction('task-a', 'command-1'), isTrue);
    expect(
        await reopened.hasCommittedAction('other-task', 'command-1'), isFalse);
    final runner = await recoveryRunner(_HangingModelGateway());
    final task = candidateTestTask(candidateTestState());
    task.executionStateJson = jsonEncode({
      ...jsonDecode(task.executionStateJson) as Map,
      'uncertainAction': {'tool': 'command.run', 'operationKey': 'command-1'}
    });
    await runner.database.agentTaskBox.put(task.id, task);
    expect(await runner.validateRecovery(task), isNull);
    expect(
        (jsonDecode(task.executionStateJson) as Map)
            .containsKey('uncertainAction'),
        isFalse);
  });

  test('P8 恢复通道的转换失败会被记成事件，而不是只写 lastError', () async {
    final runner = await recoveryRunner(_HangingModelGateway());
    final task = candidateTestTask(candidateTestState())
      ..status = AgentTaskStatus.paused;
    // 讨论状态合法但属于另一个会话：转换时必然抛错，而过去这条分支只写
    // lastError、事件日志里一片空白。
    final raw = jsonDecode(task.executionStateJson) as Map<String, dynamic>;
    raw['discussionState'] = WorkDiscussionState.initial(
      conversationId: 'another-conversation',
      deliverableContract: const <String, dynamic>{
        'contentScope': '另一个会话的任务',
      },
    ).toJson();
    task.executionStateJson = jsonEncode(raw);
    await runner.database.agentTaskBox.put(task.id, task);
    await coordinator(runner).restore();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(task.lastError, contains('恢复现场核对失败'));
    expect(
        (await events().read(task.id)).events.any((e) => e.title == '恢复现场核对失败'),
        isTrue,
        reason: '恢复通道失败必须能在事件日志里看到，否则永远查不出它跑没跑过');
  });

  for (final status in [
    AgentTaskStatus.paused,
    AgentTaskStatus.waitingForApproval,
    AgentTaskStatus.cancelled,
    AgentTaskStatus.completed,
    AgentTaskStatus.interrupted
  ]) {
    test('P8 startup preserves deliberate wait or terminal $status', () async {
      final gateway = _HangingModelGateway();
      final runner = await recoveryRunner(gateway);
      final task = candidateTestTask(candidateTestState())
        ..status = status
        ..resumeRequired = true;
      await runner.database.agentTaskBox.put(task.id, task);
      final original = task.executionStateJson;
      await coordinator(runner).restore();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(task.status, status);
      expect(gateway.requestTokens, isEmpty);
      if (task.isTerminal) expect(task.executionStateJson, original);
    });
  }

  test('P1 旧 v2 启动保留现场并等待显式策略升级，不自动重跑', () async {
    final gateway = _HangingModelGateway();
    final runner = await recoveryRunner(gateway);
    final raw = candidateTestState().toJson()
      ..['workItems'] = [
        {
          'id': 'produce',
          'ownerId': 'a',
          'kind': 'produce',
          'dependencies': [],
          'status': 'active',
          'requestRevision': 1
        }
      ];
    final task = candidateTestTask(WorkCollaborationState.tryParse(raw)!)
      ..status = AgentTaskStatus.planning;
    await runner.database.agentTaskBox.put(task.id, task);
    final owner = coordinator(runner);
    await owner.restore();
    await owner.restore();
    for (var i = 0; i < 100 && gateway.requestTokens.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(gateway.requestTokens, isEmpty);
    expect(task.status, AgentTaskStatus.paused);
    expect(task.resumeRequired, isTrue);
    expect(task.lastError, contains('自主策略'));
    expect(owner.runningTaskCount, 0);
    expect((jsonDecode(task.executionStateJson) as Map)['autoResumeCount'],
        isNull);
    await owner.dispose();
    expect(gateway.requestTokens, isEmpty);
  });

  test(
      'P8 legacy migration retains FIFO files and requires explicit confirmation',
      () async {
    final gateway = _HangingModelGateway();
    final runner = await recoveryRunner(gateway);
    final task = AgentTask(
        id: 'legacy',
        groupId: 'group-a',
        characterId: 'a',
        userRequest: '保留已有产物',
        workModeTask: true,
        status: AgentTaskStatus.planning,
        queuedUserRequests: ['先补充测试', '再补充报告'],
        lastArtifactPaths: ['old-result.txt'],
        executionStateJson: WorkDiscussionState.mergeIntoExecutionState(
            '',
            WorkDiscussionState.initial(conversationId: 'group-a')
                .copyWith(understandingPercent: 100)));
    await runner.database.agentTaskBox.put(task.id, task);
    await coordinator(runner).restore();
    expect(task.status, AgentTaskStatus.paused);
    expect(task.resumeRequired, isTrue);
    expect(task.queuedUserRequests, ['先补充测试', '再补充报告']);
    expect(task.lastArtifactPaths, ['old-result.txt']);
    expect(
        WorkDiscussionState.fromExecutionState(task.executionStateJson)!
            .collaboration!
            .approvals,
        isEmpty);
    expect(gateway.requestTokens, isEmpty);
  });

  test(
      'P8 unknown checkpoint preserved and changed member invalidates recovery',
      () async {
    final gateway = _HangingModelGateway();
    final runner = await recoveryRunner(gateway);
    final task = candidateTestTask(candidateTestState())
      ..status = AgentTaskStatus.planning;
    const future = '{"schemaVersion":99,"future":{"keep":"history"}}';
    task.executionStateJson = future;
    await runner.database.agentTaskBox.put(task.id, task);
    await coordinator(runner).restore();
    expect(task.executionStateJson, future);
    expect(task.status, AgentTaskStatus.paused);
    expect(gateway.requestTokens, isEmpty);
    final valid = candidateTestTask(candidateTestState());
    runner.database.aiCharacterBox.get('b')!.isActive = false;
    // 拒绝的理由必须写到具体成因：一句「责任成员失效」看不出该恢复配置、
    // 重新启用成员，还是换人。
    expect(await runner.validateRecovery(valid), contains('当前未启用'));
    expect(
        WorkDiscussionState.fromExecutionState(valid.executionStateJson)!
            .collaboration!
            .hasBlockingDecision,
        isTrue);
  });
}

class _BrowserSessionRecoveryGateway extends AiRequestGateway {
  final List<String> openedRefs;
  final Map<String, int> calls = {};
  bool staleSessionRefReachedModel = false;

  final bool resize;
  _BrowserSessionRecoveryGateway(this.openedRefs, {this.resize = false})
      : super(store: MemoryGovernanceStore(), client: _UnusedClient());

  @override
  Future<Map<String, dynamic>> sendChatMessageStreamed(
      {required String apiKey,
      required ApiProvider provider,
      ApiProtocol apiProtocol = ApiProtocol.defaultValue,
      String? promptCacheKey,
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
      String? taskId,
      int? runBoundary,
      bool requiresTools = false,
      bool userInitiated = false,
      bool finishOnTerminalFrame = false,
      String? reasoningEffort,
      void Function()? onResponseActivity,
      void Function(ChatStreamEvent event)? onEvent}) async {
    if (resize) {
      onResponseActivity?.call();
      onEvent?.call(ChatStreamEvent.token('{"public_update":"正在检查浏览器布局。"}'));
    }
    final call =
        calls.update(characterId, (count) => count + 1, ifAbsent: () => 1);
    final encodedMessages = jsonEncode(messages);
    Map<String, dynamic> response(String action,
            {Map<String, dynamic>? tool, String? question}) =>
        {
          'success': true,
          'message': jsonEncode({
            'action': action,
            'public_update': action == 'tool' ? '处理当前浏览器步骤。' : '暂停当前试用。',
            'tool': tool == null
                ? null
                : {'name': 'browser.context', 'arguments': tool},
            'completion': action == 'clarify' ? {'question': question} : null,
          })
        };
    Map<String, dynamic> open() =>
        response('tool', tool: {'operation': 'open'});
    Map<String, dynamic> click(String ref) => response('tool',
        tool: {'operation': 'click', 'sessionRef': ref, 'label': '飞行棋 测试页面'});
    Map<String, dynamic> close(String ref) =>
        response('tool', tool: {'operation': 'close', 'sessionRef': ref});
    Map<String, dynamic> assertPage(String ref,
            {String expectedText = '只允许操作'}) =>
        response('tool', tool: {
          'operation': 'assert',
          'sessionRef': ref,
          'acceptanceId': 'qa',
          'expectedText': expectedText,
        });
    Map<String, dynamic> pause() => response('clarify', question: '继续前暂停测试夹具。');

    if (characterId == 'a') {
      switch (call) {
        case 1:
          return open();
        case 2:
          return resize
              ? response('tool', tool: {
                  'operation': 'resize',
                  'sessionRef': openedRefs.last,
                  'width': 375,
                  'height': 667
                })
              : click(openedRefs.last);
        case 3:
          return close(openedRefs.last);
        case 4:
          return assertPage(openedRefs.last, expectedText: '越权的预期文本');
        case 5:
          return assertPage(openedRefs.last);
        default:
          return pause();
      }
    }
    switch (call) {
      case 1:
        return open();
      case 2:
        final staleRef = openedRefs.first;
        staleSessionRefReachedModel = encodedMessages.contains(staleRef) &&
            encodedMessages.contains('browserSessionOccupied');
        return close(staleRef);
      case 3:
        return open();
      case 4:
        return close(openedRefs.last);
      default:
        return pause();
    }
  }
}

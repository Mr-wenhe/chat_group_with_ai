part of 'default_work_task_runner_stage02_test.dart';

void _registerP8RunnerTests(Directory Function() hive,
    Directory Function() root, WorkTaskEventStore Function() events) {
  Future<DefaultWorkTaskRunner> recoveryRunner(
      _HangingModelGateway gateway) async {
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
                ToolPermission.commandRun
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

  test(
      'P8 startup does not apply legacy automatic attempt deadline to healthy v2',
      () async {
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
    expect(gateway.requestTokens, hasLength(1),
        reason: '${task.lastError} ${task.executionStateJson}');
    expect(gateway.requestTokens.single.isCancelled, isFalse);
    expect(owner.runningTaskCount, 1);
    expect((jsonDecode(task.executionStateJson) as Map)['autoResumeCount'],
        isNull);
    await owner.dispose();
    expect(gateway.requestTokens.single.isCancelled, isTrue);
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
    expect(await runner.validateRecovery(valid), contains('责任成员失效'));
    expect(
        WorkDiscussionState.fromExecutionState(valid.executionStateJson)!
            .collaboration!
            .hasBlockingDecision,
        isTrue);
  });
}

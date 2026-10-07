part of 'work_discussion_v2_test.dart';

class _Credentials implements ApiCredentialResolver {
  @override
  Future<String?> resolve(ApiConfig config) async => 'test-key';
}

class _ModelClient extends ChatApiService {
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>, String)
      respond;
  _ModelClient(this.respond);
  @override
  Future<Map<String, dynamic>> sendChatMessageWithResponseLimit(
      {required String apiKey,
      required ApiProvider provider,
      ApiProtocol apiProtocol = ApiProtocol.defaultValue,
      String? customBaseUrl,
      required String model,
      required List<Map<String, dynamic>> messages,
      double temperature = 0.85,
      int maxTokens = 1024,
      Duration? receiveTimeout,
      int maxRetries = 3,
      CancelToken? cancelToken,
      bool structuredJson = false,
      bool allowReasoningContentFallback = false,
      required int maxResponseBytes}) {
    expect(maxTokens, WorkDiscussionRunner.discussionMaxTokens);
    expect(apiKey, 'test-key');
    return respond(
        jsonDecode(messages.last['content'] as String) as Map<String, dynamic>,
        model);
  }
}

Map<String, dynamic> _turn(String action,
        {String text = '我确认当前方案。',
        List<Map<String, dynamic>> issues = const [],
        List<Map<String, dynamic>> resolutions = const [],
        String issue = '',
        Map<String, dynamic>? tool,
        Map<String, dynamic>? proposal,
        Map<String, dynamic>? approval}) =>
    {
      'success': true,
      'message': jsonEncode({
        'schemaVersion': 2,
        'action': action,
        'public_update': text,
        'issue_id': issue,
        'next_member_id': '',
        'issues': issues,
        'resolutions': resolutions,
        'proposal': proposal,
        'approval': approval,
        'decision': null,
        'tool': tool
      })
    };

late Directory dir;
late DatabaseService db;
late WorkTaskEventStore events;
late DefaultWorkTaskRunner execution;
late AgentTask task;

Future<void> _openFixture() async {
  dir = await openLifecycleHive();
  db = DatabaseService();
  events =
      WorkTaskEventStore(appSupportDirectory: Directory('${dir.path}/support'));
  final project = await Directory('${dir.path}/project').create();
  for (var i = 0; i < 97; i++) {
    await File('${project.path}/source$i.dart')
        .writeAsString('const diceGuard$i = true;');
  }
  final grants = WorkFolderGrantService(
      box: db.appSettingsBox,
      directoryValidator: (_) async => true,
      writeDirectoryValidator: (_) async => true,
      isWindows: false);
  await grants.authorizeDirectory(project.path, consent: (_) async => true);
  final policy = WorkspacePathPolicy(grantService: grants);
  execution = DefaultWorkTaskRunner(
      database: db,
      eventStore: events,
      credentials: _Credentials(),
      workspaceService: WorkModeWorkspaceService(db: db, grantService: grants),
      folderGrantService: grants,
      workspaceFileService: WorkspaceFileService(pathPolicy: policy),
      mutationService: WorkspaceMutationService(pathPolicy: policy));
  for (final entry
      in {'dev': '软件开发工程师', 'qa': '测试工程师', 'extra': '财务会计'}.entries) {
    final config = ApiConfig(
        id: 'config-${entry.key}',
        name: entry.key,
        provider: 'deepseek',
        modelName: entry.key == 'qa' ? 'deepseek-reasoner' : 'deepseek-chat',
        hasCredential: true,
        credentialId: 'credential-${entry.key}');
    await db.apiConfigBox.put(config.id, config);
    await db.aiCharacterBox.put(
        entry.key,
        AICharacter(
            id: entry.key,
            name: entry.key,
            avatar: 'D',
            age: 30,
            role: entry.value,
            personalityTags: const [],
            systemPrompt: '我是${entry.key}，按自己的责任回应。',
            apiKey: '',
            apiProvider: 'deepseek',
            modelName: 'deepseek-chat',
            apiConfigId: config.id,
            toolPermissions: const [ToolPermission.workspaceRead]));
  }
  final group = ChatGroup(
      id: 'v2-group',
      name: '项目讨论',
      theme: '软件开发',
      aiCharacterIds: const ['dev', 'qa', 'extra']);
  await db.chatGroupBox.put(group.id, group);
  task = AgentTask(
      id: 'v2-task',
      groupId: group.id,
      characterId: 'dev',
      userRequest: '开发游戏，读取项目 ${project.path}',
      workModeTask: true,
      requestedPermissions: const [ToolPermission.workspaceRead]);
  final legacy = WorkDiscussionState.initial(
      conversationId: group.id,
      deliverableContract: const {
        'deliverableType': 'source',
        'format': 'html',
        'location': 'game.html',
        'contentScope': '开发游戏',
        'revisionTarget': '',
        'requestRevision': 1
      });
  final workspace = await execution.workspaceService.loadOrCreate(
      conversationId: group.id,
      isDirectChat: false,
      preferredRootPath: project.path);
  final state = WorkDiscussionState.fromLegacyTask(task, legacy,
      projectScopeId: workspace.projectScopeId!);
  task.executionStateJson =
      WorkDiscussionState.mergeIntoExecutionState('', state);
}

Future<void> _closeFixture() async {
  await events.close();
  await closeLifecycleHive(dir, db);
}

Future<AgentTask> apply(WorkCollaborationUpdate update) async {
  final state =
      WorkDiscussionState.fromExecutionState(task.executionStateJson)!;
  final next = state.collaboration!.apply(update);
  task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
      task.executionStateJson,
      state.copyWith(
          collaboration: next, requestRevision: next.requestRevision),
      expectedCollaborationRevision: update.expectedRevision);
  if (db.agentTaskBox.containsKey(task.id)) {
    await db.agentTaskBox.put(task.id, task);
  }
  return task;
}

Map<String, dynamic> proposal(Map<String, dynamic> s) => {
      'scope': s['scope'],
      'plan': '按钮移动中禁用，工作项执行后再验收。',
      'artifactContract': s['artifactContract'],
      'workItems': [
        {'id': 'implementation', 'ownerId': 'dev', 'dependencies': <String>[]},
        {
          'id': 'test',
          'ownerId': 'qa',
          'dependencies': ['implementation']
        }
      ],
      'acceptances': [
        {
          'id': 'dice',
          'method': '连续点击只能触发一次移动',
          'requiredCapability': 'testing'
        }
      ]
    };
Map<String, dynamic> approval(Map<String, dynamic> s) => {
      'kind': 'plan',
      'subjectId': task.id,
      'approved': true,
      'requestRevision': s['requestRevision'],
      'teamRevision': s['teamRevision'],
      'verificationRevision': s['verificationRevision']
    };
WorkDiscussionRunner modelRunner(
        Future<Map<String, dynamic>> Function(AICharacter, Map<String, dynamic>)
            respond) =>
    WorkDiscussionRunner(
        database: db,
        credentials: _Credentials(),
        eventStore: events,
        investigate: execution.investigate,
        completion: (
                {required character,
                required config,
                required apiKey,
                required provider,
                required conversationId,
                required messages,
                required timeout,
                cancelToken}) =>
            respond(
                character,
                jsonDecode(messages.last['content'] as String)
                    as Map<String, dynamic>));
Future<Map<String, dynamic>> confirm(
    AICharacter member, Map<String, dynamic> context) async {
  final s = Map<String, dynamic>.from(context['collaboration'] as Map);
  return (s['plan'] as String).isEmpty ||
          (s['workItems'] as List)
              .any((i) => i['requestRevision'] != s['requestRevision'])
      ? _turn('propose', proposal: proposal(s))
      : _turn('approve', approval: approval(s));
}

Future<void> waitFor(bool Function() condition) async {
  for (var i = 0; i < 1000 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue);
}

void _registerProgressGuardTest() {
  test('重复自己的认可不能伪造进展，P2 阻塞且不凑满旧总轮数', () async {
    var calls = 0;
    final runner = modelRunner((member, context) async {
      calls++;
      final response = await confirm(member, context);
      final body =
          jsonDecode(response['message'] as String) as Map<String, dynamic>;
      body['next_member_id'] = 'dev';
      return {'success': true, 'message': jsonEncode(body)};
    });
    await runner.runCollaboration(task, WorkTaskCancellation(), apply);
    final state =
        WorkDiscussionState.fromExecutionState(task.executionStateJson)!
            .collaboration!;
    expect(state.planReady, isFalse);
    expect(state.approvals.length, 1);
    expect(state.hasPendingDecision, isTrue);
    expect(calls, lessThan(16));
  });
}

void _registerFailureBoundaryTest() {
  test('模型掉线保留责任，协议预览不能成为认可', () async {
    final runner = WorkDiscussionRunner(
      database: db,
      credentials: _Credentials(),
      eventStore: events,
      completion: (
              {required character,
              required config,
              required apiKey,
              required provider,
              required conversationId,
              required messages,
              required timeout,
              cancelToken}) async =>
          {'success': false, 'message': '连接失败，模型暂不可用'},
    );
    await runner.runCollaboration(task, WorkTaskCancellation(), apply);
    final state =
        WorkDiscussionState.fromExecutionState(task.executionStateJson)!
            .collaboration!;
    expect(state.team.singleWhere((m) => m['memberId'] == 'dev')['available'],
        false);
    expect(state.hasPendingDecision, true);
    expect(state.approvals, isEmpty);
    expect(db.messageBox.values, isEmpty);
  });
}

void _registerScopeBoundaryTest() {
  for (final conflicts in [false, true]) {
    test('全员提案保留明确禁止事项，只有实际冲突才交用户：$conflicts', () async {
      task.userRequest += '；不要联网';
      final original =
          WorkDiscussionState.fromExecutionState(task.executionStateJson)!;
      final json = original.collaboration!.toJson()
        ..['scope'] = task.userRequest
        ..['revision'] = 2
        ..['requestRevision'] = 2
        ..['appliedEventIds'] = ['user-input'];
      await apply(WorkCollaborationUpdate(
          taskId: task.id,
          conversationId: task.groupId,
          expectedRevision: 1,
          eventId: 'user-input',
          sourceRole: 'user',
          sourceId: 'user',
          next: WorkCollaborationState.tryParse(json)!));
      final extra = conflicts ? '增加联网' : '增加键盘操作';
      final runner = modelRunner((member, context) async {
        final state =
            Map<String, dynamic>.from(context['collaboration'] as Map);
        final issues = state['issues'] as List;
        if (issues.isEmpty) {
          return _turn('respond', issues: [
            {
              'id': 'idea',
              'kind': 'idea',
              'target': 'development',
              'problem': extra,
              'evidenceRef': '',
              'retestCondition': '确认完整方案'
            }
          ]);
        }
        if (issues.first['resolutionRef'] == '') {
          final plan = proposal(state)..['scope'] = '${state['scope']}；$extra';
          return _turn('propose', issue: 'idea', proposal: plan);
        }
        return _turn('approve', approval: {
          ...approval(state),
          if (issues.first['status'] == 'open') ...{
            'kind': 'idea',
            'subjectId': 'idea'
          }
        });
      });
      await runner.runCollaboration(task, WorkTaskCancellation(), apply);
      final result =
          WorkDiscussionState.fromExecutionState(task.executionStateJson)!
              .collaboration!;
      expect(result.scope, contains('不要联网'));
      expect(result.planReady, !conflicts);
      expect(result.hasPendingDecision, conflicts);
      expect(task.requestedPermissions, const [ToolPermission.workspaceRead]);
    });
  }
}

void _registerDocumentInvestigationTest() {
  test('真实授权图片调查以原生多模态接回成员，详情不存图片字节', () async {
    final config = db.apiConfigBox.get('config-dev')!
      ..provider = 'qwen'
      ..modelName = 'qwen-vl-max';
    await db.apiConfigBox.put(config.id, config);
    await File('${dir.path}/project/diagram.png').writeAsBytes(base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aRZkAAAAASUVORK5CYII='));
    var imageSeen = false;
    final runner = WorkDiscussionRunner(
        database: db,
        credentials: _Credentials(),
        eventStore: events,
        investigate: execution.investigate,
        completion: (
            {required character,
            required config,
            required apiKey,
            required provider,
            required conversationId,
            required messages,
            required timeout,
            cancelToken}) async {
          final context = jsonDecode(messages.firstWhere((m) =>
                  m['role'] == 'user' &&
                  m['content'] is String &&
                  (m['content'] as String).startsWith('{'))['content']
              as String) as Map<String, dynamic>;
          final s = Map<String, dynamic>.from(context['collaboration'] as Map);
          if ((s['issues'] as List).isEmpty) {
            return _turn('respond', issues: [
              {
                'id': 'image',
                'kind': 'decision',
                'target': 'code',
                'problem': '核查授权图示',
                'evidenceRef': '',
                'retestCondition': '实际读取授权图片'
              }
            ]);
          }
          if ((context['evidence'] as Map).isEmpty) {
            return _turn('investigate', issue: 'image', tool: {
              'name': 'workspace.document',
              'arguments': {'path': 'diagram.png'}
            });
          }
          if ((s['issues'] as List).single['status'] == 'open') {
            expect(character.id, 'dev');
            final parts = messages.where((m) => m['content'] is List).single;
            expect(jsonEncode(parts['content']),
                contains('data:image/png;base64,'));
            expect(jsonEncode(context), isNot(contains('data:image/')));
            expect(
                (jsonDecode(task.executionStateJson) as Map)['v2ProgressGuard']
                    ['noProgressCount'],
                0);
            imageSeen = true;
            return _turn('propose',
                resolutions: [
                  {
                    'id': 'image',
                    'resolution': '授权图示已作为原生图片接回当前成员',
                    'evidenceRef': (context['evidence'] as Map).keys.single
                  }
                ],
                proposal: proposal(s));
          }
          return _turn('approve', approval: approval(s));
        });
    await runner.runCollaboration(task, WorkTaskCancellation(), apply);
    expect(imageSeen, true,
        reason: task.executionStateJson +
            db.messageBox.values.map((m) => m.content).join('\n'));
    expect(
        WorkDiscussionState.fromExecutionState(task.executionStateJson)!
            .isPlanReady,
        true);
    final detail = db.messageBox.values
        .expand((m) => m.media ?? [])
        .singleWhere((a) => a.fileName == '调查来源与结果.json');
    final text = await File(detail.localPath).readAsString();
    expect(text, contains('diagram.png'));
    expect(text, isNot(contains('data:image/')));
  }, timeout: const Timeout(Duration(seconds: 30)));
}

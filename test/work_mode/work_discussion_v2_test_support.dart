part of 'work_discussion_v2_test.dart';

class _Credentials implements ApiCredentialResolver {
  @override
  Future<String?> resolve(ApiConfig config) async => 'test-key';
}

class _ReviewFixtureDatabase extends DatabaseService {
  _ReviewFixtureDatabase(this.root);
  final Directory root;
  @override
  Future<Directory> get mediaDir =>
      Directory('${root.path}/media').create(recursive: true);
}

class _MaterialFinishClient extends ChatApiService {
  _MaterialFinishClient(this.replies,
      {this.modelError, this.reasoningOnly = false});
  final List<String> replies;
  final Object? modelError;
  final bool reasoningOnly;
  final capturedMessages = <List<Map<String, dynamic>>>[];
  int modelCalls = 0;

  @override
  Future<Map<String, dynamic>> sendStructuredChatMessageStreamed({
    required String apiKey,
    required ApiProvider provider,
    ApiProtocol apiProtocol = ApiProtocol.defaultValue,
    String? promptCacheKey,
    String? customBaseUrl,
    required String model,
    required List<Map<String, dynamic>> messages,
    double temperature = 0.85,
    int maxTokens = 1024,
    Duration receiveTimeout = const Duration(seconds: 120),
    int maxRetries = 3,
    CancelToken? cancelToken,
    bool finishOnTerminalFrame = false,
    String? reasoningEffort,
    void Function()? onResponseActivity,
    void Function(ChatStreamEvent event)? onEvent,
  }) async {
    capturedMessages.add(messages);
    modelCalls++;
    if (reasoningOnly) {
      onResponseActivity?.call();
      final activity = Timer.periodic(
          const Duration(milliseconds: 5), (_) => onResponseActivity?.call());
      try {
        await cancelToken!.whenCancel;
        return {'success': false, 'message': '请求已取消'};
      } finally {
        activity.cancel();
      }
    }
    if (modelError != null) throw modelError!;
    return {'success': true, 'message': replies[modelCalls > 1 ? 1 : 0]};
  }
}

class _ReasoningEnvelopeAdapter implements HttpClientAdapter {
  int calls = 0;
  final temperatures = <double>[];
  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    calls++;
    final body = options.data as Map;
    temperatures.add((body['temperature'] as num).toDouble());
    final messages = body['messages'] as List;
    final context =
        jsonDecode(messages.last['content'] as String) as Map<String, dynamic>;
    final turn =
        await confirm(db.aiCharacterBox.get(context['memberId'])!, context);
    return ResponseBody.fromString(
        jsonEncode({
          'choices': [
            {
              'finish_reason': 'stop',
              'message': {
                'role': 'assistant',
                'content': turn['message'],
                'reasoning': 'PRIVATE_REASONING_ENVELOPE' * 4000,
              }
            }
          ]
        }),
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json']
        });
  }

  @override
  void close({bool force = false}) {}
}

class _ModelClient extends ChatApiService {
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>, String)
      respond;
  final int expectedMaxTokens;

  /// 调用契约不一致的记录（maxTokens / apiKey）。
  ///
  /// 断言不能写在这一层：这一层在讨论 runner 的 `_request` 之内，异常会被它的
  /// `on Object catch` 收成"成员请求失败"，断言不会报出它自己的原因。调用方在
  /// 跑完讨论之后断言本列表为空。
  final List<String> contractViolations = [];

  final Stream<ChatStreamEvent> Function(CancelToken?)? streamOverride;
  final bool reportActivity;
  final completionTimeouts = <Duration?>[];
  final completionTokens = <CancelToken?>[];
  final completionEfforts = <String?>[];
  void Function()? activityCallback;
  _ModelClient(this.respond,
      {this.expectedMaxTokens = 0,
      this.streamOverride,
      this.reportActivity = false});
  @override
  Stream<ChatStreamEvent> streamChatMessage({
    required String apiKey,
    required ApiProvider provider,
    ApiProtocol apiProtocol = ApiProtocol.defaultValue,
    String? promptCacheKey,
    String? customBaseUrl,
    required String model,
    required List<Map<String, dynamic>> messages,
    double temperature = 0.85,
    int maxTokens = 1024,
    Duration receiveTimeout = const Duration(seconds: 120),
    CancelToken? cancelToken,
    bool finishOnTerminalFrame = false,
    String? reasoningEffort,
    void Function()? onResponseActivity,
  }) async* {
    activityCallback = onResponseActivity;
    if (reportActivity) onResponseActivity?.call();
    if (streamOverride != null) {
      yield* streamOverride!(cancelToken);
      return;
    }
    final response = await sendChatMessageWithResponseLimit(
        apiKey: apiKey,
        provider: provider,
        apiProtocol: apiProtocol,
        customBaseUrl: customBaseUrl,
        model: model,
        messages: messages,
        temperature: temperature,
        maxTokens: maxTokens,
        receiveTimeout: receiveTimeout,
        maxResponseBytes: WorkDiscussionRunner.maxResponseBytes,
        cancelToken: cancelToken);
    if (response['success'] == false) {
      yield ChatStreamEvent.error(response['message'] as String? ?? '测试请求失败');
    } else {
      yield ChatStreamEvent(
          type: ChatStreamEventType.done,
          content: response['message'] as String? ??
              response['content'] as String? ??
              '',
          truncated: response['truncated'] == true,
          promptTokens: response['promptTokens'] as int?,
          completionTokens: response['completionTokens'] as int?);
    }
  }

  @override
  Future<Map<String, dynamic>> sendChatMessageWithResponseLimit(
      {required String apiKey,
      required ApiProvider provider,
      ApiProtocol apiProtocol = ApiProtocol.defaultValue,
      String? promptCacheKey,
      String? customBaseUrl,
      required String model,
      required List<Map<String, dynamic>> messages,
      double temperature = 0.85,
      int maxTokens = 1024,
      Duration? receiveTimeout,
      int maxRetries = 3,
      CancelToken? cancelToken,
      String? reasoningEffort,
      bool structuredJson = false,
      bool allowReasoningContentFallback = false,
      required int maxResponseBytes}) {
    completionTimeouts.add(receiveTimeout);
    completionTokens.add(cancelToken);
    completionEfforts.add(reasoningEffort);
    if (maxTokens != expectedMaxTokens) {
      contractViolations.add('maxTokens=$maxTokens，期望 $expectedMaxTokens');
    }
    if (apiKey != 'test-key') {
      contractViolations.add('apiKey 不是测试用 key');
    }
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
        Map<String, dynamic>? approval,
        Map<String, dynamic>? decision}) =>
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
        'decision': decision,
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

/// 当前待答事项。v2 讨论的阻塞项都落在这里，断言时不必各自展开状态。
List<Map<String, dynamic>> _pendingDecisions() =>
    WorkDiscussionState.fromExecutionState(task.executionStateJson)!
        .collaboration!
        .decisions
        .where((d) => const {'pending', 'deferred'}.contains(d['status']))
        .map((d) => Map<String, dynamic>.from(d))
        .toList();

Map<String, dynamic> _teamRecord(String memberId) =>
    WorkDiscussionState.fromExecutionState(task.executionStateJson)!
        .collaboration!
        .team
        .firstWhere((m) => m['memberId'] == memberId);

List<String> _optionLabels() => (_pendingDecisions().single['options'] as List)
    .whereType<Map>()
    .map((o) => o['label'] as String)
    .toList();

List<String> _optionIds() => (_pendingDecisions().single['options'] as List)
    .whereType<Map>()
    .map((o) => o['id'] as String)
    .toList();

String _pendingEvidence() => _pendingDecisions().single['evidence'] as String;

/// 往角色库里补一个真实可用的成员。
///
/// 换人候选来自**整个角色库**，不要求已经在群里——现场那次弹窗列出的正是两个
/// 群外角色。默认模型与 fixture 的 `dev` 相同，便于构造"同一个模型"的候选。
Future<void> _addLibraryMember(String id, String name, String role,
    {String modelName = 'deepseek-chat'}) async {
  final config = ApiConfig(
      id: 'config-$id',
      name: id,
      provider: 'deepseek',
      modelName: modelName,
      hasCredential: true,
      credentialId: 'credential-$id');
  await db.apiConfigBox.put(config.id, config);
  await db.aiCharacterBox.put(
      id,
      AICharacter(
          id: id,
          name: name,
          avatar: 'X',
          age: 30,
          role: role,
          personalityTags: const [],
          systemPrompt: '我是$name。',
          apiKey: '',
          apiProvider: 'deepseek',
          modelName: modelName,
          apiConfigId: config.id,
          toolPermissions: const [ToolPermission.workspaceRead]));
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

/// 用 [respond] 组装一个只接模型回应的讨论 runner。
///
/// **不要在 `respond` 里写 `expect` / `fail`**：`_request` 的 `on Object catch` 会把
/// 回调抛出的异常收成"成员请求失败"，断言不会报出它自己的原因（可能整条静默通过，
/// 也可能挂在与断言无关的行上）。要断言就先把值记进外层变量，`runCollaboration`
/// 之后再比。
WorkDiscussionRunner modelRunner(
        Future<Map<String, dynamic>> Function(AICharacter, Map<String, dynamic>)
            respond,
        {void Function(AICharacter, List<Map<String, dynamic>>)? onMessages,
        WorkModeWorkspaceService? workspaceService}) =>
    WorkDiscussionRunner(
        database: db,
        credentials: _Credentials(),
        eventStore: events,
        workspaceService: workspaceService,
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
          onMessages?.call(character, messages);
          return respond(
              character,
              jsonDecode(messages.last['content'] as String)
                  as Map<String, dynamic>);
        });
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
  test('模型点名不能跳过本人意见，空回应不能伪造进展，P2 有界阻塞', () async {
    var calls = 0;
    final runner = modelRunner((member, context) async {
      calls++;
      final response = member.id == 'dev'
          ? await confirm(member, context)
          : _turn('respond', text: '尚无新的判断。');
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
    // 掉线说的只是"这一次没产出正文"。把成员标成不可用会让系统请用户换人，而
    // 换上去的候选往往还是同一个模型——责任保留、可用性不动，只如实报出成因。
    expect(state.team.singleWhere((m) => m['memberId'] == 'dev')['available'],
        true);
    expect(state.hasPendingDecision, true);
    expect(
        state.decisions.any((d) =>
            d['status'] == 'pending' &&
            d['reason'].toString().contains('请确认补人')),
        isFalse,
        reason: '掉线不能报成成员不可用');
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

  test('已签提案采用时发现禁项冲突，应弹出用户裁决而不是静默暂停', () async {
    task.userRequest = '${task.userRequest}；不要联网';
    final original =
        WorkDiscussionState.fromExecutionState(task.executionStateJson)!;
    final current = original.collaboration!;
    final scope = task.userRequest;
    final candidate = proposal(current.toJson())..['scope'] = '$scope；增加联网功能';
    final digest = sha256
        .convert(utf8.encode(jsonEncode(candidate)))
        .toString()
        .substring(0, 24);
    await events.writeDiscussionDetail(task.id, digest, jsonEncode(candidate));
    const issueId = 'network-scope-idea';
    final issueRef = 'proposal:$digest';
    const adoptionLabel = '采用原提案';
    final stateJson = current.toJson()
      ..['revision'] = current.revision + 1
      ..['requestRevision'] = current.requestRevision + 1
      ..['scope'] = scope
      ..['issues'] = [
        ...current.issues,
        {
          'id': issueId,
          'sourceId': 'dev',
          'kind': 'idea',
          'status': 'open',
          'target': 'development',
          'problem': '提案新增联网功能',
          'evidenceRef': 'user-request',
          'resolution': '',
          'resolutionRef': issueRef,
          'retestCondition': '由用户裁决保留原范围或修改提案',
          'requestRevision': current.requestRevision + 1
        }
      ]
      ..['decisions'] = [
        ...current.decisions,
        {
          'id': 'adopt-network-scope',
          'revision': 1,
          'status': 'answered',
          'reason': '用户此前选择查看此提案',
          'answer': adoptionLabel,
          'answerKind': 'choice',
          'impact': '按用户裁决处理',
          'responseRef': 'user-adoption-choice',
          'evidence': '用户选择提案',
          'targetId': issueId,
          'kind': 'dispute',
          'options': [
            {
              'id': 'adopt:$issueRef',
              'label': adoptionLabel,
              'impact': '经用户裁决采用提案'
            }
          ]
        }
      ];
    final changed = WorkCollaborationState.tryParse(stateJson);
    expect(changed, isNotNull);
    task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
        task.executionStateJson,
        original.copyWith(
            collaboration: changed,
            requestRevision: current.requestRevision + 1),
        expectedCollaborationRevision: current.revision);

    var modelCalled = false;
    // `fail(...)` 不能写在回调里：`_request` 的 `on Object catch` 会把它收成
    // "成员请求失败"，这条守卫就永远不会报错。改成记账 + 回调外断言。
    final runner = modelRunner((member, context) async {
      modelCalled = true;
      return confirm(member, context);
    });
    await runner.runCollaboration(task, WorkTaskCancellation(), apply);
    expect(modelCalled, isFalse, reason: '已有用户裁决应在请求成员模型前转成待答裁决');

    final result =
        WorkDiscussionState.fromExecutionState(task.executionStateJson)!
            .collaboration!;
    final pending = result.decisions.last;
    expect(pending['kind'], 'dispute');
    expect(pending['targetId'], issueId);
    expect(pending['status'], 'pending');
    expect(
        (pending['options'] as List)
            .map((option) => (option as Map)['id'])
            .toList(),
        ['reject-idea', 'revise-idea']);
    expect(result.issues.single['status'], 'open');
    expect(result.approvals, isEmpty);
  }, timeout: const Timeout(Duration(seconds: 30)));
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
    // 断言必须留在回调之外：回调里抛出的异常会被 `_request` 的
    // `on Object catch` 收成"成员请求失败"，断言不会报出它自己的原因。
    final investigationCalls = <({
      String characterId,
      String imageParts,
      Map<String, dynamic> context,
      Object? noProgressCount,
    })>[];
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
            final parts = messages.where((m) => m['content'] is List).single;
            investigationCalls.add((
              characterId: character.id,
              imageParts: jsonEncode(parts['content']),
              context: context,
              noProgressCount: (jsonDecode(task.executionStateJson)
                  as Map)['v2ProgressGuard']['noProgressCount'],
            ));
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
    expect(investigationCalls, isNotEmpty);
    for (final call in investigationCalls) {
      expect(call.characterId, 'dev');
      expect(call.imageParts, contains('data:image/png;base64,'));
      expect(jsonEncode(call.context), isNot(contains('data:image/')));
      expect(call.noProgressCount, 0);
    }
    final detail = db.messageBox.values
        .expand((m) => m.media ?? [])
        .singleWhere((a) => a.fileName == '调查来源与结果.json');
    final text = await File(detail.localPath).readAsString();
    expect(text, contains('diagram.png'));
    expect(text, isNot(contains('data:image/')));
  }, timeout: const Timeout(Duration(seconds: 30)));
}

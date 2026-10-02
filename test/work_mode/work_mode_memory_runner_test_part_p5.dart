part of 'work_mode_memory_runner_test.dart';

class _FailingMemoryBox implements Box<PermanentMemory> {
  final Box<PermanentMemory> delegate;
  bool fail = true;
  _FailingMemoryBox(this.delegate);
  @override
  Future<void> put(dynamic key, PermanentMemory value) {
    if (fail) throw StateError('simulated memory persistence failure');
    return delegate.put(key, value);
  }

  @override
  Iterable<PermanentMemory> get values => delegate.values;
  @override
  bool containsKey(dynamic key) => delegate.containsKey(key);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _WorkMemoryDatabase extends DatabaseService {
  final Box<PermanentMemory> memories;
  _WorkMemoryDatabase(this.memories);
  @override
  Box<PermanentMemory> get permanentMemoryBox => memories;
}

class _OldFieldsReader implements BinaryReader {
  final List<int> bytes;
  final List<dynamic> values;
  _OldFieldsReader(Map<int, dynamic> fields)
      : bytes = [fields.length, ...fields.keys],
        values = fields.values.toList();
  @override
  int readByte() => bytes.removeAt(0);
  @override
  dynamic read([int? typeId]) => values.removeAt(0);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void registerP5Tests(
    DatabaseService Function() database, Directory Function() root) {
  test('P5 旧 Hive 字段没有来源/作用域时安全默认，不补造经历', () {
    final now = DateTime.now();
    final memory = PermanentMemoryAdapter().read(_OldFieldsReader({
      0: 'old',
      1: 'dev',
      2: MemoryKind.fact,
      3: '旧项目断言',
      4: <String>[],
      5: MemoryStatus.active,
      6: 50,
      7: 1.0,
      8: false,
      9: false,
      10: <String>[],
      11: MemoryOriginType.group,
      12: null,
      13: '旧群',
      14: <String>[],
      15: <String>[],
      16: now,
      17: now,
      18: now,
      19: null,
    }));
    final workspace = WorkModeWorkspaceAdapter().read(_OldFieldsReader({
      0: 'old-workspace',
      1: 'g',
      2: 'group',
      3: '',
      4: now,
    }));
    final message = MessageAdapter().read(_OldFieldsReader({
      0: 'old-message',
      1: 'g',
      2: 'dev',
      3: 'ai',
      4: '旧消息',
      5: now,
      6: null,
      7: false,
      8: <String>[],
      9: null,
      10: <String>[],
      11: null,
      12: null,
      13: null,
    }));
    expect(memory.workSource, isNull);
    expect(workspace.projectScopeId, isNull);
    expect(message.isWorkMode, isFalse);
    expect(message.workMemoryEvidence, isNull);
  });

  test('P5 项目身份持久、重绑定轮换、同路径不同群不共享', () async {
    final db = database();
    await db.saveAiProcessingDirPath(root().path);
    final service = WorkModeWorkspaceService(db: db);
    final a =
        await service.loadOrCreate(conversationId: 'a', isDirectChat: false);
    final scope = a.projectScopeId;
    expect(scope, isNotNull);
    expect(
        (await service.loadOrCreate(conversationId: 'a', isDirectChat: false))
            .projectScopeId,
        scope);
    await service.rebindConversationWorkspace(
        conversationId: 'a', isDirectChat: false, grantedPath: root().path);
    expect(db.workModeWorkspaceBox.get('a')!.projectScopeId, isNot(scope));
    await service.rebindConversationWorkspace(
        conversationId: 'b', isDirectChat: false, grantedPath: root().path);
    expect(db.workModeWorkspaceBox.get('a')!.projectScopeId,
        isNot(db.workModeWorkspaceBox.get('b')!.projectScopeId));
    final portable =
        BackupEntityCodec.decodeWorkspace(BackupEntityCodec.workspace(a));
    expect(portable.projectScopeId, isNull);
  });

  test('P5 pinned、明确记忆仍受项目/主体/删除分界约束，普通聊天保留旧行为', () async {
    final db = database();
    final at = DateTime.now();
    for (final entry in {
      'project': ['user'],
      'hidden': ['user', 'secret']
    }.entries) {
      await db.permanentMemoryBox.put(
          entry.key,
          PermanentMemory(
            id: entry.key,
            observerCharacterId: 'dev',
            kind: MemoryKind.fact,
            content: '读取规则_${entry.key}',
            subjectIds: entry.value,
            status: MemoryStatus.active,
            pinned: true,
            explicitlyRequested: true,
            originType: MemoryOriginType.group,
            originConversationId: 'group',
            originNameSnapshot: 'A',
            occurredAt: at,
            workSource: const {'scopeId': 'A', 'type': 'projectInstruction'},
          ));
    }
    await db.permanentMemoryBox.put(
        'legacy',
        PermanentMemory(
          observerCharacterId: 'dev',
          kind: MemoryKind.fact,
          content: '旧项目读取规则',
          subjectIds: const ['user'],
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: '旧项目',
        ));
    final selector = MemoryContextSelector(db);
    Future<String> select(String scope, {DateTime? boundary}) =>
        selector.select(
          observerCharacterId: 'dev',
          participantCharacterIds: ['dev'],
          userMessage: '读取规则',
          forWork: true,
          projectScopeId: scope,
          conversationId: 'group',
          contextBoundary: boundary,
        );
    expect(await select('A'), contains('读取规则_project'));
    expect(await select('A'), isNot(contains('hidden')));
    expect(await select('B'), isEmpty);
    expect(await select('A', boundary: at), isEmpty);
    expect(
        await selector.select(
            observerCharacterId: 'dev', participantCharacterIds: ['dev']),
        contains('旧项目读取规则'));
    expect(
        await selector.select(
            observerCharacterId: 'dev', participantCharacterIds: ['dev']),
        isNot(contains('读取规则_project')));
  });

  test('P5 旧观察器工作猜想不提炼，明确项目记忆不变为全局，稳定偏好有明确范围', () async {
    final db = database();
    final entry = ObservationEntry(db: db);
    for (final text in [
      '我认为代码支持无限次重试',
      '记住本项目读取规则：允许无限次重试',
      '记住所有项目的稳定偏好：我喜欢简短读取报告',
      '记住所有项目的稳定偏好：我喜欢本项目已验证无限次重试'
    ]) {
      final message = Message(
          groupId: 'g',
          senderId: 'user',
          senderType: 'user',
          content: text,
          isWorkMode: true,
          visibleToCharacterIds: ['dev']);
      await db.messageBox.put(message.id, message);
      await entry.observeMessage(
          message: message,
          visibleCharacterIds: ['dev'],
          conversationId: 'g',
          conversationNameSnapshot: 'G',
          allCharacters: [],
          isGroupChat: true);
    }
    final invented = Message(
        groupId: 'g',
        senderId: 'dev',
        senderType: 'ai',
        content: '我曾验证本项目可以无限次重试',
        isWorkMode: true,
        visibleToCharacterIds: ['dev']);
    await db.messageBox.put(invented.id, invented);
    await entry.recordWorkExperience(invented);
    expect(db.permanentMemoryBox.length, 3);
    expect(entry.loadRetryQueue(), isEmpty);
    final result = await MemoryContextSelector(db).select(
        observerCharacterId: 'dev',
        participantCharacterIds: ['dev'],
        userMessage: '简短读取报告',
        forWork: true,
        projectScopeId: 'B',
        conversationId: 'b');
    expect(result, contains('稳定偏好'));
    expect(result, isNot(contains('无限次重试')));
  });

  test('P5 经验写失败保留重试、重建去重、纠正和遗忘保留来源，删除不复活', () async {
    final db = database();
    final task = AgentTask(
        id: 't',
        groupId: 'g',
        characterId: 'dev',
        userRequest: '读取源码',
        workModeTask: true);
    await db.agentTaskBox.put(task.id, task);
    final message = Message(
        id: 'source',
        groupId: 'g',
        senderId: 'dev',
        senderType: 'ai',
        content: '真实读取成功；猜想不入永久事实。',
        isWorkMode: true,
        visibleToCharacterIds: [
          'dev',
          'qa'
        ],
        workMemoryEvidence: {
          'taskId': 't',
          'scopeId': 'A',
          'evidenceRef': 'investigation:receipt',
          'tool': 'workspace.read',
          'issueId': 'i',
          'requestRevision': 1,
        });
    await db.messageBox.put(message.id, message);
    await MemoryControls(db).setAutomaticMemoryEnabled(false);
    await ObservationEntry(db: db).recordWorkExperience(message);
    expect(ObservationEntry(db: db).loadRetryQueue(), isEmpty);
    expect(db.permanentMemoryBox, isEmpty);
    await MemoryControls(db).setAutomaticMemoryEnabled(true);
    final box = _FailingMemoryBox(db.permanentMemoryBox);
    final failingDb = _WorkMemoryDatabase(box);
    await ObservationEntry(db: failingDb).recordWorkExperience(message);
    expect(db.permanentMemoryBox, isEmpty);
    expect(ObservationEntry(db: db).loadRetryQueue(), hasLength(1));
    await Hive.close();
    await reopenLifecycleHive(root());
    // New service instances read the same pending input from disk.
    expect(await ObservationEntry(db: db).processRetryQueue(), 1);
    await ObservationEntry(db: db).recordWorkExperience(message);
    expect(db.permanentMemoryBox.length, 1);
    final memory = db.permanentMemoryBox.values.single;
    expect(memory.observerCharacterId, 'dev');
    expect(memory.participantIds, ['dev']);
    final selector = MemoryContextSelector(db);
    final b = await selector.select(
        observerCharacterId: 'dev',
        participantCharacterIds: ['dev', 'qa'],
        userMessage: '读取源码',
        forWork: true,
        projectScopeId: 'B',
        conversationId: 'b');
    expect(b, contains('不是本项目已验证事实'));
    expect(b, contains('investigation:receipt'));
    expect(
        await selector.select(
            observerCharacterId: 'qa',
            participantCharacterIds: ['qa'],
            userMessage: '读取源码',
            forWork: true),
        isEmpty);
    final restored = BackupEntityCodec.decodePermanentMemory(
        BackupEntityCodec.permanentMemory(memory));
    expect(restored.workSource, memory.workSource);
    final controls = MemoryControls(db);
    final corrected = await controls.editPermanent(memory,
        correctedContent: '读取方法只适用于当前授权材料', subjectIds: []);
    expect(corrected.workSource!['scopeId'], 'A');
    expect(corrected.sourceMessageIds, ['source']);
    expect(
        await selector.select(
            observerCharacterId: 'dev',
            participantCharacterIds: ['dev'],
            userMessage: '读取源码',
            forWork: true,
            projectScopeId: 'B'),
        isEmpty);
    await controls.deletePermanent(corrected);
    await ObservationEntry(db: db).recordWorkExperience(message);
    expect(
        db.permanentMemoryBox.values
            .where((m) => m.status == MemoryStatus.active),
        isEmpty);
    expect(BackupEntityCodec.message(message, [])['isWorkMode'], true);
    expect(
        BackupEntityCodec.message(message, [])
            .containsKey('workMemoryEvidence'),
        isFalse);
  });

  test('P5 当前 actor 不污染共享历史，预算不足不挤掉证据', () async {
    final db = database();
    final history = <Map<String, dynamic>>[
      {'role': 'system', 'content': '验收和证据'}
    ];
    final actor = AICharacter(
        id: 'dev',
        name: '开发',
        avatar: 'D',
        age: 30,
        role: '开发工程师',
        personalityTags: ['直接'],
        systemPrompt: '关注实现',
        apiKey: '',
        apiProvider: 'deepseek');
    final result = await runWithUnifiedMemory<List<Map<String, dynamic>>>(
        selector: MemoryContextSelector(db),
        conversationHistory: history,
        observerCharacterId: 'dev',
        participantCharacterIds: ['dev'],
        userMessage: '读取源码',
        actor: actor,
        maximumPromptTokens: 1,
        run: (prepared) async => prepared);
    expect(result, history);
    expect(history, hasLength(1));
    final characterLimited =
        await runWithUnifiedMemory<List<Map<String, dynamic>>>(
            selector: MemoryContextSelector(db),
            conversationHistory: history,
            observerCharacterId: 'dev',
            participantCharacterIds: ['dev'],
            userMessage: '读取源码',
            actor: actor,
            maximumPromptCharacters: 8,
            run: (prepared) async => prepared);
    expect(characterLimited, history);

    await expectLater(
        runWithUnifiedMemory<void>(
            selector: MemoryContextSelector(db),
            conversationHistory: history,
            observerCharacterId: 'qa',
            participantCharacterIds: ['qa'],
            userMessage: '源码',
            actor: actor,
            run: (_) async {}),
        throwsStateError);
  });
}

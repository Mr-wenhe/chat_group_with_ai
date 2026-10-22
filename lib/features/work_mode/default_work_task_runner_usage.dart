part of 'default_work_task_runner.dart';

const MethodChannel _browserTestChannel =
    MethodChannel('com.chatgroup/browser_test');

class _ProductionUsage {
  final WorkCandidatePublisher publisher;
  final WorkCandidate candidate;
  final WorkCollaborationState state;
  final String actorId;
  final List<WorkUsageObservation> observations = [];
  int documentRequestSequence = 0;
  int browserOperationSequence = 0;
  Map<String, dynamic>? feedback;
  _ProductionUsage(this.publisher, this.candidate, this.state, this.actorId);
}

class _MacWebKitTestSession {
  final String actorId;
  final String scenarioId;
  final String iterationId;
  final String artifactDigest;
  final String planDigest;
  final Map<String, String> queryParameters;
  final String sessionRef;
  int successfulClicks = 0;
  int clicksAtLastAssertion = 0;
  int successfulResizes = 0;
  int resizesAtLastAssertion = 0;
  String? lastObservationRef;
  bool uncertain = false;

  _MacWebKitTestSession({
    required this.actorId,
    required this.scenarioId,
    required this.iterationId,
    required this.artifactDigest,
    required this.planDigest,
    required Map<String, String> queryParameters,
    required this.sessionRef,
  }) : queryParameters = Map.unmodifiable(queryParameters);
}

extension _DefaultWorkTaskRunnerUsage on DefaultWorkTaskRunner {
  Future<bool> _prepareUsageActor(
      AgentTask task, WorkCollaborationState state) async {
    if (!state.isAutonomous ||
        !state.usagePlanReady ||
        state.hasOpenIssue ||
        state.acceptances.any((a) => a['status'] == 'failed')) {
      return false;
    }
    final receipts = WorkUsageReceiptStore(eventStore);
    String? missing;
    for (final member in state.participantIds) {
      if (!await receipts.valid(state, member)) {
        missing = member;
        break;
      }
    }
    if (missing == null) return false;
    final member = missing;
    task.characterId = member;
    if (!await _productionActorAvailable(task, persist: false)) return false;
    if (state.currentUsageFor(member) != null) {
      await _productionCommit(
          task,
          'usage',
          {
            'usageEvidenceRefs': [
              for (final e in state.usageEvidenceRefs)
                e['memberId'] == member ? {...e, 'status': 'blocked'} : e
            ]
          },
          persist: false);
    }
    final assignment =
        state.usageAssignments.singleWhere((a) => a['memberId'] == member);
    _bindWorkItem(task, 'usage', assignment['scenarioId'] as String);
    return true;
  }

  Future<_ProductionUsage?> _prepareProductionUsage(AgentTask task) async {
    final binding =
        _decodeMap(task.executionStateJson)['workItemExecution'] as Map?;
    if (!const {'usage', 'verify'}.contains(binding?['stage'])) return null;
    final isReview = binding?['stage'] == 'verify';
    final state = _candidateState(task);
    if (isReview &&
        (state.artifactContract['type'] != 'software' ||
            !state.usagePlanReady ||
            !state.usageAssignments.any((a) =>
                a['memberId'] == task.characterId &&
                (a['requiredCapabilities'] as List)
                    .contains('browser.context')))) {
      return null;
    }
    if (!state.isAutonomous ||
        !state.usagePlanReady ||
        !state.planReady ||
        binding?['actorId'] != task.characterId ||
        binding?['iterationId'] != state.currentIteration?['id']) {
      throw StateError('试用角色、使用计划或候选失效。');
    }
    final publisher = await candidatePublisher(task);
    final candidate = (await publisher.recover())
        .singleWhere((c) => c.iterationId == state.currentIteration!['id']);
    await publisher.verify(candidate, expectedDigest: candidate.digest);
    final usage =
        _ProductionUsage(publisher, candidate, state, task.characterId);
    final ref = _decodeMap(task.executionStateJson)['v2UsageObservationRef'];
    if (ref is String) {
      final text = await eventStore.readDiscussionDetail(task.id, ref);
      final hash = sha256.convert(utf8.encode(text)).toString();
      final record = jsonDecode(text) as Map;
      if (hash.substring(0, 24) != ref ||
          !await eventStore.hasCommittedAction(
              task.id, 'usage-observations:$hash') ||
          record['actorId'] != task.characterId ||
          record['taskId'] != task.id ||
          record['conversationId'] != task.groupId ||
          record['iterationId'] != candidate.iterationId ||
          record['artifactDigest'] != candidate.digest ||
          record['planDigest'] != state.usagePlanDigest ||
          record['verificationRevision'] != state.verificationRevision) {
        throw StateError('试用现场证据不属于当前成员、计划或候选；未重放动作。');
      }
      for (final item in record['observations'] as List) {
        final observation = WorkUsageObservation.tryParse(item);
        if (observation == null ||
            !observation.matches(state, task.characterId)) {
          throw StateError('试用观察损坏；未重放动作。');
        }
        if (observation.runtime == 'macos-native' &&
            await eventStore.hasCommittedAction(
              task.id,
              'native-session-invalidated:${observation.sessionRef}',
            )) {
          continue;
        }
        usage.observations.add(observation);
      }
    }
    return usage;
  }

  Future<void> _recordUsageObservation(AgentTask task, _ProductionUsage usage,
      WorkUsageObservation observation) async {
    if (!observation.matches(usage.state, usage.actorId) ||
        _candidateState(task).usagePlanDigest != usage.state.usagePlanDigest ||
        task.characterId != usage.actorId) {
      throw StateError('当前试用观察归属无效。');
    }
    if (observation.operation == 'bundle-integrity-failed') {
      usage.observations.removeWhere((item) => item.runtime == 'macos-native');
    }
    usage.observations.add(observation);
    final body = jsonEncode({
      'taskId': task.id,
      'conversationId': task.groupId,
      'actorId': usage.actorId,
      'iterationId': usage.candidate.iterationId,
      'artifactDigest': usage.candidate.digest,
      'planDigest': usage.state.usagePlanDigest,
      'verificationRevision': usage.state.verificationRevision,
      'observations': usage.observations.map((o) => o.toJson()).toList(),
    });
    final hash = sha256.convert(utf8.encode(body)).toString();
    await eventStore.writeDiscussionDetail(
        task.id, hash.substring(0, 24), body);
    await eventStore.recordCommittedAction(task.id, 'usage-observations:$hash');
    final root = _decodeMap(task.executionStateJson)
      ..['v2UsageObservationRef'] = hash.substring(0, 24);
    task.executionStateJson = jsonEncode(root);
  }

  Future<void> _recordDocumentModelUse(
    AgentTask task,
    _ProductionUsage usage,
    WorkAgentModelRequest request,
    List<Map<String, dynamic>> sentMessages,
  ) async {
    if (task.characterId != usage.actorId ||
        request.task.characterId != usage.actorId ||
        _candidateState(task).currentIteration?['artifactDigest'] !=
            usage.candidate.digest) {
      return;
    }
    final rawResults = request.context['recentToolResults'];
    if (rawResults is! List) return;
    for (final raw in rawResults) {
      if (raw is! Map ||
          raw['tool'] != AgentToolName.workspaceDocument.wireName ||
          raw['status'] != WorkToolResultStatus.success.name ||
          raw['data'] is! Map) {
        continue;
      }
      final data = Map<String, dynamic>.from(raw['data'] as Map);
      final fileName = data['fileName'];
      final documentDigest = data['documentDigest'];
      if (fileName is! String ||
          !RegExp(r'^[a-f0-9]{64}$')
              .hasMatch(documentDigest is String ? documentDigest : '')) {
        continue;
      }
      final sourcePath = data['path'];
      if (sourcePath is! String) continue;
      final candidateFile = usage.candidate.files.where((file) {
        final path = file['path'] as String;
        return file['sha256'] == documentDigest &&
            p.equals(
              p.normalize(File(sourcePath).absolute.path),
              p.normalize(usage.candidate.file(path).absolute.path),
            );
      }).firstOrNull;
      if (candidateFile == null) continue;
      final documentPath = candidateFile['path'] as String;
      final isVisual = data['pageNumber'] is int;
      final content = data['content'];
      final outputRefs = <String>[];
      final sourceLocations = <Map<String, dynamic>>[];
      var beforeRef = documentDigest;
      late final String afterRef;
      late final String operation;
      List<int> pages = const [];
      int? pageCount;
      int? chunkCount;
      List<int> chunks = const [];
      String? fontCoverageStatus;
      if (isVisual) {
        if (content is! List ||
            data['imageRef'] is! String ||
            data['manifestRef'] is! String) {
          continue;
        }
        final imagePart = content
            .whereType<Map>()
            .where((part) =>
                part['type'] == 'image_url' && part['image_url'] is Map)
            .firstOrNull;
        final url = imagePart?['image_url'] is Map
            ? (imagePart!['image_url'] as Map)['url']
            : null;
        if (url is! String ||
            !url.startsWith('data:image/png;base64,') ||
            !_containsSentText(sentMessages, url)) {
          continue;
        }
        final manifest = data['manifest'];
        if (manifest is! Map ||
            manifest['documentSha256'] != documentDigest ||
            manifest['documentPath'] != sourcePath ||
            manifest['pageNumber'] != data['pageNumber'] ||
            manifest['pageCount'] != data['pageCount']) {
          continue;
        }
        final textPart = content
            .whereType<Map>()
            .where((part) => part['type'] == 'text')
            .map((part) => part['text'])
            .whereType<String>()
            .firstOrNull;
        if (textPart == null || !_containsSentText(sentMessages, textPart)) {
          continue;
        }
        operation = 'visual-read';
        pages = [data['pageNumber'] as int];
        pageCount = data['pageCount'] as int?;
        afterRef = data['imageSha256'] is String
            ? data['imageSha256'] as String
            : sha256.convert(url.codeUnits).toString();
        outputRefs.add(data['imageRef'] as String);
        outputRefs.add(data['manifestRef'] as String);
        final coverage = manifest['fontCoverage'];
        fontCoverageStatus =
            coverage is Map ? coverage['status'] as String? : null;
        sourceLocations.add({'fileName': fileName, 'page': pages.single});
      } else {
        if (content is! String ||
            content.isEmpty ||
            !_containsSentText(sentMessages, content)) {
          continue;
        }
        final rawChunks = data['chunkIndexes'];
        final rawSources = data['sources'];
        if (rawChunks is! List ||
            rawChunks.isEmpty ||
            rawChunks.any((item) => item is! int) ||
            rawSources is! List ||
            rawSources.isEmpty ||
            rawSources.any((item) => item is! Map)) {
          continue;
        }
        operation = 'body-read';
        chunks = rawChunks.cast<int>();
        chunkCount = data['totalChunkCount'] as int?;
        sourceLocations.addAll(
            rawSources.map((item) => Map<String, dynamic>.from(item as Map)));
        afterRef = sha256.convert(utf8.encode(content)).toString();
        final manifestBytes = utf8.encode(jsonEncode({
          'schemaVersion': 1,
          'taskId': task.id,
          'actorId': usage.actorId,
          'artifactDigest': usage.candidate.digest,
          'documentDigest': documentDigest,
          'documentPath': documentPath,
          'fileName': fileName,
          'operation': operation,
          'chunkIndexes': chunks,
          'chunkCount': chunkCount,
          'sourceLocations': sourceLocations,
          'receivedTextSha256': afterRef,
        }));
        outputRefs.add(await eventStore.writeDocumentEvidence(
            task.id, 'json', manifestBytes));
      }
      final observation = WorkUsageObservation(
        taskId: task.id,
        conversationId: task.groupId,
        actorId: usage.actorId,
        scenarioId: usage.state.usageAssignments.singleWhere((assignment) =>
            assignment['memberId'] == usage.actorId)['scenarioId'] as String,
        iterationId: usage.candidate.iterationId,
        artifactDigest: usage.candidate.digest,
        planDigest: usage.state.usagePlanDigest,
        verificationRevision: usage.state.verificationRevision,
        runtime: 'document',
        sessionRef:
            'document:${task.id}:${usage.actorId}:${++usage.documentRequestSequence}',
        operation: operation,
        beforeRef: beforeRef,
        afterRef: afterRef,
        outputRefs: outputRefs,
        documentFileName: fileName,
        documentPath: documentPath,
        documentDigest: documentDigest,
        pageNumbers: pages,
        pageCount: pageCount,
        chunkIndexes: chunks,
        chunkCount: chunkCount,
        sourceLocations: sourceLocations,
        fontCoverageStatus: fontCoverageStatus,
      );
      final duplicate = usage.observations
          .any((existing) => existing.duplicatesDocumentUse(observation));
      if (duplicate) continue;
      if (observation.valid &&
          observation.matches(usage.state, usage.actorId)) {
        await _recordUsageObservation(task, usage, observation);
      }
    }
  }

  bool _containsSentText(Object? value, String target, {int depth = 0}) {
    if (value is String) {
      if (value.contains(target)) return true;
      if (depth >= 4) return false;
      try {
        return _containsSentText(jsonDecode(value), target, depth: depth + 1);
      } on Object {
        return false;
      }
    }
    if (value is List) {
      return value.any((item) => _containsSentText(item, target, depth: depth));
    }
    if (value is Map) {
      return value.values
          .any((item) => _containsSentText(item, target, depth: depth));
    }
    return false;
  }

  WorkToolRegistry _usageRegistry(
    WorkToolRegistry registry,
    _ProductionUsage usage,
    AgentTask task,
    AICharacter character,
  ) =>
      WorkToolRegistry(
        mutationPipeline: registry.mutationPipeline,
        definitions: [
          for (final definition in registry.definitions)
            WorkToolDefinition(
              name: definition.name,
              access: definition.access,
              schema: definition.schema,
              mutationPipeline: definition.mutationPipeline,
              handler: (invocation) async {
                if (definition.isMutation &&
                    definition.name != AgentToolName.commandRun &&
                    definition.name != AgentToolName.nativeApp &&
                    definition.name != AgentToolName.browserContext) {
                  return const WorkToolResult.permissionDenied(
                      message: '试用阶段不能修改冻结候选、断言或角色技能。');
                }
                var effectiveInvocation = invocation;
                if (definition.name == AgentToolName.workspaceDocument) {
                  final assignment = usage.state.usageAssignments
                      .singleWhere((a) => a['memberId'] == usage.actorId);
                  final capabilities =
                      (assignment['requiredCapabilities'] as List)
                          .cast<String>();
                  final operation = invocation.arguments['operation'] ?? 'read';
                  final requiredCapability = operation == 'render'
                      ? 'document.visual'
                      : 'document.body';
                  if (!capabilities.contains(requiredCapability)) {
                    return const WorkToolResult.permissionDenied(
                        message: '当前使用场景没有分配此文档检查能力。');
                  }
                  final rawPath = invocation.arguments['path'];
                  final entry = rawPath is! String
                      ? null
                      : usage.candidate.files.where((file) {
                          final relative = file['path'] as String;
                          final candidatePath =
                              usage.candidate.file(relative).absolute.path;
                          return rawPath == relative ||
                              p.equals(p.normalize(File(rawPath).absolute.path),
                                  p.normalize(candidatePath));
                        }).firstOrNull;
                  if (entry == null ||
                      !const {'docx', 'pdf'}.contains(p
                          .extension(entry['path'] as String)
                          .toLowerCase()
                          .replaceFirst('.', ''))) {
                    return const WorkToolResult.permissionDenied(
                        message: '文档使用只能读取本轮冻结候选中的 DOCX 或 PDF。');
                  }
                  final candidatePath = usage.candidate
                      .file(entry['path'] as String)
                      .absolute
                      .path;
                  effectiveInvocation = WorkToolInvocation(
                    task: invocation.task,
                    call: AgentToolCall(
                      name: invocation.name,
                      arguments: {
                        ...invocation.arguments,
                        'path': candidatePath,
                      },
                    ),
                    context: invocation.context,
                  );
                }
                final closesStoredBrowserSession =
                    definition.name == AgentToolName.browserContext &&
                        invocation.arguments['operation'] == 'close' &&
                        _browserTestSessions[task.id]?.sessionRef ==
                            invocation.arguments['sessionRef'];
                if (!closesStoredBrowserSession) {
                  await usage.publisher.verify(usage.candidate,
                      expectedDigest: usage.candidate.digest);
                }
                if (invocation.context.isCancelled) {
                  return const WorkToolResult.paused(
                      message: '试用已暂停或停止，未继续操作。');
                }
                final result = await definition.handler(effectiveInvocation);
                if (!closesStoredBrowserSession) {
                  await usage.publisher.verify(usage.candidate,
                      expectedDigest: usage.candidate.digest);
                }
                return result;
              },
            ),
          if (_canUseBrowserContext(
            task,
            character,
            usage.state.usageAssignments
                .singleWhere((item) => item['memberId'] == usage.actorId),
            usage.candidate,
          ))
            _browserTestDefinition(usage),
          if (nativeAppAutomation != null &&
              Platform.isMacOS &&
              usage.state.artifactContract['nativeBundle'] is Map)
            WorkToolDefinition(
              name: AgentToolName.nativeApp,
              access: WorkToolAccess.mutation,
              schema: const WorkToolSchema(
                fields: {
                  'operation': WorkToolValueType.string,
                  'action': WorkToolValueType.string,
                  'sessionRef': WorkToolValueType.string,
                  'elementId': WorkToolValueType.string,
                  'text': WorkToolValueType.string,
                  'direction': WorkToolValueType.string,
                  'distance': WorkToolValueType.integer,
                  'widthDelta': WorkToolValueType.integer,
                  'heightDelta': WorkToolValueType.integer,
                  'acceptanceId': WorkToolValueType.string,
                  'expectedText': WorkToolValueType.string,
                },
                required: {'operation'},
              ),
              mutationPipeline: WorkToolMutationPipeline(
                policy: (invocation) async {
                  final role = database.aiCharacterBox.get(usage.actorId);
                  if (role == null ||
                      !role.toolPermissions
                          .contains(ToolPermission.nativeApp) ||
                      invocation.task.characterId != usage.actorId ||
                      usage.state.currentIteration?['id'] !=
                          usage.candidate.iterationId ||
                      usage.state.currentIteration?['artifactDigest'] !=
                          usage.candidate.digest ||
                      WorkApprovalFingerprint.mutation(call: invocation.call)
                          .isEmpty) {
                    return const WorkToolResult.permissionDenied(
                        message: '当前成员没有 native.app 权限或候选已变化。',
                        failureCode: 'discussionPhaseDenied');
                  }
                  return null;
                },
                approval: (_) => null,
                snapshot: (_) => null,
                lock: (_) => resourceLockManager == null
                    ? const WorkToolResult.paused(
                        message: 'macOS 桌面资源锁不可用，未操作目标 App。')
                    : null,
              ),
              handler: (invocation) async {
                final actor = database.aiCharacterBox.get(usage.actorId);
                if (actor == null ||
                    !_permissionsForTask(invocation.task, actor)
                        .contains(ToolPermission.nativeApp)) {
                  return const WorkToolResult.permissionDenied(
                      message: '当前成员或任务没有授予 native.app 权限。');
                }
                final assignment = usage.state.usageAssignments
                    .singleWhere((a) => a['memberId'] == usage.actorId);
                final cancellation = invocation.context.cancellation;
                if (cancellation != null) {
                  unawaited(cancellation.whenCancelled.then<void>((_) =>
                      nativeAppAutomation!.cancelTask(usage.state.taskId)));
                }
                await usage.publisher.verify(usage.candidate,
                    expectedDigest: usage.candidate.digest);
                final result = await nativeAppAutomation!.invoke(
                  task: invocation.task,
                  state: usage.state,
                  candidate: usage.candidate,
                  assignment: assignment,
                  call: invocation.call,
                  cancellationSignal: cancellation?.whenCancelled,
                  isCancelled: () => cancellation?.isCancelled == true,
                );
                try {
                  await usage.publisher.verify(usage.candidate,
                      expectedDigest: usage.candidate.digest);
                } on Object {
                  await nativeAppAutomation!.cancelTask(usage.state.taskId);
                  rethrow;
                }
                if (result.failureCode == 'nativeAppCandidateChanged') {
                  usage.observations.removeWhere(
                      (observation) => observation.runtime == 'macos-native');
                }
                return result;
              },
            ),
        ],
      );

  bool _canUseBrowserContext(
    AgentTask task,
    AICharacter character,
    Map<String, dynamic> assignment,
    WorkCandidate candidate,
  ) {
    final collaboration = WorkDiscussionState.fromExecutionState(
      task.executionStateJson,
    )?.collaboration;
    return Platform.isMacOS &&
        WorkTaskExecutionPolicy.isValidatedV2GroupTask(task) &&
        collaboration?.artifactContract['type'] == 'software' &&
        collaboration?.currentIteration?['id'] == candidate.iterationId &&
        collaboration?.currentIteration?['artifactDigest'] ==
            candidate.digest &&
        _browserCandidateEntry(candidate) != null &&
        (assignment['requiredCapabilities'] as List)
            .contains('browser.context') &&
        _permissionsForTask(task, character)
            .contains(ToolPermission.browserContext);
  }

  Map<String, dynamic>? _browserCandidateEntry(WorkCandidate candidate) {
    final html = candidate.files
        .where((file) =>
            p.extension(file['path'] as String).toLowerCase() == '.html')
        .toList(growable: false);
    return html.length == 1 ? html.single : null;
  }

  WorkToolDefinition _browserTestDefinition(_ProductionUsage usage) =>
      WorkToolDefinition(
        name: AgentToolName.browserContext,
        access: WorkToolAccess.mutation,
        schema: const WorkToolSchema(
          fields: {
            'operation': WorkToolValueType.string,
            'sessionRef': WorkToolValueType.string,
            'label': WorkToolValueType.string,
            'acceptanceId': WorkToolValueType.string,
            'expectedText': WorkToolValueType.string,
            'queryParameters': WorkToolValueType.object,
            'width': WorkToolValueType.integer,
            'height': WorkToolValueType.integer,
          },
          required: {'operation'},
        ),
        mutationPipeline: WorkToolMutationPipeline(
          policy: (invocation) async {
            final actor = database.aiCharacterBox.get(usage.actorId);
            final assignment = usage.state.usageAssignments
                .singleWhere((item) => item['memberId'] == usage.actorId);
            final current = _candidateState(invocation.task);
            final cleanupOnly = invocation.arguments['operation'] == 'close' &&
                _browserTestSessions[invocation.task.id]?.sessionRef ==
                    invocation.arguments['sessionRef'];
            if (actor == null ||
                !_permissionsForTask(invocation.task, actor)
                    .contains(ToolPermission.browserContext) ||
                !(assignment['requiredCapabilities'] as List)
                    .contains('browser.context') ||
                (!cleanupOnly &&
                    (invocation.task.characterId != usage.actorId ||
                        !WorkTaskExecutionPolicy.isValidatedV2GroupTask(
                            invocation.task) ||
                        current.artifactContract['type'] != 'software' ||
                        current.usagePlanDigest !=
                            usage.state.usagePlanDigest ||
                        current.currentIteration?['id'] !=
                            usage.candidate.iterationId ||
                        current.currentIteration?['artifactDigest'] !=
                            usage.candidate.digest)) ||
                WorkApprovalFingerprint.mutation(call: invocation.call)
                    .isEmpty) {
              return const WorkToolResult.permissionDenied(
                  message: '当前成员未获浏览器测试权限，或候选/场景已变化。',
                  failureCode: 'discussionPhaseDenied');
            }
            return null;
          },
          approval: (_) => null,
          snapshot: (invocation) async {
            final closesStoredBrowserSession =
                invocation.arguments['operation'] == 'close' &&
                    _browserTestSessions[invocation.task.id]?.sessionRef ==
                        invocation.arguments['sessionRef'];
            if (!closesStoredBrowserSession) {
              await usage.publisher.verify(usage.candidate,
                  expectedDigest: usage.candidate.digest);
            }
            return null;
          },
          lock: (_) => null,
        ),
        handler: (invocation) => _runBrowserTestTool(usage, invocation),
      );

  Future<Map<String, dynamic>?> _invokeBrowserTestMap(
    Map<String, Object?> arguments, {
    Duration timeout = const Duration(seconds: 12),
  }) =>
      _browserTestChannel
          .invokeMapMethod<String, dynamic>('run', arguments)
          .timeout(timeout);

  Future<WorkToolResult> _runBrowserTestTool(
      _ProductionUsage usage, WorkToolInvocation invocation) async {
    final task = invocation.task;
    final assignment = usage.state.usageAssignments
        .singleWhere((item) => item['memberId'] == usage.actorId);
    final operation = invocation.arguments['operation'] as String;
    if (operation == 'open') {
      final rawQueryParameters = invocation.arguments['queryParameters'];
      if (rawQueryParameters is Map &&
          rawQueryParameters.entries
              .any((entry) => entry.key is! String || entry.value is! String)) {
        return const WorkToolResult.permissionDenied(message: '测试参数必须是字符串键值。');
      }
      final queryParameters = rawQueryParameters is Map
          ? Map<String, String>.from(rawQueryParameters)
          : const <String, String>{};
      final existing = _browserTestSessions[task.id];
      if (existing != null) {
        if (existing.actorId == usage.actorId &&
            existing.scenarioId == assignment['scenarioId'] &&
            existing.iterationId == usage.candidate.iterationId &&
            existing.artifactDigest == usage.candidate.digest &&
            existing.planDigest == usage.state.usagePlanDigest &&
            existing.queryParameters.length == queryParameters.length &&
            existing.queryParameters.entries
                .every((entry) => queryParameters[entry.key] == entry.value)) {
          if (existing.uncertain || existing.lastObservationRef == null) {
            return WorkToolResult.failed(
                message: '上次打开未确认成功；请先 close 核实清理，再重新 open，不能把空会话当作已打开。',
                failureCode: 'browserSessionUncertain',
                data: {'sessionRef': existing.sessionRef});
          }
          return WorkToolResult.alreadyCommitted(
              message: '当前成员的候选浏览器会话已打开；未重复创建。',
              data: {'sessionRef': existing.sessionRef});
        }
        return WorkToolResult.failed(
            message:
                '上一个隔离浏览器会话仍占用本任务；请先用返回的 sessionRef 调用 close，收到关闭成功后再 open。',
            failureCode: 'browserSessionOccupied',
            data: {'sessionRef': existing.sessionRef});
      }
      final entry = _browserCandidateEntry(usage.candidate);
      if (entry == null) {
        return const WorkToolResult.permissionDenied(
            message: '当前冻结候选必须且只能包含一个 HTML 文件。');
      }
      final sessionRef = 'browser:${sha256.convert(utf8.encode(
            '${task.id}:${usage.actorId}:${usage.candidate.iterationId}:${++usage.browserOperationSequence}',
          )).toString().substring(0, 24)}';
      final session = _MacWebKitTestSession(
        actorId: usage.actorId,
        scenarioId: assignment['scenarioId'] as String,
        iterationId: usage.candidate.iterationId,
        artifactDigest: usage.candidate.digest,
        planDigest: usage.state.usagePlanDigest,
        queryParameters: queryParameters,
        sessionRef: sessionRef,
      );
      _browserTestSessions[task.id] = session;
      try {
        final response = await _invokeBrowserTestMap(
          {
            'operation': 'open',
            'sessionRef': sessionRef,
            'filePath':
                usage.candidate.file(entry['path'] as String).absolute.path,
            'rootPath': usage.candidate.directory.absolute.path,
            'queryParameters': queryParameters,
          },
          timeout: const Duration(seconds: 25),
        );
        final snapshot = response?['snapshot'];
        if (snapshot is! Map) throw StateError('浏览器未返回当前候选页面。');
        final snapshotData = Map<String, dynamic>.from(snapshot);
        final evidence = await _storeBrowserStep(
          task,
          usage,
          session,
          operation: 'open',
          snapshot: snapshotData,
        );
        await usage.publisher
            .verify(usage.candidate, expectedDigest: usage.candidate.digest);
        session.lastObservationRef = evidence['afterRef'] as String;
        final cancellation = invocation.context.cancellation;
        if (cancellation != null) {
          unawaited(cancellation.whenCancelled.then<void>((_) async {
            try {
              await _browserTestChannel.invokeMethod<void>('run', {
                'operation': 'close',
                'sessionRef': sessionRef,
              }).timeout(const Duration(seconds: 10));
              if (_browserTestSessions[task.id]?.sessionRef == sessionRef) {
                _browserTestSessions.remove(task.id);
              }
            } on Object {
              if (_browserTestSessions[task.id]?.sessionRef == sessionRef) {
                _browserTestSessions[task.id]?.uncertain = true;
              }
            }
          }));
        }
        return WorkToolResult.success(
          message: '已在隔离 WebKit 中打开当前冻结 HTML 候选，未允许网络请求。',
          data: {
            'operation': 'open',
            'browserEngine': 'WKWebView',
            'candidateDigest': usage.candidate.digest,
            'iterationId': usage.candidate.iterationId,
            'queryParameters': session.queryParameters,
            'sessionRef': sessionRef,
            'evidenceRefs': evidence['outputRefs'],
            ..._browserModelSnapshot(task, snapshotData, usage.actorId),
          },
        );
      } on Object catch (error) {
        session.uncertain = true;
        try {
          await _browserTestChannel.invokeMethod<void>('run', {
            'operation': 'close',
            'sessionRef': sessionRef,
          }).timeout(const Duration(seconds: 10));
          if (_browserTestSessions[task.id]?.sessionRef == sessionRef) {
            _browserTestSessions.remove(task.id);
          }
        } on Object {
          // Keep the uncertain session until close can confirm cleanup.
        }
        return WorkToolResult.failed(
          message: '隔离浏览器未能打开当前候选：${sanitizeWorkTaskError(error)}',
          failureCode: 'browserOpenFailed',
          data: {'sessionRef': sessionRef},
        );
      }
    }

    final session = _browserTestSessions[task.id];
    final closing = operation == 'close';
    if (session == null ||
        invocation.arguments['sessionRef'] != session.sessionRef ||
        (!closing &&
            (session.actorId != usage.actorId ||
                session.scenarioId != assignment['scenarioId'] ||
                session.iterationId != usage.candidate.iterationId ||
                session.artifactDigest != usage.candidate.digest ||
                session.planDigest != usage.state.usagePlanDigest))) {
      return const WorkToolResult.permissionDenied(
          message: '浏览器会话不属于当前成员、场景或冻结候选。',
          failureCode: 'discussionPhaseDenied');
    }
    if (operation == 'close') {
      if (!session.uncertain &&
          session.actorId == usage.actorId &&
          (session.successfulClicks > session.clicksAtLastAssertion ||
              session.successfulResizes > session.resizesAtLastAssertion)) {
        return WorkToolResult.failed(
          message: '仍有浏览器操作尚未断言；会话保持打开，请先用当前场景的验收项断言页面结果。',
          failureCode: 'browserCloseBeforeAssertion',
          data: {
            'sessionRef': session.sessionRef,
            'unassertedClicks':
                session.successfulClicks - session.clicksAtLastAssertion,
            'unassertedResizes':
                session.successfulResizes - session.resizesAtLastAssertion,
          },
        );
      }
      try {
        await _browserTestChannel.invokeMethod<void>('run', {
          'operation': 'close',
          'sessionRef': session.sessionRef,
        }).timeout(const Duration(seconds: 10));
        _browserTestSessions.remove(task.id);
        return const WorkToolResult.success(message: '隔离浏览器会话已关闭。');
      } on Object catch (error) {
        return WorkToolResult.paused(
            message: '浏览器会话关闭未能核实：${sanitizeWorkTaskError(error)}；当前场景仍被占用。');
      }
    }
    if (session.uncertain && !const {'observe', 'close'}.contains(operation)) {
      return const WorkToolResult.paused(
          message: '上一次浏览器动作结果不确定；请先 observe 核对，未自动重放。',
          failureCode: 'browserActionUncertain');
    }

    String? acceptanceId;
    String? expectedText;
    Map<String, dynamic>? acceptance;
    var hasFreshInteraction = false;
    if (operation == 'assert') {
      acceptanceId = invocation.arguments['acceptanceId'] as String;
      expectedText = invocation.arguments['expectedText'] as String;
      final assignedIds = (assignment['acceptanceIds'] as List).cast<String>();
      acceptance = usage.state.acceptances
          .where((item) => item['id'] == acceptanceId)
          .firstOrNull;
      final agreedText = acceptance == null
          ? ''
          : '${assignment['expectedResult']} ${acceptance['method']}';
      if (acceptance == null ||
          !assignedIds.contains(acceptanceId) ||
          !agreedText.contains(expectedText)) {
        return const WorkToolResult.failed(
            message: '断言必须绑定本人场景中的验收项，且预期文字须来自已确认的 expectedResult。',
            failureCode: 'browserAssertionBinding');
      }
    }

    Map<String, dynamic> actionResult = const {};
    Map<String, dynamic> snapshot = const {};
    try {
      if (operation == 'click') {
        final clicked = await _invokeBrowserTestMap(
          {
            'operation': 'click',
            'sessionRef': session.sessionRef,
            'label': invocation.arguments['label'],
          },
        );
        actionResult = _decodeBrowserResult(clicked);
        if (actionResult['ok'] == true) session.successfulClicks++;
        final observed = await _invokeBrowserTestMap(
          {'operation': 'observe', 'sessionRef': session.sessionRef},
        );
        snapshot = _snapshotFromBrowserResponse(observed);
      } else if (operation == 'assert') {
        hasFreshInteraction =
            session.successfulClicks > session.clicksAtLastAssertion ||
                session.successfulResizes > session.resizesAtLastAssertion;
        final asserted = await _invokeBrowserTestMap(
          {
            'operation': 'assert',
            'sessionRef': session.sessionRef,
            'expectedText': expectedText,
          },
        );
        actionResult = _decodeBrowserResult(asserted);
        session.clicksAtLastAssertion = session.successfulClicks;
        session.resizesAtLastAssertion = session.successfulResizes;
        final observed = await _invokeBrowserTestMap(
          {'operation': 'observe', 'sessionRef': session.sessionRef},
        );
        snapshot = _snapshotFromBrowserResponse(observed);
      } else if (operation == 'resize') {
        final resized = await _invokeBrowserTestMap(
          {
            'operation': 'resize',
            'sessionRef': session.sessionRef,
            'width': invocation.arguments['width'],
            'height': invocation.arguments['height'],
          },
        );
        snapshot = _snapshotFromBrowserResponse(resized);
        if (snapshot.isNotEmpty) session.successfulResizes++;
      } else if (operation == 'observe') {
        final observed = await _invokeBrowserTestMap(
          {'operation': 'observe', 'sessionRef': session.sessionRef},
        );
        snapshot = _snapshotFromBrowserResponse(observed);
      }
    } on Object catch (error) {
      session.uncertain = operation == 'click' || operation == 'resize';
      return WorkToolResult.failed(
        message: session.uncertain
            ? '浏览器动作响应中断，结果不确定；先 observe 核对后再继续。'
            : '浏览器观察失败：${sanitizeWorkTaskError(error)}',
        failureCode: session.uncertain
            ? 'browserActionUncertain'
            : 'browserObservationFailed',
        data: {'sessionRef': session.sessionRef},
      );
    }
    if (operation == 'observe') session.uncertain = false;
    if (operation != 'close') {
      try {
        await usage.publisher
            .verify(usage.candidate, expectedDigest: usage.candidate.digest);
      } on Object catch (error) {
        session.uncertain = true;
        usage.observations
            .removeWhere((item) => item.runtime == 'macos-webkit');
        return WorkToolResult.permissionDenied(
          message:
              '浏览器操作后当前候选摘要已变化或无法核实：${sanitizeWorkTaskError(error)}；先关闭会话。',
          failureCode: 'browserCandidateChanged',
          data: {'sessionRef': session.sessionRef},
        );
      }
    }
    final evidence = await _storeBrowserStep(
      task,
      usage,
      session,
      operation: operation,
      snapshot: snapshot,
      actionResult: actionResult,
      acceptanceId: acceptanceId,
      expectedText: expectedText,
    );
    final afterRef = evidence['afterRef'] as String;
    final beforeRef = session.lastObservationRef ?? usage.candidate.digest;
    session.lastObservationRef = afterRef;
    WorkUsageObservation? observation;
    if (const {'click', 'resize', 'assert'}.contains(operation)) {
      final visualAcceptance = operation == 'assert' &&
          ('${acceptance?['method'] ?? ''} ${acceptance?['requiredCapability'] ?? ''}')
              .contains(RegExp(r'布局|重叠|不遮挡|可读|视觉|尺寸'));
      final canSeeScreenshot = supportsVisionModelForTask(task, usage.actorId);
      final matched = actionResult['matched'] == true;
      final verified = operation == 'assert' &&
          matched &&
          actionResult['textTruncated'] != true &&
          hasFreshInteraction &&
          (!visualAcceptance || canSeeScreenshot);
      observation = WorkUsageObservation(
        taskId: task.id,
        conversationId: usage.state.conversationId,
        actorId: usage.actorId,
        scenarioId: assignment['scenarioId'] as String,
        iterationId: usage.candidate.iterationId,
        artifactDigest: usage.candidate.digest,
        planDigest: usage.state.usagePlanDigest,
        verificationRevision: usage.state.verificationRevision,
        runtime: 'macos-webkit',
        sessionRef: session.sessionRef,
        operation: operation,
        beforeRef: beforeRef,
        afterRef: afterRef,
        outputRefs: (evidence['outputRefs'] as List).cast<String>(),
        verifiedAcceptanceIds:
            verified && acceptanceId != null ? [acceptanceId] : const [],
        businessResultVerified: verified && acceptanceId != null,
      );
      await _recordUsageObservation(task, usage, observation);
    }
    return WorkToolResult.success(
      usageObservation: observation,
      message: operation == 'assert' && actionResult['matched'] != true
          ? '浏览器断言未通过；实际状态和截图已留证，继续检查其他验收项。'
          : '浏览器操作已执行；当前页面、候选摘要及截图已留证。',
      data: {
        'operation': operation,
        'candidateDigest': usage.candidate.digest,
        'iterationId': usage.candidate.iterationId,
        'sessionRef': session.sessionRef,
        'actionResult': actionResult,
        'evidenceRefs': evidence['outputRefs'],
        ..._browserModelSnapshot(task, snapshot, usage.actorId),
      },
    );
  }

  Map<String, dynamic> _snapshotFromBrowserResponse(
      Map<String, dynamic>? response) {
    final snapshot = response?['snapshot'];
    return snapshot is Map
        ? Map<String, dynamic>.from(snapshot)
        : Map<String, dynamic>.from(response ?? const {});
  }

  Map<String, dynamic> _decodeBrowserResult(Map<String, dynamic>? response) {
    final text = response?['result'];
    if (text is! String) return const {};
    try {
      final value = jsonDecode(text);
      return value is Map ? Map<String, dynamic>.from(value) : const {};
    } on FormatException {
      return const {};
    }
  }

  Future<Map<String, Object>> _storeBrowserStep(
    AgentTask task,
    _ProductionUsage usage,
    _MacWebKitTestSession session, {
    required String operation,
    required Map<String, dynamic> snapshot,
    Map<String, dynamic> actionResult = const {},
    String? acceptanceId,
    String? expectedText,
  }) async {
    final page = _decodeBrowserResult(snapshot);
    final content = snapshot['content'];
    final imageUrl = content is List
        ? content
            .whereType<Map>()
            .where((part) => part['type'] == 'image_url')
            .map((part) => part['image_url'])
            .whereType<Map>()
            .map((image) => image['url'])
            .whereType<String>()
            .where((url) => url.startsWith('data:image/png;base64,'))
            .firstOrNull
        : null;
    if (imageUrl is! String) throw StateError('浏览器没有返回当前页面截图。');
    final png =
        base64Decode(imageUrl.substring('data:image/png;base64,'.length));
    if (png.isEmpty ||
        png.length > WorkTaskEventStore.maxNativeScreenshotBytes) {
      throw StateError('浏览器截图为空或超过证据上限。');
    }
    final screenshotRef =
        await eventStore.writeNativeEvidence(task.id, 'png', png);
    final record = {
      'schemaVersion': 1,
      'taskId': task.id,
      'conversationId': task.groupId,
      'actorId': usage.actorId,
      'scenarioId': session.scenarioId,
      'iterationId': usage.candidate.iterationId,
      'artifactDigest': usage.candidate.digest,
      'planDigest': usage.state.usagePlanDigest,
      'verificationRevision': usage.state.verificationRevision,
      'browserEngine': 'WKWebView',
      'sessionRef': session.sessionRef,
      'sequence': ++usage.browserOperationSequence,
      'operation': operation,
      'queryParameters': session.queryParameters,
      'successfulClicks': session.successfulClicks,
      'successfulResizes': session.successfulResizes,
      if (acceptanceId != null) 'acceptanceId': acceptanceId,
      if (expectedText != null) 'expected': expectedText,
      'actual': actionResult['visibleText'] ?? page['visibleText'] ?? '',
      'actionResult': actionResult,
      'page': page,
      'screenshotRef': screenshotRef,
    };
    final text = jsonEncode(record);
    final digest = sha256.convert(utf8.encode(text)).toString();
    await eventStore.writeDiscussionDetail(
        task.id, digest.substring(0, 24), text);
    return {
      'afterRef': digest,
      'outputRefs': ['detail:${digest.substring(0, 24)}', screenshotRef],
    };
  }

  Map<String, Object?> _browserModelSnapshot(
          AgentTask task, Map<String, dynamic> snapshot, String actorId) =>
      {
        if (snapshot['result'] is String)
          'page': _decodeBrowserResult(snapshot),
        if (supportsVisionModelForTask(task, actorId) &&
            snapshot['content'] is List)
          'content': snapshot['content'],
      };

  Future<String?> _validateProductionUsage(AgentTask task,
      _ProductionUsage usage, AgentFinishCompletion completion) async {
    final current = _candidateState(task);
    if (current.usagePlanDigest != usage.state.usagePlanDigest ||
        task.characterId != usage.actorId ||
        current.pendingInputIds.isNotEmpty ||
        task.queuedUserRequests.isNotEmpty) {
      return '当前试用责任已变化或有待处理输入。';
    }
    await usage.publisher
        .verify(usage.candidate, expectedDigest: usage.candidate.digest);
    if (nativeAppAutomation?.hasOpenSession(task.id) == true ||
        nativeAppAutomation?.hasUnverifiedCleanup == true) {
      return 'macOS App 会话尚未核实关闭，不能提交本人反馈或切换试用成员。';
    }
    if (_browserTestSessions.containsKey(task.id)) {
      return '隔离浏览器会话尚未核实关闭，不能提交本人反馈或切换试用成员。';
    }
    final assignment = current.usageAssignments
        .singleWhere((a) => a['memberId'] == usage.actorId);
    final requiredCapabilities =
        (assignment['requiredCapabilities'] as List).cast<String>().toSet();
    final requiresDocumentFeedback = requiredCapabilities.any((capability) =>
        const {'document.body', 'document.visual'}.contains(capability));
    final feedback = parseWorkUsageFeedback(completion,
        acceptanceIds: List<String>.from(assignment['acceptanceIds'] as List),
        requireDocumentEvidence: requiresDocumentFeedback,
        requireDocumentPages: requiredCapabilities.contains('document.visual'));
    if (feedback == null) {
      return requiresDocumentFeedback
          ? 'finish.evidence 需要本人完整文档反馈，包含 documentEvidence.pageNumbers 和 sourceLocations；每个缺陷附本人实际看到的 sourceLocation。'
              '反馈结构错误、位置无效或缺项时不采纳。'
          : 'finish.evidence 需要本人完整反馈 JSON {method,result,acceptanceIds,report,defects}；失败列全复现、预期、实际与复测条件，通过不带缺陷，不接受额外字段或他人报告。';
    }
    if (feedback['result'] != 'blocked' && usage.observations.isEmpty ||
        usage.observations.any((o) => !o.matches(current, usage.actorId))) {
      return '缺少本人当前候选的真实操作及前后观察，不能用报告或命令 JSON 代替。';
    }
    // A blocked member must be able to record a missing renderer, vision model, or page.
    if (requiresDocumentFeedback && feedback['result'] != 'blocked') {
      final documentError = _validateDocumentFeedback(
          usage, assignment, feedback, requiredCapabilities);
      if (documentError != null) return documentError;
    }
    final verified = usage.observations
        .where((o) => o.valid && o.businessResultVerified)
        .expand((o) => o.verifiedAcceptanceIds)
        .toSet();
    if (requiresDocumentFeedback && feedback['result'] == 'passed') {
      verified.addAll(List<String>.from(assignment['acceptanceIds'] as List));
    }
    if (feedback['result'] == 'passed' &&
        !(assignment['acceptanceIds'] as List).every(verified.contains)) {
      return '缺少本人真实操作、操作前后观察或业务核验；命令输出、截图路径和他人报告不能替代使用收据。';
    }
    if (completion.summary.trim().isEmpty || completion.evidence.isEmpty) {
      return '缺少本人实际使用反馈和证据引用。';
    }
    if (requiresDocumentFeedback && feedback['result'] == 'passed') {
      final acceptanceIds =
          List<String>.from(assignment['acceptanceIds'] as List);
      final verifiedDocuments = usage.observations
          .where((observation) => observation.runtime == 'document')
          .map((observation) => WorkUsageObservation(
                taskId: observation.taskId,
                conversationId: observation.conversationId,
                actorId: observation.actorId,
                scenarioId: observation.scenarioId,
                iterationId: observation.iterationId,
                artifactDigest: observation.artifactDigest,
                planDigest: observation.planDigest,
                verificationRevision: observation.verificationRevision,
                runtime: observation.runtime,
                sessionRef: observation.sessionRef,
                operation: observation.operation,
                beforeRef: observation.beforeRef,
                afterRef: observation.afterRef,
                outputRefs: observation.outputRefs,
                verifiedAcceptanceIds: acceptanceIds,
                businessResultVerified: true,
                documentFileName: observation.documentFileName,
                documentPath: observation.documentPath,
                documentDigest: observation.documentDigest,
                pageNumbers: observation.pageNumbers,
                pageCount: observation.pageCount,
                chunkIndexes: observation.chunkIndexes,
                chunkCount: observation.chunkCount,
                sourceLocations: observation.sourceLocations,
                fontCoverageStatus: observation.fontCoverageStatus,
              ))
          .toList(growable: false);
      usage.observations
        ..removeWhere((observation) => observation.runtime == 'document')
        ..addAll(verifiedDocuments);
    }
    usage.feedback = feedback;
    return null;
  }

  String? _validateDocumentFeedback(
    _ProductionUsage usage,
    Map<String, dynamic> assignment,
    Map<String, dynamic> feedback,
    Set<String> capabilities,
  ) {
    if (usage.state.artifactContract['type'] != 'document') {
      return '文档使用能力只能验收冻结的文档候选。';
    }
    final candidates = usage.candidate.files
        .where((file) => const {'docx', 'pdf'}.contains(p
            .extension(file['path'] as String)
            .toLowerCase()
            .replaceFirst('.', '')))
        .map((file) => file['path'] as String)
        .toSet();
    if (candidates.isEmpty) return '冻结候选没有 DOCX 或 PDF 文件。';
    final observations = usage.observations
        .where((observation) => observation.runtime == 'document')
        .toList(growable: false);
    final observedLocations = <String>{};
    final observedPages = <int>{};
    for (final observation in observations) {
      observedLocations
          .addAll(observation.sourceLocations.map(_documentLocationKey));
      observedPages.addAll(observation.pageNumbers);
      observedPages.addAll(observation.sourceLocations
          .map((location) => location['page'])
          .whereType<int>());
    }
    final evidence = feedback['documentEvidence'] as Map;
    final feedbackLocations = (evidence['sourceLocations'] as List).cast<Map>();
    if (feedbackLocations.isEmpty ||
        feedbackLocations.any((location) =>
            !observedLocations.contains(_documentLocationKey(location)))) {
      return '文档反馈没有绑定到本人收到的页码或原文位置。';
    }
    final feedbackPages = (evidence['pageNumbers'] as List).cast<int>().toSet();
    if (!observedPages.containsAll(feedbackPages)) {
      return '文档反馈引用了本人没有实际收到的页码。';
    }
    for (final documentPath in candidates) {
      final candidateFile = usage.candidate.files
          .singleWhere((file) => file['path'] == documentPath);
      final fileName = p.basename(documentPath);
      final fileObservations = observations
          .where((observation) =>
              observation.documentPath == documentPath &&
              observation.documentFileName == fileName &&
              observation.documentDigest == candidateFile['sha256'])
          .toList(growable: false);
      if (fileObservations.isEmpty) return '缺少 $fileName 的本人检查收据。';
      if (capabilities.contains('document.body')) {
        final body = fileObservations
            .where((observation) => observation.operation == 'body-read')
            .toList(growable: false);
        final counts =
            body.map((observation) => observation.chunkCount).toSet();
        if (body.isEmpty || counts.length != 1 || counts.single == null) {
          return '$fileName 正文分块不完整或总块数不一致。';
        }
        final count = counts.single!;
        final chunks =
            body.expand((observation) => observation.chunkIndexes).toSet();
        if (count < 1 ||
            chunks.length != count ||
            !List<int>.generate(count, (index) => index)
                .every(chunks.contains)) {
          return '$fileName 尚未由本人模型完整读取。';
        }
      }
      if (capabilities.contains('document.visual')) {
        final visual = fileObservations
            .where((observation) => observation.operation == 'visual-read')
            .toList(growable: false);
        final counts =
            visual.map((observation) => observation.pageCount).toSet();
        if (visual.isEmpty ||
            counts.length != 1 ||
            counts.single == null ||
            visual.any((observation) =>
                observation.fontCoverageStatus != 'resolved')) {
          return '$fileName 缺少可核验的渲染器、字体覆盖或页数。';
        }
        final count = counts.single!;
        final pages =
            visual.expand((observation) => observation.pageNumbers).toSet();
        if (count < 1 ||
            pages.length != count ||
            !List<int>.generate(count, (index) => index + 1)
                .every(pages.contains) ||
            !feedbackPages.containsAll(pages)) {
          return '$fileName 必要页没有完整渲染并由本人视觉模型收到。';
        }
        for (var page = 1; page <= count; page++) {
          if (!feedbackLocations.any((location) =>
              location['fileName'] == fileName && location['page'] == page)) {
            return '$fileName 第 $page 页缺少绑定到本人观察的来源位置。';
          }
        }
      }
    }
    if (feedback['result'] == 'failed') {
      final feedbackLocationKeys =
          feedbackLocations.map(_documentLocationKey).toSet();
      for (final defect in (feedback['defects'] as List).cast<Map>()) {
        final key = _documentLocationKey(defect['sourceLocation'] as Map);
        if (!observedLocations.contains(key) ||
            !feedbackLocationKeys.contains(key)) {
          return '缺陷位置必须来自当前成员实际收到的原文或页图。';
        }
      }
    }
    return null;
  }

  String _documentLocationKey(Map location) {
    final keys = location.keys.cast<String>().toList()..sort();
    return jsonEncode({for (final key in keys) key: location[key]});
  }

  Future<void> _finishProductionUsage(AgentTask task, _ProductionUsage usage,
      AICharacter member, WorkTaskCancellation cancellation) async {
    if (cancellation.isCancelled || task.queuedUserRequests.isNotEmpty) return;
    final feedback = usage.feedback;
    if (feedback == null) throw StateError('试用缺少本人反馈，不能跳过完成守卫。');
    final message = Message(
        groupId: task.groupId,
        senderId: member.id,
        senderType: Message.senderTypeAi,
        content: task.resultSummary);
    await database.persistMessage(message);
    if (cancellation.isCancelled || task.queuedUserRequests.isNotEmpty) return;
    final result = feedback['result'] as String;
    final store = WorkUsageReceiptStore(eventStore);
    final ref = await store.record(
        state: usage.state,
        actorId: member.id,
        observations: usage.observations,
        feedbackRef: message.id,
        status: result,
        feedback: feedback);
    if (cancellation.isCancelled || task.queuedUserRequests.isNotEmpty) return;
    final state = _candidateState(task);
    final assignment =
        state.usageAssignments.singleWhere((a) => a['memberId'] == member.id);
    await _productionCommit(task, 'usage', {
      'usageEvidenceRefs': [
        for (final e in state.usageEvidenceRefs)
          if (e['memberId'] != member.id) e,
        {
          'taskId': task.id,
          'conversationId': task.groupId,
          'memberId': member.id,
          'scenarioId': assignment['scenarioId'],
          'requestRevision': state.requestRevision,
          'teamRevision': state.teamRevision,
          'verificationRevision': state.verificationRevision,
          'iterationId': usage.candidate.iterationId,
          'artifactDigest': usage.candidate.digest,
          'planDigest': state.usagePlanDigest,
          'receiptRef': ref,
          'feedbackRef': message.id,
          'status': result
        }
      ]
    });
    if (cancellation.isCancelled ||
        task.isTerminal ||
        task.queuedUserRequests.isNotEmpty) {
      return;
    }
    if (result == 'failed') {
      await _recordUsageFailure(task, feedback, ref, member.id);
    } else if (result == 'passed') {
      try {
        await _skillResourcePackStore.recordSuccessfulUse(
          database: database,
          taskId: task.id,
          conversationId: task.groupId,
          characterId: member.id,
        );
      } on Object {
        // Missing local skill receipts cannot convert the usage result or
        // block the task; the remote skill stays unverified.
      }
    }
    if (cancellation.isCancelled ||
        task.isTerminal ||
        task.queuedUserRequests.isNotEmpty) {
      return;
    }
    task
      ..status = result == 'passed' && !_candidateState(task).allMembersUsed
          ? AgentTaskStatus.queued
          : AgentTaskStatus.paused
      ..resumeRequired = result == 'blocked'
      ..lastError = result == 'blocked'
          ? WorkPublicUpdateStream.sanitize(
              '成员 ${member.name} 未完成实际使用：${feedback['report']}')
          : '';
    await _persistCheckpoint(task);
  }

  Future<void> _recordUsageFailure(AgentTask task,
      Map<String, dynamic> feedback, String ref, String actorId) async {
    final current = _candidateState(task);
    final defects = (feedback['defects'] as List).cast<Map>();
    final failedIds = defects.map((d) => d['acceptanceId']).toSet();
    await _productionCommit(task, 'review', {
      'verificationRevision': current.verificationRevision + 1,
      'phase': 'clarifying',
      'acceptances': [
        for (final a in current.acceptances)
          {
            ...a,
            'verificationRevision': current.verificationRevision + 1,
            if (failedIds.contains(a['id'])) 'status': 'failed',
            if (failedIds.contains(a['id'])) 'evidenceRef': ref,
          }
      ],
      'issues': [
        ...current.issues,
        for (final (index, defect) in defects.indexed)
          {
            'id': 'usage-defect-${current.revision}-$index',
            'sourceId': actorId,
            'kind': 'defect',
            'status': 'open',
            'target': defect['acceptanceId'],
            'problem':
                '复现：${defect['reproduction']}；预期：${defect['expected']}；实际：${defect['actual']}',
            'evidenceRef': ref,
            'resolution': '',
            'resolutionRef': '',
            'retestCondition': defect['retestCondition'],
            'requestRevision': current.requestRevision,
          }
      ],
    });
  }
}

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_protocol.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/tool_permission.dart';
import 'package:chat_group/core/streaming/chat_stream_event.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/ai_governance/ai_request_gateway.dart';
import 'package:chat_group/features/document/binary_document_parser.dart';
import 'package:chat_group/features/work_mode/default_work_task_runner.dart';
import 'package:chat_group/features/work_mode/work_command_runner.dart';
import 'package:chat_group/features/work_mode/work_discussion_runner.dart';
import 'package:chat_group/features/work_mode/work_discussion_state.dart';
import 'package:chat_group/features/work_mode/work_collaboration_state.dart';
import 'package:chat_group/features/work_mode/work_folder_grant_service.dart';
import 'package:chat_group/features/work_mode/work_mode_directory_service.dart';
import 'package:chat_group/features/work_mode/work_mode_workspace_service.dart';
import 'package:chat_group/features/work_mode/work_resource_lock_manager.dart';
import 'package:chat_group/features/work_mode/work_role_router.dart';
import 'package:chat_group/features/work_mode/work_snapshot_service.dart';
import 'package:chat_group/features/work_mode/work_task_coordinator.dart';
import 'package:chat_group/features/work_mode/work_task_completion_choice.dart';
import 'package:chat_group/features/work_mode/work_task_event_store.dart';
import 'package:chat_group/features/work_mode/workspace_file_service.dart';
import 'package:chat_group/features/work_mode/workspace_mutation_service.dart';
import 'package:chat_group/features/work_mode/workspace_path_policy.dart';
import 'package:chat_group/services/chat_api_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/lifecycle_hive.dart';
import 'work_candidate_test_support.dart';
import 'package:chat_group/features/document/document_understanding_service.dart';
import 'package:chat_group/core/models/media_attachment.dart';
import '../helpers/memory_governance_store.dart';

part 'work_mode_s8_end_to_end_support.dart';

void main() {
  late Directory hiveDirectory;
  late Directory isolatedDesktop;
  late DatabaseService database;
  late WorkTaskEventStore eventStore;
  late WorkTaskCoordinator coordinator;

  setUp(() async {
    hiveDirectory = await openLifecycleHive();
    database = CandidateTestDatabase(hiveDirectory);
    eventStore = WorkTaskEventStore(
      appSupportDirectory: Directory('${hiveDirectory.path}/s8-support'),
    );
    isolatedDesktop =
        await Directory('${hiveDirectory.path}/approved-desktop').create();
  });

  tearDown(() async {
    await coordinator.dispose();
    await eventStore.close();
    await closeLifecycleHive(hiveDirectory, database);
  });

  test('keeps a frozen DOCX blocked until every member performs real usage',
      () async {
    const groupId = 's8-screenshot-group';
    final permissions = <ToolPermission>[
      ToolPermission.workspaceRead,
      ToolPermission.workspacePatch,
      ToolPermission.commandRun,
    ];
    final configIds = <String>[
      's8-product-config',
      's8-front-config',
      's8-qa-config',
    ];
    for (final configId in configIds) {
      await database.apiConfigBox.put(
        configId,
        ApiConfig(
          id: configId,
          name: configId,
          provider: ApiProvider.deepseek.name,
          modelName:
              configId == configIds[1] ? 'deepseek-vl2' : 'deepseek-chat',
          hasCredential: true,
          credentialId: 'credential-$configId',
        ),
      );
    }
    final characters = <AICharacter>[
      _s8Character(
        id: 's8-product',
        name: '产品经理',
        role: '产品经理',
        configId: configIds[0],
        permissions: permissions,
      ),
      _s8Character(
        id: 's8-front',
        name: '前端工程师',
        role: '前端工程师',
        configId: configIds[1],
        permissions: permissions,
        modelName: 'deepseek-vl2',
      ),
      _s8Character(
        id: 's8-qa',
        name: '测试工程师',
        role: '测试工程师',
        configId: configIds[2],
        permissions: permissions,
      ),
    ];
    for (final character in characters) {
      await database.aiCharacterBox.put(character.id, character);
    }
    final group = ChatGroup(
      id: groupId,
      name: 'S8 验收群',
      theme: '网页产品需求讨论',
      aiCharacterIds: characters.map((character) => character.id).toList(),
    );
    await database.chatGroupBox.put(group.id, group);

    const request = '@all 讨论 HTML 游戏需求，最后由@产品经理输出一份 Word 文档，保存到桌面。'
        '核心能力包括无限地图、方块采集、背包系统、合成系统、人物，其他可后续再做。';
    final route = await const WorkRoleRouter().route(
      request: request,
      conversationId: groupId,
      characters: characters,
      skills: const [],
    );
    expect(route.isSuccess, isTrue);
    expect(route.characterId, 's8-product');
    expect(route.discussionCharacterIds,
        characters.map((character) => character.id).toList());
    expect(route.deliverableContract?.format, 'docx');
    expect(route.deliverableContract?.location, 'desktop');
    expect(route.stages.map((stage) => stage.id), ['product']);

    final task = AgentTask(
      id: 's8-screenshot-task',
      groupId: groupId,
      characterId: route.characterId!,
      userRequest: request,
      requestedPermissions: permissions,
      assignedCharacterIds: const ['s8-product'],
      plan: 'S8 真实输入路由与群讨论验收',
      workModeTask: true,
    );
    final state = WorkDiscussionState.initial(
      conversationId: groupId,
      coordinatorId: route.discussionCharacterIds.first,
      executorId: route.characterId,
      candidateCharacterIds: const ['s8-product'],
      participantCharacterIds: route.discussionCharacterIds,
      deliverableContract: route.deliverableContract!.toJson(),
    );
    final fresh = WorkDiscussionState.forNewTask(task, routed: state);
    // The dedicated test group explicitly includes these professional reviewers.
    // No plan/delivery approval is seeded; each actual member turn must sign.
    final team = WorkRoleRouter.selectTeam(
        request: request,
        characters: characters,
        confirmedMemberIds: const ['s8-front', 's8-qa']);
    final collaboration = fresh.collaboration!.toJson()
      ..['team'] = team.team
      ..['coordinatorId'] = 's8-product';
    task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
        '',
        fresh.copyWith(
            collaboration: WorkCollaborationState.tryParse(collaboration)!));
    final taskExecution = jsonDecode(task.executionStateJson) as Map;
    task.executionStateJson = jsonEncode({
      ...taskExecution,
      'visionModelCharacterId': 's8-front',
    });

    final grants = WorkFolderGrantService(
      box: database.appSettingsBox,
      directoryValidator: (_) async => true,
      writeDirectoryValidator: (_) async => true,
      isWindows: false,
    );
    await grants.authorizeDirectory(
      isolatedDesktop.path,
      consent: (_) async => true,
    );
    final pathPolicy = WorkspacePathPolicy(grantService: grants);
    final files = WorkspaceFileService(pathPolicy: pathPolicy);
    final snapshots = WorkSnapshotService(
      appSupportDirectory: Directory('${hiveDirectory.path}/s8-snapshots'),
      pathPolicy: pathPolicy,
      eventStore: eventStore,
    );
    final mutations = WorkspaceMutationService(
      pathPolicy: pathPolicy,
      snapshotPort: snapshots,
      eventStore: eventStore,
    );
    final workspaceService = WorkModeWorkspaceService(
      db: database,
      grantService: grants,
      directories: _S8IsolatedDirectoryService(isolatedDesktop.path),
    );
    final pandoc = _S8PandocHarness();
    final commandRunner = WorkCommandRunner(
      policy: WorkCommandPolicy(
        authorizedRoots: [isolatedDesktop.path],
        isWindows: false,
        isMacOS: false,
      ),
      pathPolicy: pathPolicy,
      processStarter: pandoc.start,
    );
    final executionGateway = _S8ExecutionGateway()
      ..task = (() => task)
      ..root = isolatedDesktop.path;
    final runner = DefaultWorkTaskRunner(
      database: database,
      eventStore: eventStore,
      credentials: _S8Credentials(),
      gateway: executionGateway,
      workspaceService: workspaceService,
      folderGrantService: grants,
      workspaceFileService: files,
      mutationService: mutations,
      resourceLockManager: WorkResourceLockManager(isWindows: false),
      directoryService: _S8IsolatedDirectoryService(isolatedDesktop.path),
      commandRunner: commandRunner,
    );
    final discussionRunner = WorkDiscussionRunner(
      database: database,
      credentials: _S8Credentials(),
      workspaceService: workspaceService,
      eventStore: eventStore,
      completion: ({
        required character,
        required config,
        required apiKey,
        required provider,
        required conversationId,
        required messages,
        required timeout,
        cancelToken,
      }) async {
        final current =
            WorkDiscussionState.fromExecutionState(task.executionStateJson)!
                .collaboration!;
        final proposing = current.plan.isEmpty;
        final delivering = current.phase == 'reviewing';
        final ruling = !proposing &&
            current.isAutonomous &&
            character.id == current.coordinatorId &&
            current.participantIds.every((id) => current.currentApprovals.any(
                  (approval) =>
                      approval['memberId'] == id &&
                      approval['kind'] == 'plan' &&
                      approval['subjectId'] == current.taskId,
                )) &&
            !current.currentCoordinatorDecisions
                .any((decision) => decision['kind'] == 'plan');
        return {
          'success': true,
          'message': jsonEncode({
            'schemaVersion': 2,
            'action': proposing
                ? 'propose'
                : ruling
                    ? 'decide'
                    : 'approve',
            'public_update': character.id == 's8-front'
                ? '可实现性已核对；本次只交需求文档。'
                : character.id == 's8-qa'
                    ? '范围和验收条目已核对。'
                    : '核心能力写入需求，其他功能保留在非本期范围。',
            'issue_id': '',
            'next_member_id': '',
            'issues': [],
            'resolutions': [],
            'proposal': proposing
                ? {
                    'scope': current.scope,
                    'plan': '先制作 Word 需求文档，再由其他成员核对正文、格式与验收条目。',
                    'artifactContract': {
                      ...current.artifactContract,
                      'files': ['需求文档.docx']
                    },
                    'workItems': [
                      {
                        'id': 'requirements',
                        'ownerId': 's8-product',
                        'kind': 'produce',
                        'dependencies': []
                      }
                    ],
                    'acceptances': [
                      {
                        'id': 'doc-review',
                        'method': '正文与格式审查',
                        'requiredCapability': 'read'
                      }
                    ],
                    'usageAssignments': [
                      {
                        'memberId': 's8-product',
                        'scenarioId': 's8-product-review',
                        'goal': '以产品视角核对核心能力与本期范围',
                        'preconditions': '当前候选包含真实 DOCX 文件',
                        'stepGoals': ['打开候选文档并核对五项核心能力', '确认非本期范围未混入交付'],
                        'expectedResult': 'DOCX 内容符合用户明确的范围与验收要求',
                        'acceptanceIds': ['doc-review'],
                        'requiredCapabilities': [
                          'document.body',
                          'document.visual'
                        ],
                        'resetMethod': '关闭文档后重新打开当前候选',
                      },
                      {
                        'memberId': 's8-front',
                        'scenarioId': 's8-front-review',
                        'goal': '以实现视角核对能力描述能否落实',
                        'preconditions': '当前候选包含真实 DOCX 文件',
                        'stepGoals': ['读取能力与验收条目', '检查范围边界是否清楚'],
                        'expectedResult': '能力描述可实现且验收边界清晰',
                        'acceptanceIds': ['doc-review'],
                        'requiredCapabilities': ['read'],
                        'resetMethod': '关闭文档后重新打开当前候选',
                      },
                      {
                        'memberId': 's8-qa',
                        'scenarioId': 's8-qa-review',
                        'goal': '以测试视角核对验收要求是否可验证',
                        'preconditions': '当前候选包含真实 DOCX 文件',
                        'stepGoals': ['读取验收标准', '确认核心能力都有可检查结果'],
                        'expectedResult': '每项核心能力均有明确的验收结果',
                        'acceptanceIds': ['doc-review'],
                        'requiredCapabilities': ['read'],
                        'resetMethod': '关闭文档后重新打开当前候选',
                      }
                    ]
                  }
                : null,
            'approval': proposing || ruling
                ? null
                : {
                    'kind': delivering ? 'delivery' : 'plan',
                    'subjectId': delivering
                        ? current.currentIteration!['id']
                        : current.taskId,
                    'approved': true,
                    'requestRevision': current.requestRevision,
                    'teamRevision': current.teamRevision,
                    'verificationRevision': current.verificationRevision,
                    if (delivering)
                      'iterationId': current.currentIteration!['id'],
                    if (delivering)
                      'artifactDigest':
                          current.currentIteration!['artifactDigest']
                  },
            'decision': ruling
                ? {
                    'kind': 'ruling',
                    'targetId': current.taskId,
                    'reason': '成员已分别确认当前范围与交付方式。',
                    'evidence': '已核对全体成员针对当前方案的真实认可记录。',
                    'impact': '维持用户范围，由指定执行者制作。',
                    'options': [],
                  }
                : null,
            'tool': null
          })
        };
      },
    );
    coordinator = WorkTaskCoordinator(
      taskBox: database.agentTaskBox,
      eventStore: eventStore,
      runner: runner,
      discussionRunner: discussionRunner,
      requireFolderGrant: false,
      resourceLockManager: WorkResourceLockManager(isWindows: false),
    );

    final submitted = await coordinator.submit(task);
    expect(submitted.characterId, 's8-product');
    final approvalForPatch = await _s8WaitFor(
      database,
      task.id,
      eventStore,
      (value) =>
          value.status == AgentTaskStatus.waitingForApproval &&
          value.pendingToolRequestJson.contains('workspace.patch'),
    );
    final discussionState = WorkDiscussionState.fromExecutionState(
      approvalForPatch.executionStateJson,
    );
    expect(discussionState?.schemaVersion, 2);
    expect(discussionState?.collaboration?.productionReady, isTrue);
    expect(discussionState?.collaboration?.team.length, 3);

    await coordinator.approve(task.id);
    final approvalForPandoc = await _s8WaitFor(
      database,
      task.id,
      eventStore,
      (value) =>
          value.status == AgentTaskStatus.waitingForApproval &&
          value.pendingToolRequestJson.contains('command.run'),
    );
    expect(approvalForPandoc.pendingToolRequestJson, contains('pandoc'));
    final workspace = database.workModeWorkspaceBox.get(groupId);
    expect(workspace?.workDirPath, isolatedDesktop.path);
    expect(
      await File('${isolatedDesktop.path}/需求文档.docx').exists(),
      isFalse,
    );

    await coordinator.approveWithoutUndo(task.id);
    final frozen = await _s8WaitFor(
        database,
        task.id,
        eventStore,
        (value) =>
            WorkTaskCompletionChoice.pending(value) &&
            !coordinator.isTaskInFlight(value.id));
    await coordinator.chooseCandidateCompletion(
        task.id, WorkTaskCompletionChoice.identity(frozen)!,
        test: true);
    final blocked = await _s8WaitFor(
      database,
      task.id,
      eventStore,
      (value) => value.status == AgentTaskStatus.paused && value.resumeRequired,
    );
    expect(executionGateway.calls, greaterThanOrEqualTo(5));
    expect(pandoc.conversionCount, 1);
    expect(executionGateway.usageSystemPrompts, isNotEmpty);
    final usagePrompt = executionGateway.usageSystemPrompts.first;
    for (final instruction in const [
      '你负责 own_usage 对应的本人场景',
      '先核对候选版本、目标应用和前置测试数据',
      '每步依据操作后的真实结果继续',
      '不得修改候选、测试断言或必达验收',
      '旧缺陷也要实际复测',
      '只有图像实际送达且当前模型能够看见时才报告视觉观察',
      '没有真实操作证据不得签通过',
      '不能用搜索片段当全文',
      '不能用正文提取代替版式检查',
      'documentEvidence:{pageNumbers:',
      '每个缺陷都要有本人观察到的 sourceLocation',
    ]) {
      expect(usagePrompt, contains(instruction));
    }
    for (final entry in executionGateway.usageModels.entries) {
      final actor = database.aiCharacterBox.get(entry.key)!;
      final actorConfig = database.apiConfigBox.get(actor.apiConfigId)!;
      expect(entry.value, actorConfig.modelName,
          reason: '试用成员 ${entry.key} 必须用自己的模型');
    }
    expect(blocked.lastError, contains('未完成实际使用'));
    final blockedState =
        WorkDiscussionState.fromExecutionState(blocked.executionStateJson)!;
    expect(blockedState.executorId, 's8-product');
    expect(blockedState.collaboration!.allMembersUsed, isFalse);
    expect(blockedState.collaboration!.deliveryReady, isFalse);

    final artifact = File('${isolatedDesktop.path}/需求文档.docx');
    expect(await artifact.exists(), isTrue);
    final sections = BinaryDocumentParser.validateDocxForDelivery(
      Uint8List.fromList(await artifact.readAsBytes()),
    );
    expect(sections, isNotEmpty);
    final body = sections.map((section) => section.text).join('\n');
    for (final item in const [
      '网页版我的世界产品需求文档',
      '无限地图',
      '方块采集',
      '背包系统',
      '合成系统',
      '人物系统',
      '验收标准',
    ]) {
      expect(body, contains(item));
    }
    expect(blocked.lastArtifactPaths, contains(endsWith('需求文档.docx')));

    final messages = database.messageBox.values
        .where((message) => message.groupId == groupId)
        .toList(growable: false);
    final spokenIds = messages
        .where((message) => message.senderType == 'ai')
        .map((message) => message.senderId)
        .toSet();
    expect(spokenIds, containsAll(const ['s8-product', 's8-front', 's8-qa']));
    expect(
      messages.any(
        (message) =>
            message.senderId == 's8-product' &&
            !message.content.contains('[理解进度'),
      ),
      isTrue,
    );
    expect(
      messages.any(
        (message) =>
            message.senderId == 's8-front' && message.content.contains('可实现性'),
      ),
      isTrue,
    );
    expect(
      messages.any(
        (message) =>
            message.senderId == 's8-qa' && message.content.contains('验收'),
      ),
      isTrue,
    );
  });
}

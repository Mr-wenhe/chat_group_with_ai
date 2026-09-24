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
import 'package:chat_group/features/work_mode/work_artifact_delivery_guard.dart';
import 'package:chat_group/features/work_mode/work_command_runner.dart';
import 'package:chat_group/features/work_mode/work_discussion_runner.dart';
import 'package:chat_group/features/work_mode/work_discussion_state.dart';
import 'package:chat_group/features/work_mode/work_folder_grant_service.dart';
import 'package:chat_group/features/work_mode/work_mode_directory_service.dart';
import 'package:chat_group/features/work_mode/work_mode_workspace_service.dart';
import 'package:chat_group/features/work_mode/work_resource_lock_manager.dart';
import 'package:chat_group/features/work_mode/work_role_router.dart';
import 'package:chat_group/features/work_mode/work_snapshot_service.dart';
import 'package:chat_group/features/work_mode/work_task_coordinator.dart';
import 'package:chat_group/features/work_mode/work_task_event_store.dart';
import 'package:chat_group/features/work_mode/workspace_file_service.dart';
import 'package:chat_group/features/work_mode/workspace_mutation_service.dart';
import 'package:chat_group/features/work_mode/workspace_path_policy.dart';
import 'package:chat_group/services/chat_api_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/lifecycle_hive.dart';
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
    database = DatabaseService();
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

  test(
      'routes the screenshot request through discussion, approvals and real DOCX delivery',
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
          modelName: 'deepseek-chat',
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
    task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
      '',
      state,
    );

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
    final executionGateway = _S8ExecutionGateway();
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
        final coordinatorPrompt = messages.any(
          (message) => message['content'].toString().contains('协调/执行人'),
        );
        return _s8DiscussionTurn(
          update: coordinatorPrompt
              ? '${character.name}已收集前端和测试建议，完成产品取舍，确认只输出 Word 需求文档。'
              : '${character.name}已从${character.role}职责给出可实现性、风险和验收建议。',
          percent: coordinatorPrompt ? 100 : 70,
        );
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
      (value) =>
          value.status == AgentTaskStatus.waitingForApproval &&
          value.pendingToolRequestJson.contains('workspace.patch'),
    );
    final discussionState = WorkDiscussionState.fromExecutionState(
      approvalForPatch.executionStateJson,
    );
    expect(discussionState?.isExecutionReady, isTrue);
    expect(discussionState?.understandingPercent, 100);
    expect(discussionState?.executorId, 's8-product');

    await coordinator.approve(task.id);
    final approvalForPandoc = await _s8WaitFor(
      database,
      task.id,
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
    final completed = await _s8WaitFor(
      database,
      task.id,
      (value) => value.status == AgentTaskStatus.completed,
    );
    // Two tool turns (conversion source, then pandoc) are enough: the DOCX
    // satisfies the contract, so the loop completes from that result instead of
    // spending a third model turn on a finish decision.
    expect(executionGateway.calls, 2);
    expect(pandoc.conversionCount, 1);
    expect(completed.characterId, 's8-product');
    expect(completed.lastArtifactPaths, contains(endsWith('需求文档.docx')));

    final artifactPath = completed.lastArtifactPaths.firstWhere(
      (path) => path.endsWith('需求文档.docx'),
    );
    final artifact = File(artifactPath);
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
    final delivery = await WorkArtifactDeliveryGuard.validateTask(
      task: completed,
      pathPolicy: pathPolicy,
      workspaceRoot: isolatedDesktop.path,
    );
    expect(delivery.valid, isTrue, reason: delivery.message);

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
            message.content.contains('[理解进度 100%]'),
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

import 'dart:convert';
import 'dart:io';

import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/tool_permission.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/features/ai_governance/ai_request_gateway.dart';
import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/work_mode/default_work_task_runner.dart';
import 'package:chat_group/features/work_mode/work_folder_grant_service.dart';
import 'package:chat_group/features/work_mode/work_mode_workspace_service.dart';
import 'package:chat_group/features/work_mode/work_snapshot_service.dart';
import 'package:chat_group/features/work_mode/work_task_coordinator.dart';
import 'package:chat_group/features/work_mode/work_task_event_store.dart';
import 'package:chat_group/features/work_mode/workspace_file_service.dart';
import 'package:chat_group/features/work_mode/workspace_mutation_service.dart';
import 'package:chat_group/features/work_mode/workspace_path_policy.dart';
import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/services/chat_api_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/lifecycle_hive.dart';
import '../helpers/memory_governance_store.dart';

class _TestCredentials implements ApiCredentialResolver {
  @override
  Future<String?> resolve(ApiConfig config) async => 'test-key';
}

class _SequencedGateway extends AiRequestGateway {
  _SequencedGateway()
      : super(
          store: MemoryGovernanceStore(),
          client: _UnusedClient(),
        );

  int calls = 0;

  @override
  Future<Map<String, dynamic>> sendChatMessageStreamed({
    required String apiKey,
    required ApiProvider provider,
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
    bool requiresTools = false,
    bool userInitiated = false,
  }) async {
    calls++;
    return {
      'success': true,
      'message': calls == 1
          ? '```agent_tool\n'
              '{"tool":"workspace.patch","reason":"写入授权目录文件",'
              '"args":{"path":"notes.txt","content":"production-stage02"}}\n'
              '```'
          : '已完成写入。',
    };
  }
}

/// The gateway override above never reaches a transport, but the concrete
/// gateway still requires a client in its constructor.
class _UnusedClient extends ChatApiService {}

void main() {
  late DatabaseService database;
  late WorkTaskEventStore eventStore;
  late Directory hiveDirectory;
  late Directory authorizedDirectory;

  setUp(() async {
    hiveDirectory = await openLifecycleHive();
    database = DatabaseService();
    eventStore = WorkTaskEventStore(
      appSupportDirectory: Directory('${hiveDirectory.path}/app-support'),
    );
    authorizedDirectory =
        await Directory('${hiveDirectory.path}/authorized').create();
  });

  tearDown(() async {
    await eventStore.close();
    await closeLifecycleHive(hiveDirectory, database);
  });

  test('production runner routes approved workspace.patch through Stage02',
      () async {
    final grants = WorkFolderGrantService(
      box: database.appSettingsBox,
      directoryValidator: (_) async => true,
      isWindows: false,
    );
    final grant = await grants.authorizeDirectory(
      authorizedDirectory.path,
      consent: (_) async => true,
    );
    expect(grant, isNotNull);
    final pathPolicy = WorkspacePathPolicy(grantService: grants);
    final files = WorkspaceFileService(pathPolicy: pathPolicy);
    final snapshots = WorkSnapshotService(
      appSupportDirectory: Directory('${hiveDirectory.path}/app-support'),
      pathPolicy: pathPolicy,
    );
    final mutations = WorkspaceMutationService(
      pathPolicy: pathPolicy,
      snapshotPort: snapshots,
    );
    final gateway = _SequencedGateway();
    final config = ApiConfig(
      id: 'stage02-config',
      name: 'Stage02 test config',
      provider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
    );
    final character = AICharacter(
      id: 'stage02-character',
      name: 'Stage02 character',
      avatar: 'S2',
      age: 30,
      role: '测试执行角色',
      personalityTags: const [],
      systemPrompt: '只按工具协议工作。',
      apiKey: '',
      apiProvider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
      apiConfigId: config.id,
      toolPermissions: const [
        ToolPermission.workspaceRead,
        ToolPermission.workspacePatch,
      ],
    );
    await database.apiConfigBox.put(config.id, config);
    await database.aiCharacterBox.put(character.id, character);

    final runner = DefaultWorkTaskRunner(
      database: database,
      eventStore: eventStore,
      credentials: _TestCredentials(),
      gateway: gateway,
      workspaceService: WorkModeWorkspaceService(
        db: database,
        grantService: grants,
      ),
      folderGrantService: grants,
      workspaceFileService: files,
      mutationService: mutations,
    );
    final task = AgentTask(
      id: 'stage02-runner-task',
      groupId: 'stage02-group',
      characterId: character.id,
      userRequest: '请处理这个需求',
      workModeTask: true,
    );

    await runner.run(task, WorkTaskCancellation());

    expect(task.status, AgentTaskStatus.waitingForApproval);
    // The pending request is held in the runner while the task checkpoint is
    // persisted; this assertion also proves the first model turn was parsed.
    expect(task.pendingToolRequestJson, contains('workspace.patch'));
    expect(task.executionStateJson, contains('approvalScope'));
    final pendingSummary = jsonDecode(task.contextSummary) as Map;
    expect(pendingSummary['schemaVersion'], 2);
    expect(pendingSummary['goal'], '请处理这个需求');
    expect(pendingSummary['acceptanceCriteria'], isNotEmpty);
    expect(pendingSummary['completedActions'], isEmpty);
    expect(pendingSummary['sideEffects'], isEmpty);
    expect(pendingSummary['artifactPaths'], contains('notes.txt'));
    expect(pendingSummary['approvedScope'], isNotNull);
    expect(pendingSummary['unresolved'], isNotEmpty);
    expect(
      await File(
        '${authorizedDirectory.path}/conversations/group_stage02-group/notes.txt',
      ).exists(),
      isFalse,
    );

    final checkpoint = jsonDecode(task.executionStateJson) as Map;
    task.executionStateJson = jsonEncode({
      ...checkpoint,
      'approvalDecision': 'approved',
    });
    await database.agentTaskBox.put(task.id, task);
    await runner.run(task, WorkTaskCancellation());

    final output = File(
      '${authorizedDirectory.path}/conversations/group_stage02-group/notes.txt',
    );
    expect(task.status, AgentTaskStatus.completed);
    final completedSummary = jsonDecode(task.contextSummary) as Map;
    expect(completedSummary['approvedScope'], isNotNull);
    expect(completedSummary['sideEffects'], isNotEmpty);
    expect(completedSummary['unresolved'], isEmpty);
    expect(completedSummary['lastResult'], contains('已生成文件'));
    expect(await output.readAsString(), 'production-stage02');
    expect(gateway.calls, 1);
    expect((await snapshots.readManifest(task.id))?.actions.single.completed,
        isTrue);
    expect((await snapshots.undo(task.id)).succeeded, isTrue);
    expect(await output.exists(), isFalse);
  });
}

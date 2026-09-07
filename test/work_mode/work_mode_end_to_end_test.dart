import 'dart:convert';
import 'dart:io';
import 'dart:collection';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/models/tool_permission.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/ai_governance/ai_governance_store.dart';
import 'package:chat_group/features/ai_governance/ai_request_gateway.dart';
import 'package:chat_group/features/ai_governance/ai_request_guard.dart';
import 'package:chat_group/features/ai_governance/model_capability_registry.dart';
import 'package:chat_group/features/work_mode/default_work_task_runner.dart';
import 'package:chat_group/features/work_mode/work_folder_grant_service.dart';
import 'package:chat_group/features/work_mode/work_mode_workspace_service.dart';
import 'package:chat_group/features/work_mode/work_resource_lock_manager.dart';
import 'package:chat_group/features/work_mode/work_snapshot_service.dart';
import 'package:chat_group/features/work_mode/work_task_coordinator.dart';
import 'package:chat_group/features/work_mode/work_task_event.dart';
import 'package:chat_group/features/work_mode/work_task_event_store.dart';
import 'package:chat_group/features/work_mode/workspace_file_service.dart';
import 'package:chat_group/features/work_mode/workspace_mutation_service.dart';
import 'package:chat_group/features/work_mode/workspace_path_policy.dart';
import 'package:chat_group/services/chat_api_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/lifecycle_hive.dart';

class _Credentials implements ApiCredentialResolver {
  @override
  Future<String?> resolve(ApiConfig config) async => 'test-key';
}

class _StrictDecisionGateway extends AiRequestGateway {
  final Queue<String> decisions;
  int calls = 0;

  _StrictDecisionGateway(this.decisions)
      : super(store: _Store(), client: _UnusedChatApi());

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
    if (decisions.isEmpty) {
      return {'success': false, 'message': '没有更多严格决策。'};
    }
    return {'success': true, 'message': decisions.removeFirst()};
  }
}

class _Store implements GovernancePersistence {
  @override
  BudgetSettings budgetSettings = const BudgetSettings();
  @override
  WebSearchPolicy globalSearchPolicy = WebSearchPolicy.off;
  @override
  final List<UsageLedgerEntry> ledgerEntries = <UsageLedgerEntry>[];
  @override
  final List<AiRequestDiagnostic> diagnostics = <AiRequestDiagnostic>[];
  @override
  final List<SearchAuditEntry> searchAudits = <SearchAuditEntry>[];
  AiRequestGuard? _guard;

  @override
  AiRequestGuard get guard => _guard ??= AiRequestGuard(
        store: this,
        registry: ModelCapabilityRegistry(),
        clock: DateTime.now,
      );

  final Map<String, WebSearchPolicy> conversationPolicies =
      <String, WebSearchPolicy>{};
  final Map<String, CustomModelCapability> customCapabilities =
      <String, CustomModelCapability>{};

  @override
  WebSearchPolicy? conversationSearchPolicy(String conversationId) =>
      conversationPolicies[conversationId];

  @override
  CustomModelCapability? customCapability(String provider, String model) =>
      customCapabilities['$provider/$model'];

  @override
  Future<void> ensureLedgerBox() async {}

  @override
  Future<void> addDiagnostic(AiRequestDiagnostic diagnostic) async =>
      diagnostics.add(diagnostic);

  @override
  Future<void> addLedgerEntry(UsageLedgerEntry entry) async =>
      ledgerEntries.add(entry);

  @override
  Future<void> addSearchAudit(SearchAuditEntry entry) async =>
      searchAudits.add(entry);

  @override
  Future<void> clearDiagnostics() async => diagnostics.clear();

  @override
  Future<void> clearLedger() async => ledgerEntries.clear();

  @override
  Future<void> clearSearchAudits() async => searchAudits.clear();

  @override
  Future<void> saveBudgetSettings(BudgetSettings settings) async =>
      budgetSettings = settings;

  @override
  Future<void> saveConversationSearchPolicy(
    String conversationId,
    WebSearchPolicy? policy,
  ) async {
    if (policy == null) {
      conversationPolicies.remove(conversationId);
    } else {
      conversationPolicies[conversationId] = policy;
    }
  }

  @override
  Future<void> saveCustomCapability(
    String provider,
    String model,
    CustomModelCapability capability,
  ) async =>
      customCapabilities['$provider/$model'] = capability;

  @override
  Future<void> saveGlobalSearchPolicy(WebSearchPolicy policy) async =>
      globalSearchPolicy = policy;
}

class _UnusedChatApi extends ChatApiService {}

String _decision({
  required String action,
  required String update,
  Map<String, dynamic>? tool,
  Map<String, dynamic>? completion,
}) =>
    jsonEncode({
      'action': action,
      'public_update': update,
      'tool': tool,
      'completion': completion,
    });

String _tool(String name, Map<String, dynamic> arguments, String update) =>
    _decision(
      action: 'tool',
      update: update,
      tool: {'name': name, 'arguments': arguments},
    );

String _finish(String summary) => _decision(
      action: 'finish',
      update: '已完成并核对结果。',
      completion: {
        'summary': summary,
        'evidence': ['文件可重新读取']
      },
    );

Future<AgentTask> _waitFor(
  WorkTaskCoordinator coordinator,
  String taskId,
  bool Function(AgentTask task) predicate,
) async {
  await for (final task in coordinator.watchTask(taskId)) {
    if (predicate(task)) return task;
  }
  throw StateError('任务状态流意外结束：$taskId');
}

void main() {
  late Directory hiveDirectory;
  late DatabaseService database;
  late WorkTaskEventStore eventStore;
  late Directory authorizedDirectory;

  setUp(() async {
    hiveDirectory = await openLifecycleHive();
    database = DatabaseService();
    eventStore = WorkTaskEventStore(
      appSupportDirectory: Directory('${hiveDirectory.path}/support'),
    );
    authorizedDirectory =
        await Directory('${hiveDirectory.path}/authorized').create();
  });

  tearDown(() async {
    await eventStore.close();
    await closeLifecycleHive(hiveDirectory, database);
  });

  test(
      'production work mode keeps one loop across read approval write follow-up and undo',
      () async {
    const groupId = 'e2e-group';
    const characterId = 'e2e-worker';
    final grants = WorkFolderGrantService(
      box: database.appSettingsBox,
      directoryValidator: (_) async => true,
      writeDirectoryValidator: (_) async => true,
      isWindows: false,
    );
    await grants.authorizeDirectory(
      authorizedDirectory.path,
      consent: (_) async => true,
    );
    final pathPolicy = WorkspacePathPolicy(grantService: grants);
    final files = WorkspaceFileService(pathPolicy: pathPolicy);
    final snapshots = WorkSnapshotService(
      appSupportDirectory: Directory('${hiveDirectory.path}/support'),
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
    final workspace = await workspaceService.loadOrCreate(
      conversationId: groupId,
      isDirectChat: false,
    );
    final original = File('${workspace.workDirPath}/notes.txt');
    await original.parent.create(recursive: true);
    await original.writeAsString('v1');

    final config = ApiConfig(
      id: 'e2e-config',
      name: 'E2E',
      provider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
    );
    final character = AICharacter(
      id: characterId,
      name: '执行角色',
      avatar: 'E2E',
      age: 30,
      role: '开发执行',
      personalityTags: const [],
      systemPrompt: '严格执行并报告公开进度。',
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

    final gateway = _StrictDecisionGateway(Queue.of([
      _tool('workspace.read', {'path': 'notes.txt'}, '正在读取原文件。'),
      _tool(
          'workspace.patch',
          {
            'path': 'notes.txt',
            'content': 'v2',
          },
          '已读取原文件，准备请求写入批准。'),
      _finish('原文件已更新为 v2。'),
      _tool('workspace.read', {'path': 'notes.txt'}, '正在读取待修订文件。'),
      _tool(
          'workspace.patch',
          {
            'path': 'notes.txt',
            'content': 'v3',
          },
          '正在修订同一原文件。'),
      _finish('原文件已修订为 v3。'),
    ]));
    final runner = DefaultWorkTaskRunner(
      database: database,
      eventStore: eventStore,
      credentials: _Credentials(),
      gateway: gateway,
      workspaceService: workspaceService,
      folderGrantService: grants,
      workspaceFileService: files,
      mutationService: mutations,
      resourceLockManager: WorkResourceLockManager(isWindows: false),
    );
    final coordinator = WorkTaskCoordinator(
      taskBox: database.agentTaskBox,
      eventStore: eventStore,
      runner: runner,
      folderGrantService: grants,
      requireFolderGrant: false,
      resourceLockManager: WorkResourceLockManager(isWindows: false),
    );

    final task = await coordinator.submit(AgentTask(
      id: 'e2e-task',
      groupId: groupId,
      characterId: characterId,
      userRequest: '把 notes.txt 更新为 v2',
      requestedPermissions: character.toolPermissions,
      assignedCharacterIds: const [characterId],
      workModeTask: true,
    ));
    final waiting = await _waitFor(
      coordinator,
      task.id,
      (value) => value.status == AgentTaskStatus.waitingForApproval,
    );
    expect(waiting.pendingToolRequestJson, contains('workspace.patch'));
    final pendingEvents = await eventStore.read(task.id);
    expect(
      pendingEvents.events.any(
        (event) => event.kind == WorkTaskEventKind.approvalRequired,
      ),
      isTrue,
    );

    await coordinator.approve(task.id);
    final completed = await _waitFor(
      coordinator,
      task.id,
      (value) => value.status == AgentTaskStatus.completed,
    );
    expect(completed.resultSummary, contains('v2'));
    expect(await original.readAsString(), 'v2');
    expect(gateway.calls, 3);

    await coordinator.enqueueFollowUp(task.id, '请把原文件改成 v3');
    final revisionWaiting = await _waitFor(
      coordinator,
      task.id,
      (value) => value.status == AgentTaskStatus.waitingForApproval,
    );
    expect(revisionWaiting.pendingToolRequestJson, contains('workspace.patch'));
    await coordinator.approve(task.id);
    await _waitFor(
      coordinator,
      task.id,
      (value) => value.status == AgentTaskStatus.completed,
    );
    expect(await original.readAsString(), 'v3');
    expect(gateway.calls, 6);

    final completedEvents = await eventStore.read(task.id);
    expect(
      completedEvents.events
          .where((event) => event.kind == WorkTaskEventKind.completed),
      isNotEmpty,
    );
    final manifest = await snapshots.readManifest(task.id);
    expect(manifest, isNotNull);
    expect(manifest!.actions, hasLength(2));
    expect(manifest.actions.every((action) => action.completed), isTrue);
    final undo = await snapshots.undo(task.id);
    expect(undo.succeeded, isTrue);
    expect(await original.readAsString(), 'v1');

    await coordinator.dispose();
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/models/api_protocol.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/media_attachment.dart';
import 'package:chat_group/core/models/tool_permission.dart';
import 'package:chat_group/core/streaming/chat_stream_event.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/features/ai_governance/ai_request_gateway.dart';
import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/work_mode/default_work_task_runner.dart';
import 'package:chat_group/features/work_mode/work_folder_grant_service.dart';
import 'package:chat_group/features/work_mode/work_mode_workspace_service.dart';
import 'package:chat_group/features/work_mode/work_snapshot_service.dart';
import 'package:chat_group/features/work_mode/work_command_runner.dart';
import 'package:chat_group/features/work_mode/work_task_coordinator.dart';
import 'package:chat_group/features/work_mode/work_task_event.dart';
import 'package:chat_group/features/work_mode/work_task_event_store.dart';
import 'package:chat_group/features/work_mode/workspace_file_service.dart';
import 'package:chat_group/features/work_mode/workspace_mutation_service.dart';
import 'package:chat_group/features/work_mode/workspace_path_policy.dart';
import 'package:chat_group/features/work_mode/work_resource_lock_manager.dart';
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
  final String patchPath;
  final String patchContent;
  final bool repeatToolOnSecondModelCall;

  _SequencedGateway({
    this.patchPath = 'notes.txt',
    this.patchContent = 'production-stage02',
    this.repeatToolOnSecondModelCall = false,
  }) : super(
          store: MemoryGovernanceStore(),
          client: _UnusedClient(),
        );

  int calls = 0;

  @override
  Future<Map<String, dynamic>> sendChatMessageStreamed({
    required String apiKey,
    required ApiProvider provider,
    ApiProtocol apiProtocol = ApiProtocol.defaultValue,
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
    void Function(ChatStreamEvent event)? onEvent,
  }) async {
    calls++;
    final returnsTool = repeatToolOnSecondModelCall ? calls <= 2 : calls == 1;
    return {
      'success': true,
      'message': returnsTool
          ? jsonEncode({
              'action': 'tool',
              'public_update': '准备写入授权目录文件。',
              'tool': {
                'name': 'workspace.patch',
                'arguments': {
                  'path': patchPath,
                  'content': patchContent,
                },
              },
              'completion': null,
            })
          : jsonEncode({
              'action': 'finish',
              'public_update': '写入已完成并核对结果。',
              'tool': null,
              'completion': {
                'summary': '已生成文件 $patchPath。',
                'evidence': ['文件可重新读取'],
              },
            }),
    };
  }
}

class _MultiPatchGateway extends AiRequestGateway {
  final List<Map<String, String>> patches;

  _MultiPatchGateway(this.patches)
      : super(
          store: MemoryGovernanceStore(),
          client: _UnusedClient(),
        );

  int calls = 0;

  @override
  Future<Map<String, dynamic>> sendChatMessageStreamed({
    required String apiKey,
    required ApiProvider provider,
    ApiProtocol apiProtocol = ApiProtocol.defaultValue,
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
    void Function(ChatStreamEvent event)? onEvent,
  }) async {
    calls++;
    final patchIndex = calls - 1;
    final message = patchIndex < patches.length
        ? jsonEncode({
            'action': 'tool',
            'public_update': '准备生成第 ${patchIndex + 1} 个项目文件。',
            'tool': {
              'name': 'workspace.patch',
              'arguments': {
                'path': patches[patchIndex]['path'],
                'content': patches[patchIndex]['content'],
              },
            },
            'completion': null,
          })
        : jsonEncode({
            'action': 'finish',
            'public_update': '项目文件已生成并核对。',
            'tool': null,
            'completion': {
              'summary': '已生成全部项目文件。',
              'evidence': ['每个文件均已重新读取'],
            },
          });
    return {'success': true, 'message': message};
  }
}

class _CommandGateway extends AiRequestGateway {
  _CommandGateway()
      : super(
          store: MemoryGovernanceStore(),
          client: _UnusedClient(),
        );

  @override
  Future<Map<String, dynamic>> sendChatMessageStreamed({
    required String apiKey,
    required ApiProvider provider,
    ApiProtocol apiProtocol = ApiProtocol.defaultValue,
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
    void Function(ChatStreamEvent event)? onEvent,
  }) async {
    return {
      'success': true,
      'message': jsonEncode({
        'action': 'tool',
        'public_update': '准备读取工作目录。',
        'tool': {
          'name': 'command.run',
          'arguments': {
            'executable': 'pwd',
            'arguments': <String>[],
            'workingDirectory': '.',
            'declaredImpact': <String>['.'],
          },
        },
        'completion': null,
      }),
    };
  }
}

class _MissingMutationCommandGateway extends AiRequestGateway {
  _MissingMutationCommandGateway()
      : super(
          store: MemoryGovernanceStore(),
          client: _UnusedClient(),
        );

  int calls = 0;

  @override
  Future<Map<String, dynamic>> sendChatMessageStreamed({
    required String apiKey,
    required ApiProvider provider,
    ApiProtocol apiProtocol = ApiProtocol.defaultValue,
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
    void Function(ChatStreamEvent event)? onEvent,
  }) async {
    calls++;
    final content = calls == 1
        ? {
            'action': 'tool',
            'public_update': '检查缺失工具。',
            'tool': {
              'name': 'command.run',
              'arguments': {
                'executable': 'insta',
                'arguments': <String>[],
                'workingDirectory': '.',
                'declaredImpact': <String>['.'],
              },
            },
            'completion': null,
          }
        : {
            'action': 'finish',
            'public_update': '检查完成。',
            'tool': null,
            'completion': {
              'summary': '缺失工具检查完成。',
              'evidence': ['工具状态已记录'],
            },
          };
    return {'success': true, 'message': jsonEncode(content)};
  }
}

class _ReadOnlyCommandGateway extends AiRequestGateway {
  int calls = 0;

  _ReadOnlyCommandGateway()
      : super(
          store: MemoryGovernanceStore(),
          client: _UnusedClient(),
        );

  @override
  Future<Map<String, dynamic>> sendChatMessageStreamed({
    required String apiKey,
    required ApiProvider provider,
    ApiProtocol apiProtocol = ApiProtocol.defaultValue,
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
    void Function(ChatStreamEvent event)? onEvent,
  }) async {
    calls++;
    final content = calls == 1
        ? {
            'action': 'tool',
            'public_update': '读取当前工作目录。',
            'tool': {
              'name': 'command.run',
              'arguments': {
                'executable': 'pwd',
                'arguments': <String>[],
                'workingDirectory': '.',
                'declaredImpact': <String>['.'],
              },
            },
            'completion': null,
          }
        : {
            'action': 'finish',
            'public_update': '已完成只读检查。',
            'tool': null,
            'completion': {
              'summary': '当前工作目录已读取。',
              'evidence': ['命令已返回'],
            },
          };
    return {'success': true, 'message': jsonEncode(content)};
  }
}

class _SensitiveGateway extends AiRequestGateway {
  final String toolName;
  final Map<String, dynamic> arguments;
  int calls = 0;

  _SensitiveGateway({required this.toolName, required this.arguments})
      : super(
          store: MemoryGovernanceStore(),
          client: _UnusedClient(),
        );

  @override
  Future<Map<String, dynamic>> sendChatMessageStreamed({
    required String apiKey,
    required ApiProvider provider,
    ApiProtocol apiProtocol = ApiProtocol.defaultValue,
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
    void Function(ChatStreamEvent event)? onEvent,
  }) async {
    calls++;
    return {
      'success': true,
      'message': calls == 1
          ? jsonEncode({
              'action': 'tool',
              'public_update': '读取敏感文件。',
              'tool': {'name': toolName, 'arguments': arguments},
              'completion': null,
            })
          : jsonEncode({
              'action': 'finish',
              'public_update': '已按用户决定继续。',
              'tool': null,
              'completion': {
                'summary': '敏感读取已按用户决定跳过。',
                'evidence': ['未暴露敏感内容'],
              },
            }),
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
    final publicEvents = (await eventStore.read(task.id)).events;
    expect(
      publicEvents.any(
        (event) =>
            event.kind == WorkTaskEventKind.toolOutput &&
            event.safeMetadata['pending'] == true,
      ),
      isTrue,
    );
    expect(
      publicEvents.any(
        (event) =>
            event.kind == WorkTaskEventKind.modelOutput &&
            event.detail == '准备写入授权目录文件。',
      ),
      isTrue,
    );
    // The pending request is held in the runner while the task checkpoint is
    // persisted; this assertion also proves the first model turn was parsed.
    expect(task.pendingToolRequestJson, contains('workspace.patch'));
    expect(task.executionStateJson, contains('approvalScope'));
    final pendingSummary = jsonDecode(task.contextSummary) as Map;
    expect(pendingSummary['schemaVersion'], 1);
    expect(pendingSummary['conversationId'], 'stage02-group');
    expect(pendingSummary['target'], '请处理这个需求');
    expect(pendingSummary['artifactPaths'], isEmpty);
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
    task.status = AgentTaskStatus.queued;
    await database.agentTaskBox.put(task.id, task);
    await runner.run(task, WorkTaskCancellation());

    final output = File(
      '${authorizedDirectory.path}/conversations/group_stage02-group/notes.txt',
    );
    expect(task.status, AgentTaskStatus.completed);
    final completedSummary = jsonDecode(task.contextSummary) as Map;
    expect(completedSummary['conversationId'], 'stage02-group');
    expect(completedSummary['completedSummaries'], isNotEmpty);
    expect(
      (completedSummary['artifactPaths'] as List)
          .whereType<String>()
          .any((path) => path.endsWith('/notes.txt')),
      isTrue,
    );
    expect(await output.readAsString(), 'production-stage02');
    expect(gateway.calls, 2);
    expect((await snapshots.readManifest(task.id))?.actions.single.completed,
        isTrue);
    expect((await snapshots.undo(task.id)).succeeded, isTrue);
    expect(await output.exists(), isFalse);
  });

  test('production runner records every workspace.patch in one project ZIP',
      () async {
    final grants = WorkFolderGrantService(
      box: database.appSettingsBox,
      directoryValidator: (_) async => true,
      writeDirectoryValidator: (_) async => true,
      isWindows: false,
    );
    expect(
      await grants.authorizeDirectory(
        authorizedDirectory.path,
        consent: (_) async => true,
      ),
      isNotNull,
    );
    final pathPolicy = WorkspacePathPolicy(grantService: grants);
    final files = WorkspaceFileService(pathPolicy: pathPolicy);
    final snapshots = WorkSnapshotService(
      appSupportDirectory: Directory('${hiveDirectory.path}/app-support'),
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
      conversationId: 'stage02-project',
      isDirectChat: false,
      requireWritable: true,
    );
    await database.saveAiProcessingDirPath(
      '${hiveDirectory.path}/ai-processing',
    );
    final mediaDirectory =
        await Directory('${hiveDirectory.path}/media').create(recursive: true);
    var mediaCopyIndex = 0;

    const projectFiles = <Map<String, String>>[
      {
        'path': 'project/lib/main.dart',
        'content': 'void main() => print("hello");',
      },
      {
        'path': 'project/test/main_test.dart',
        'content': 'void main() {}',
      },
      {
        'path': 'project/assets/config.json',
        'content': '{"name":"demo"}',
      },
    ];
    final gateway = _MultiPatchGateway(projectFiles);
    final config = ApiConfig(
      id: 'stage02-project-config',
      name: 'Stage02 project test config',
      provider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
    );
    final character = AICharacter(
      id: 'stage02-project-character',
      name: '项目执行角色',
      avatar: 'P',
      age: 30,
      role: '项目生成测试角色',
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
      workspaceService: workspaceService,
      folderGrantService: grants,
      workspaceFileService: files,
      mutationService: mutations,
      mediaCopier: (source, type, {fileName}) async {
        final target = File(
          '${mediaDirectory.path}/${mediaCopyIndex++}-${fileName ?? 'attachment'}',
        );
        await source.copy(target.path);
        return MediaAttachment(
          type: type,
          localPath: target.path,
          fileName: fileName,
          fileSize: await target.length(),
        );
      },
    );
    final task = AgentTask(
      id: 'stage02-project-task',
      groupId: 'stage02-project',
      characterId: character.id,
      userRequest: '生成项目源码并交付全部文件',
      workModeTask: true,
    );

    var approvalRounds = 0;
    while (task.status != AgentTaskStatus.completed) {
      await runner.run(task, WorkTaskCancellation());
      if (task.status != AgentTaskStatus.waitingForApproval) break;
      approvalRounds++;
      expect(approvalRounds, lessThanOrEqualTo(projectFiles.length));
      expect(task.pendingToolRequestJson, contains('workspace.patch'));
      final checkpoint = jsonDecode(task.executionStateJson) as Map;
      task
        ..executionStateJson = jsonEncode({
          ...checkpoint,
          'approvalDecision': 'approved',
        })
        ..status = AgentTaskStatus.queued;
      await database.agentTaskBox.put(task.id, task);
    }

    expect(task.status, AgentTaskStatus.completed,
        reason: '${task.lastError}; ${task.resultSummary}');
    expect(gateway.calls, projectFiles.length + 1);
    final expectedPaths = projectFiles
        .map((file) => '${workspace.workDirPath}/${file['path']}')
        .toList(growable: false);
    final canonicalPaths = <String>[];
    for (var index = 0; index < projectFiles.length; index++) {
      final canonicalPath =
          await File(expectedPaths[index]).resolveSymbolicLinks();
      final canonical = File(canonicalPath);
      canonicalPaths.add(canonicalPath);
      expect(
        await canonical.readAsString(),
        projectFiles[index]['content'],
      );
    }
    // macOS may expose the temporary directory through /var while the
    // resolved path returned by the tool uses its /private/var spelling.
    expect(task.lastArtifactPaths, containsAll(canonicalPaths));

    final message = database.messageBox.values
        .where((item) =>
            item.groupId == task.groupId && item.senderId == character.id)
        .last;
    expect(
      message.media,
      hasLength(1),
      reason:
          'content=${message.content}; paths=${task.lastArtifactPaths}; root=${workspace.workDirPath}',
    );
    expect(message.content, contains('3 个产物打包为 ZIP'));
    final archive = ZipDecoder().decodeBytes(
      await File(message.media!.single.localPath).readAsBytes(),
    );
    final names = archive.files.map((entry) => entry.name).toList();
    expect(
        names.any((name) => name.endsWith('/project/lib/main.dart')), isTrue);
    expect(names.any((name) => name.endsWith('/project/test/main_test.dart')),
        isTrue);
    expect(names.any((name) => name.endsWith('/project/assets/config.json')),
        isTrue);
    final events = await eventStore.read(task.id);
    final progress = events.events
        .where((event) => event.title == '文件交付进度')
        .toList(growable: false);
    expect(progress.last.safeMetadata['filesProcessed'], 3);
  });

  test('production command cannot use task permissions to bypass role grant',
      () async {
    final grants = WorkFolderGrantService(
      box: database.appSettingsBox,
      directoryValidator: (_) async => true,
      writeDirectoryValidator: (_) async => true,
      isWindows: false,
    );
    expect(
      await grants.authorizeDirectory(
        authorizedDirectory.path,
        consent: (_) async => true,
      ),
      isNotNull,
    );
    final pathPolicy = WorkspacePathPolicy(grantService: grants);
    final files = WorkspaceFileService(pathPolicy: pathPolicy);
    final snapshots = WorkSnapshotService(
      appSupportDirectory: Directory('${hiveDirectory.path}/app-support'),
      pathPolicy: pathPolicy,
      eventStore: eventStore,
    );
    final mutations = WorkspaceMutationService(
      pathPolicy: pathPolicy,
      snapshotPort: snapshots,
      eventStore: eventStore,
    );
    final config = ApiConfig(
      id: 'command-permission-config',
      name: 'Command permission test',
      provider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
    );
    final character = AICharacter(
      id: 'command-permission-character',
      name: '无命令权限角色',
      avatar: 'CP',
      age: 30,
      role: '只读角色',
      personalityTags: const [],
      systemPrompt: '只按工具协议工作。',
      apiKey: '',
      apiProvider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
      apiConfigId: config.id,
      toolPermissions: const [ToolPermission.workspaceRead],
    );
    await database.apiConfigBox.put(config.id, config);
    await database.aiCharacterBox.put(character.id, character);

    var processStarts = 0;
    final runner = DefaultWorkTaskRunner(
      database: database,
      eventStore: eventStore,
      credentials: _TestCredentials(),
      gateway: _CommandGateway(),
      workspaceService: WorkModeWorkspaceService(
        db: database,
        grantService: grants,
      ),
      folderGrantService: grants,
      workspaceFileService: files,
      mutationService: mutations,
      commandRunner: WorkCommandRunner(
        policy: WorkCommandPolicy(
          authorizedRoots: [authorizedDirectory.path],
          isWindows: false,
        ),
        processStarter: (_, {required env, required shell}) async {
          processStarts++;
          throw StateError('command runner must not be reached');
        },
      ),
    );
    final task = AgentTask(
      id: 'command-permission-task',
      groupId: 'command-permission-group',
      characterId: character.id,
      userRequest: '读取工作目录',
      // Simulate a stale or tampered task checkpoint that requests a capability
      // the active character never granted.
      requestedPermissions: const [ToolPermission.commandRun],
      assignedCharacterIds: const ['command-permission-character'],
      workModeTask: true,
    );

    await runner.run(task, WorkTaskCancellation());

    expect(task.status, AgentTaskStatus.paused);
    expect(task.lastError, contains('commandRun'));
    expect(task.pendingToolRequestJson, contains('command.run'));
    expect(processStarts, 0);
  });

  test(
      'approved missing command reaches tool-missing recovery instead of looping',
      () async {
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
    final mutations = WorkspaceMutationService(pathPolicy: pathPolicy);
    final config = ApiConfig(
      id: 'missing-command-config',
      name: 'Missing command test',
      provider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
    );
    final character = AICharacter(
      id: 'missing-command-character',
      name: '缺失工具角色',
      avatar: 'MT',
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
        ToolPermission.commandRun,
      ],
    );
    await database.apiConfigBox.put(config.id, config);
    await database.aiCharacterBox.put(character.id, character);
    final workspaceService = WorkModeWorkspaceService(
      db: database,
      grantService: grants,
    );
    var processStarts = 0;
    final commandRunner = WorkCommandRunner(
      policy: WorkCommandPolicy(
        authorizedRoots: [authorizedDirectory.path],
        isWindows: false,
      ),
      pathPolicy: pathPolicy,
      processStarter: (_, {required env, required shell}) async {
        processStarts++;
        throw const ProcessException(
          'insta',
          [],
          'No such file or directory',
          2,
        );
      },
    );
    final runner = DefaultWorkTaskRunner(
      database: database,
      eventStore: eventStore,
      credentials: _TestCredentials(),
      gateway: _MissingMutationCommandGateway(),
      workspaceService: workspaceService,
      folderGrantService: grants,
      workspaceFileService: files,
      mutationService: mutations,
      resourceLockManager: WorkResourceLockManager(isWindows: false),
      commandRunner: commandRunner,
    );
    final task = AgentTask(
      id: 'missing-command-task',
      groupId: 'missing-command-group',
      characterId: character.id,
      userRequest: 'insta',
      requestedPermissions: character.toolPermissions,
      assignedCharacterIds: const ['missing-command-character'],
      workModeTask: true,
    );

    await runner.run(task, WorkTaskCancellation());
    expect(task.status, AgentTaskStatus.waitingForApproval);
    expect(task.lastError, contains('影响范围不确定'));

    final checkpoint = Map<String, dynamic>.from(
      jsonDecode(task.executionStateJson) as Map,
    )..['approvalDecision'] = 'approvedWithoutUndo';
    task
      ..executionStateJson = jsonEncode(checkpoint)
      ..status = AgentTaskStatus.queued;
    await runner.run(task, WorkTaskCancellation());

    expect(task.status, AgentTaskStatus.paused);
    expect(task.lastError, contains('缺少工具'));
    expect(task.contextSummary, contains('toolMissing'));
    expect(processStarts, 1);
  });

  test('production read-only command runs with a read-only folder grant',
      () async {
    final grants = WorkFolderGrantService(
      box: database.appSettingsBox,
      directoryValidator: (_) async => true,
      writeDirectoryValidator: (_) async => false,
      isWindows: false,
    );
    expect(
      await grants.authorizeDirectory(
        authorizedDirectory.path,
        consent: (_) async => true,
      ),
      isNotNull,
    );
    final pathPolicy = WorkspacePathPolicy(grantService: grants);
    final files = WorkspaceFileService(pathPolicy: pathPolicy);
    final mutations = WorkspaceMutationService(pathPolicy: pathPolicy);
    final config = ApiConfig(
      id: 'readonly-command-config',
      name: 'Read-only command test',
      provider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
    );
    final character = AICharacter(
      id: 'readonly-command-character',
      name: '只读命令角色',
      avatar: 'RO',
      age: 30,
      role: '检查角色',
      personalityTags: const [],
      systemPrompt: '只按工具协议工作。',
      apiKey: '',
      apiProvider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
      apiConfigId: config.id,
      toolPermissions: const [
        ToolPermission.workspaceRead,
        ToolPermission.commandRun,
      ],
    );
    await database.apiConfigBox.put(config.id, config);
    await database.aiCharacterBox.put(character.id, character);

    var processStarts = 0;
    final runner = DefaultWorkTaskRunner(
      database: database,
      eventStore: eventStore,
      credentials: _TestCredentials(),
      gateway: _ReadOnlyCommandGateway(),
      workspaceService: WorkModeWorkspaceService(
        db: database,
        grantService: grants,
      ),
      folderGrantService: grants,
      workspaceFileService: files,
      mutationService: mutations,
      commandRunner: WorkCommandRunner(
        policy: WorkCommandPolicy(
          authorizedRoots: [authorizedDirectory.path],
          isWindows: false,
        ),
        processStarter: (_, {required env, required shell}) async {
          processStarts++;
          return WorkCommandProcess(
            pid: 10,
            stdout: Stream<List<int>>.value(utf8.encode('read-only\n')),
            stderr: const Stream<List<int>>.empty(),
            exitCode: Future<int>.value(0),
            terminateTree: ({bool force = false}) async {},
          );
        },
      ),
    );
    final task = AgentTask(
      id: 'readonly-command-task',
      groupId: 'readonly-command-group',
      characterId: character.id,
      userRequest: '查看当前工作目录',
      requestedPermissions: character.toolPermissions,
      assignedCharacterIds: const ['readonly-command-character'],
      workModeTask: true,
    );

    await runner.run(task, WorkTaskCancellation());

    expect(task.status, AgentTaskStatus.completed);
    expect(task.lastError, isEmpty);
    expect(processStarts, 1);
  });

  test(
      'sensitive mutation still asks for approval when ordinary prompts are off',
      () async {
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
    await grants.setOrdinaryWriteConfirmation(false);
    final pathPolicy = WorkspacePathPolicy(grantService: grants);
    final files = WorkspaceFileService(pathPolicy: pathPolicy);
    final snapshots = WorkSnapshotService(
      appSupportDirectory: Directory('${hiveDirectory.path}/support-sensitive'),
      pathPolicy: pathPolicy,
    );
    final mutations = WorkspaceMutationService(
      pathPolicy: pathPolicy,
      snapshotPort: snapshots,
    );
    final config = ApiConfig(
      id: 'sensitive-write-config',
      name: 'Sensitive write',
      provider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
    );
    final character = AICharacter(
      id: 'sensitive-write-character',
      name: '敏感写入角色',
      avatar: 'SW',
      age: 30,
      role: '开发工程师',
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
    final gateway = _SequencedGateway(
      patchPath: '.env',
      patchContent: 'sensitive-update',
      repeatToolOnSecondModelCall: true,
    );
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
      id: 'sensitive-write-task',
      groupId: 'sensitive-write-group',
      characterId: character.id,
      userRequest: '更新 .env',
      requestedPermissions: character.toolPermissions,
      assignedCharacterIds: [character.id],
      workModeTask: true,
    );

    await runner.run(task, WorkTaskCancellation());

    expect(task.status, AgentTaskStatus.waitingForApproval);
    expect(task.executionStateJson, contains('approvalPlan'));
    expect(task.executionStateJson, contains('sensitive'));

    final checkpoint = Map<String, dynamic>.from(
      jsonDecode(task.executionStateJson) as Map,
    )..['approvalDecision'] = 'approved';
    task
      ..executionStateJson = jsonEncode(checkpoint)
      ..status = AgentTaskStatus.queued;
    // Simulate a process restart: the new runner has no in-memory request and
    // must re-plan from the model instead of replaying the redacted checkpoint.
    final restartedRunner = DefaultWorkTaskRunner(
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
    await restartedRunner.run(task, WorkTaskCancellation());

    expect(task.status, AgentTaskStatus.completed);
    expect(task.lastError, isEmpty, reason: task.lastError);
    expect(gateway.calls, 3);
    expect(
      await File(
        '${authorizedDirectory.path}/conversations/group_sensitive-write-group/.env',
      ).readAsString(),
      'sensitive-update',
    );
  });

  test(
      'rejecting a sensitive read becomes a safe skip instead of an approval loop',
      () async {
    final grants = WorkFolderGrantService(
      box: database.appSettingsBox,
      directoryValidator: (_) async => true,
      isWindows: false,
    );
    await grants.authorizeDirectory(
      authorizedDirectory.path,
      consent: (_) async => true,
    );
    final pathPolicy = WorkspacePathPolicy(grantService: grants);
    final files = WorkspaceFileService(pathPolicy: pathPolicy);
    final mutations = WorkspaceMutationService(pathPolicy: pathPolicy);
    final config = ApiConfig(
      id: 'sensitive-read-config',
      name: 'Sensitive read',
      provider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
    );
    final character = AICharacter(
      id: 'sensitive-read-character',
      name: '敏感读取角色',
      avatar: 'SR',
      age: 30,
      role: '审计工程师',
      personalityTags: const [],
      systemPrompt: '只按工具协议工作。',
      apiKey: '',
      apiProvider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
      apiConfigId: config.id,
      toolPermissions: const [ToolPermission.workspaceRead],
    );
    await database.apiConfigBox.put(config.id, config);
    await database.aiCharacterBox.put(character.id, character);
    final workspaceService = WorkModeWorkspaceService(
      db: database,
      grantService: grants,
    );
    final workspace = await workspaceService.loadOrCreate(
      conversationId: 'sensitive-read-group',
      isDirectChat: false,
    );
    final sensitiveFile = File('${workspace.workDirPath}/.env');
    await sensitiveFile.writeAsString('TOKEN=do-not-expose');
    final gateway = _SensitiveGateway(
      toolName: 'workspace.read',
      arguments: const {'path': '.env'},
    );
    final runner = DefaultWorkTaskRunner(
      database: database,
      eventStore: eventStore,
      credentials: _TestCredentials(),
      gateway: gateway,
      workspaceService: workspaceService,
      folderGrantService: grants,
      workspaceFileService: files,
      mutationService: mutations,
    );
    final task = AgentTask(
      id: 'sensitive-read-task',
      groupId: 'sensitive-read-group',
      characterId: character.id,
      userRequest: '读取 .env',
      requestedPermissions: character.toolPermissions,
      assignedCharacterIds: [character.id],
      workModeTask: true,
    );

    await runner.run(task, WorkTaskCancellation());
    expect(task.status, AgentTaskStatus.waitingForApproval);
    task.executionStateJson = jsonEncode({
      ...Map<String, dynamic>.from(jsonDecode(task.executionStateJson) as Map),
      'approvalDecision': 'rejected',
    });
    task.status = AgentTaskStatus.queued;
    await runner.run(task, WorkTaskCancellation());

    expect(task.status, AgentTaskStatus.completed);
    expect(gateway.calls, 2);
    expect(task.executionStateJson, isNot(contains('approvalDecision')));
    expect(task.contextSummary, isNot(contains('do-not-expose')));
  });
}

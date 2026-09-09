import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/models/api_protocol.dart';
import 'package:chat_group/core/models/character_memory.dart';
import 'package:chat_group/core/models/character_skill.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/group_memory.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/permanent_memory.dart';
import 'package:chat_group/core/models/relationship_event.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/core/models/tool_permission.dart';
import 'package:chat_group/core/streaming/chat_stream_event.dart';
import 'package:chat_group/core/models/user_profile.dart';
import 'package:chat_group/core/models/work_mode_workspace.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/ai_governance/ai_request_gateway.dart';
import 'package:chat_group/features/chat_group/chat_room_page.dart';
import 'package:chat_group/features/work_mode/default_work_task_runner.dart';
import 'package:chat_group/features/work_mode/presentation/work_task_overlay_host.dart';
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
import 'package:chat_group/providers/providers.dart';
import 'package:chat_group/services/chat_api_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import '../helpers/memory_governance_store.dart';

class _Credentials implements ApiCredentialResolver {
  @override
  Future<String?> resolve(ApiConfig config) async => 'ui-test-key';
}

/// A synchronous in-memory box keeps this widget integration test focused on
/// the chat/role/folder UI rather than Hive's asynchronous disk flushes.
class _MemoryBox<T> implements Box<T> {
  final String _name;
  final Map<dynamic, T> _values = <dynamic, T>{};
  final StreamController<BoxEvent> _events =
      StreamController<BoxEvent>.broadcast();
  var _nextIntegerKey = 0;

  _MemoryBox(this._name);

  @override
  String get name => _name;
  @override
  bool get isOpen => true;
  @override
  String? get path => null;
  @override
  bool get lazy => false;
  @override
  Iterable<dynamic> get keys => _values.keys;
  @override
  int get length => _values.length;
  @override
  bool get isEmpty => _values.isEmpty;
  @override
  bool get isNotEmpty => _values.isNotEmpty;
  @override
  dynamic keyAt(int index) => _values.keys.elementAt(index);
  @override
  Stream<BoxEvent> watch({dynamic key}) => key == null
      ? _events.stream
      : _events.stream.where((event) => event.key == key);
  @override
  bool containsKey(dynamic key) => _values.containsKey(key);

  @override
  Future<void> put(dynamic key, dynamic value) {
    _values[key] = value as T;
    _events.add(BoxEvent(key, value, false));
    return Future<void>.value();
  }

  @override
  Future<void> putAt(int index, dynamic value) {
    final key = keyAt(index);
    return put(key, value);
  }

  @override
  Future<void> putAll(Map<dynamic, dynamic> entries) =>
      Future.wait(entries.entries.map((entry) => put(entry.key, entry.value)));
  @override
  Future<int> add(dynamic value) async {
    while (_values.containsKey(_nextIntegerKey)) {
      _nextIntegerKey++;
    }
    final key = _nextIntegerKey++;
    await put(key, value);
    return key;
  }

  @override
  Future<Iterable<int>> addAll(Iterable<dynamic> values) =>
      Future.wait(values.map(add));
  @override
  Future<void> delete(dynamic key) async {
    if (!_values.containsKey(key)) return;
    _values.remove(key);
    _events.add(BoxEvent(key, null, true));
  }

  @override
  Future<void> deleteAt(int index) => delete(keyAt(index));
  @override
  Future<void> deleteAll(Iterable<dynamic> keys) =>
      Future.wait(keys.map(delete));
  @override
  Future<int> clear() async {
    final count = _values.length;
    final keysToDelete = List<dynamic>.from(_values.keys);
    await deleteAll(keysToDelete);
    return count;
  }

  @override
  Future<void> compact() async {}
  @override
  Future<void> close() => Future<void>.value();
  @override
  Future<void> deleteFromDisk() => clear();
  @override
  Future<void> flush() => Future<void>.value();
  @override
  Iterable<T> get values => _values.values;
  @override
  Iterable<T> valuesBetween({dynamic startKey, dynamic endKey}) =>
      _values.entries
          .where((entry) =>
              (startKey == null || entry.key.compareTo(startKey) >= 0) &&
              (endKey == null || entry.key.compareTo(endKey) <= 0))
          .map((entry) => entry.value);
  @override
  T? get(dynamic key, {T? defaultValue}) => _values[key] ?? defaultValue;
  @override
  T? getAt(int index) => _values[keyAt(index)];
  @override
  Map<dynamic, T> toMap() => Map<dynamic, T>.from(_values);
}

class _MemoryDatabaseService extends DatabaseService {
  final _characters = _MemoryBox<AICharacter>('ai_characters');
  final _configs = _MemoryBox<ApiConfig>('api_configs');
  final _groups = _MemoryBox<ChatGroup>('chat_groups');
  final _messages = _MemoryBox<Message>('messages');
  final _groupMemories = _MemoryBox<GroupMemory>('group_memories');
  final _characterMemories = _MemoryBox<CharacterMemory>('character_memories');
  final _relationships = _MemoryBox<RelationshipState>('relationship_states');
  final _skills = _MemoryBox<CharacterSkill>('character_skills');
  final _tasks = _MemoryBox<AgentTask>('agent_tasks');
  final _workspaces = _MemoryBox<WorkModeWorkspace>('work_mode_workspaces');
  final _settings = _MemoryBox<dynamic>('app_settings');
  final _profiles = _MemoryBox<UserProfile>('user_profile');
  final _permanent = _MemoryBox<PermanentMemory>('permanent_memories');
  final _relationshipEvents =
      _MemoryBox<RelationshipEvent>('relationship_events');

  @override
  Box<AICharacter> get aiCharacterBox => _characters;
  @override
  Box<ApiConfig> get apiConfigBox => _configs;
  @override
  Box<ChatGroup> get chatGroupBox => _groups;
  @override
  Box<Message> get messageBox => _messages;
  @override
  Box<GroupMemory> get groupMemoryBox => _groupMemories;
  @override
  Box<CharacterMemory> get characterMemoryBox => _characterMemories;
  @override
  Box<RelationshipState> get relationshipStateBox => _relationships;
  @override
  Box<CharacterSkill> get characterSkillBox => _skills;
  @override
  Box<AgentTask> get agentTaskBox => _tasks;
  @override
  Box<WorkModeWorkspace> get workModeWorkspaceBox => _workspaces;
  @override
  Box<dynamic> get appSettingsBox => _settings;
  @override
  Box<UserProfile> get userProfileBox => _profiles;
  @override
  Box<PermanentMemory> get permanentMemoryBox => _permanent;
  @override
  Box<RelationshipEvent> get relationshipEventBox => _relationshipEvents;
}

class _RouteApi extends ChatApiService {
  int calls = 0;

  @override
  Future<Map<String, dynamic>> sendChatMessageWithResponseLimit({
    required String apiKey,
    required ApiProvider provider,
    ApiProtocol apiProtocol = ApiProtocol.defaultValue,
    String? customBaseUrl,
    required String model,
    required List<Map<String, dynamic>> messages,
    double temperature = 0.85,
    int maxTokens = 1024,
    Duration? receiveTimeout,
    int maxRetries = 5,
    CancelToken? cancelToken,
    bool requiresTools = false,
    bool userInitiated = false,
    void Function(ChatStreamEvent event)? onEvent,
    required int maxResponseBytes,
  }) async {
    calls++;
    return {
      'success': true,
      'message': jsonEncode({
        'characterId': 'ui-worker',
        'publicReason': '该角色负责执行当前工作指令。',
        'confidence': 0.95,
        'needsHandoff': false,
      }),
    };
  }
}

class _UiWorkGateway extends AiRequestGateway {
  int calls = 0;

  _UiWorkGateway()
      : super(
          store: MemoryGovernanceStore(),
          client: ChatApiService(),
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
    final decision = calls == 1
        ? {
            'action': 'tool',
            'public_update': '正在读取已授权工作目录。',
            'tool': {
              'name': 'workspace.list',
              'arguments': {'path': '.', 'page': 0, 'pageSize': 20},
            },
            'completion': null,
          }
        : {
            'action': 'finish',
            'public_update': '目录读取完成并核对结果。',
            'tool': null,
            'completion': {
              'summary': '已通过聊天入口读取并核对授权目录。',
              'evidence': ['目录列表已返回'],
            },
          };
    return {'success': true, 'message': jsonEncode(decision)};
  }
}

class _MemoryEventStore extends WorkTaskEventStore {
  final Map<String, List<WorkTaskEvent>> _events =
      <String, List<WorkTaskEvent>>{};

  _MemoryEventStore() : super(appSupportDirectory: Directory.systemTemp);

  @override
  Future<WorkTaskEvent> append({
    required String taskId,
    required WorkTaskEventKind kind,
    required String title,
    String detail = '',
    int? progressCurrent,
    int? progressTotal,
    Map<String, dynamic>? safeMetadata,
    DateTime? timestamp,
  }) async {
    final events = _events.putIfAbsent(taskId, () => <WorkTaskEvent>[]);
    final event = WorkTaskEvent(
      taskId: taskId,
      sequence: events.length + 1,
      timestamp: timestamp ?? DateTime.now(),
      kind: kind,
      title: title,
      detail: detail,
      progressCurrent: progressCurrent,
      progressTotal: progressTotal,
      safeMetadata: safeMetadata ?? const <String, dynamic>{},
    );
    events.add(event);
    return event;
  }

  @override
  Future<WorkTaskEventReadResult> read(String taskId) async {
    return WorkTaskEventReadResult(
      events: List<WorkTaskEvent>.from(_events[taskId] ?? const []),
      issues: const [],
    );
  }

  @override
  Stream<WorkTaskEvent> watch(String taskId) async* {
    yield* Stream<WorkTaskEvent>.fromIterable(_events[taskId] ?? const []);
  }

  @override
  Future<void> close() async {}
}

Future<AgentTask> _waitForTask(
  DatabaseService database,
  String taskId,
  bool Function(AgentTask task) predicate,
) async {
  for (var attempt = 0; attempt < 120; attempt++) {
    final task = database.agentTaskBox.get(taskId);
    if (task != null && predicate(task)) return task;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  throw StateError('任务未在限定时间内达到预期状态：$taskId');
}

Future<void> _pumpUntil(
  WidgetTester tester,
  Finder finder, {
  int maxFrames = 80,
}) async {
  for (var frame = 0; frame < maxFrames; frame++) {
    if (finder.evaluate().isNotEmpty) return;
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  expect(finder, findsOneWidget);
}

void main() {
  late Directory hiveDirectory;
  late Directory authorizedDirectory;
  late DatabaseService database;
  late WorkTaskEventStore eventStore;
  late WorkTaskCoordinator coordinator;

  setUp(() async {
    hiveDirectory =
        await Directory.systemTemp.createTemp('chat_group_ui_test_');
    Hive.init(hiveDirectory.path);
    await Hive.openBox<dynamic>(DatabaseService.aiGovernanceLedgerBoxName);
    database = _MemoryDatabaseService();
    eventStore = _MemoryEventStore();
    authorizedDirectory =
        await Directory('${hiveDirectory.path}/authorized').create();
  });

  tearDown(() async {
    await coordinator.dispose();
    await eventStore.close();
    if (await hiveDirectory.exists()) {
      await hiveDirectory.delete(recursive: true);
    }
  });

  testWidgets(
      'chat input routes a work task and completes after folder authorization UI',
      (tester) async {
    const groupId = 'ui-work-group';
    final config = ApiConfig(
      id: 'ui-config',
      name: 'UI test config',
      provider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
      hasCredential: true,
    );
    final character = AICharacter(
      id: 'ui-worker',
      name: '开发角色',
      avatar: 'D',
      age: 30,
      role: '开发工程师',
      personalityTags: const [],
      systemPrompt: '负责执行工作任务',
      apiKey: '',
      apiProvider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
      apiConfigId: config.id,
      toolPermissions: const [ToolPermission.workspaceRead],
    );
    await tester.runAsync(() async {
      await database.apiConfigBox.put(config.id, config);
      await database.aiCharacterBox.put(character.id, character);
      await database.chatGroupBox.put(
        groupId,
        ChatGroup(
          id: groupId,
          name: '工作入口测试群',
          theme: '工作模式测试',
          aiCharacterIds: [character.id],
        ),
      );
    });

    final grants = WorkFolderGrantService(
      box: database.appSettingsBox,
      directoryValidator: (_) async => true,
      writeDirectoryValidator: (_) async => true,
      isWindows: false,
    );
    await tester.runAsync(() => grants.load());
    var pickerCalls = 0;
    final pathPolicy =
        WorkspacePathPolicy(grantService: grants, isWindows: false);
    final files = WorkspaceFileService(pathPolicy: pathPolicy);
    final snapshots = WorkSnapshotService(
      appSupportDirectory: Directory('${hiveDirectory.path}/snapshots'),
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
    final gateway = _UiWorkGateway();
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
    coordinator = WorkTaskCoordinator(
      taskBox: database.agentTaskBox,
      eventStore: eventStore,
      runner: runner,
      folderGrantService: grants,
      folderPicker: () async {
        pickerCalls++;
        return pickerCalls == 1 ? null : authorizedDirectory.path;
      },
      requireFolderGrant: true,
      resourceLockManager: WorkResourceLockManager(isWindows: false),
    );
    final routeApi = _RouteApi();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseServiceProvider.overrideWithValue(database),
          workTaskEventStoreProvider.overrideWithValue(eventStore),
          workTaskCoordinatorProvider.overrideWithValue(coordinator),
        ],
        child: MaterialApp(
          home: WorkTaskOverlayHost(
            coordinator: coordinator,
            eventStore: eventStore,
            child: ChatRoomPage(
              groupId: groupId,
              chatApi: routeApi,
              credentialResolver: _Credentials(),
            ),
          ),
        ),
      ),
    );
    await _pumpUntil(tester, find.byType(TextField));
    await tester.tap(find.byKey(const Key('work-mode-toggle')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    expect(
      find.byTooltip('工作模式已开启 · 敏感操作需确认'),
      findsOneWidget,
    );
    await tester.enterText(find.byType(TextField), '读取工作目录');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));

    await _pumpUntil(tester, find.byKey(const Key('work-task-add-folder')));
    for (var attempt = 0; attempt < 20; attempt++) {
      final tasks = database.agentTaskBox.values;
      final waitingForInitialPicker = tasks.any(
        (task) => task.status == AgentTaskStatus.paused,
      );
      if (pickerCalls >= 1 && waitingForInitialPicker) break;
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
    }

    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('work-task-add-folder')));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await _pumpUntil(
      tester,
      find.byKey(const Key('work-folder-grant-consent-confirm')),
    );
    await tester.runAsync(() async {
      await tester.tap(
        find.byKey(const Key('work-folder-grant-consent-confirm')),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump();
    final completedTask = (await tester.runAsync(
      () => _waitForTask(
        database,
        database.agentTaskBox.values.single.id,
        (task) => task.status == AgentTaskStatus.completed,
      ),
    ))!;
    expect(completedTask.userRequest, '读取工作目录');
    expect(completedTask.characterId, 'ui-worker');
    expect(completedTask.lastError, isEmpty);
    expect(
      completedTask.completedOperations,
      anyElement(contains('workspace.list')),
    );
    expect(routeApi.calls, 1);
    expect(pickerCalls, 2);
    expect(gateway.calls, 2);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.runAsync(() async {
      await coordinator.dispose();
      await eventStore.close();
    });
  }, timeout: const Timeout(Duration(seconds: 20)));
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/models/api_protocol.dart';
import 'package:chat_group/core/streaming/chat_stream_event.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/ai_governance/ai_request_gateway.dart';
import 'package:chat_group/features/work_mode/default_work_task_runner.dart';
import 'package:chat_group/features/work_mode/weather_forecast_service.dart';
import 'package:chat_group/features/work_mode/work_folder_grant_service.dart';
import 'package:chat_group/features/work_mode/work_mode_workspace_service.dart';
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

class _TestCredentials implements ApiCredentialResolver {
  @override
  Future<String?> resolve(ApiConfig config) async => 'test-key';
}

class _WeatherGateway extends AiRequestGateway {
  _WeatherGateway()
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
        'public_update': '正在查询天气。',
        'tool': {
          'name': 'weather.forecast',
          'arguments': {'location': '上海', 'days': 7},
        },
        'completion': null,
      }),
    };
  }
}

class _BlockingWeatherForecastService extends WeatherForecastService {
  final Completer<void> started = Completer<void>();
  final Completer<WeatherForecast> release = Completer<WeatherForecast>();
  CancelToken? receivedCancelToken;

  _BlockingWeatherForecastService() : super(prepareEndpoint: (_, __) async {});

  @override
  Future<WeatherForecast> fetch({
    String? location,
    int days = WeatherForecastService.maxDays,
    CancelToken? cancelToken,
  }) async {
    receivedCancelToken = cancelToken;
    started.complete();
    if (cancelToken == null) return release.future;
    await cancelToken.whenCancel;
    throw const WeatherForecastException('天气查询已取消。');
  }
}

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

  test('cancels an in-flight weather lookup with the task stop signal',
      () async {
    final grants = WorkFolderGrantService(
      box: database.appSettingsBox,
      directoryValidator: (_) async => true,
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
    );
    final mutations = WorkspaceMutationService(
      pathPolicy: pathPolicy,
      snapshotPort: snapshots,
    );
    final config = ApiConfig(
      id: 'weather-cancel-config',
      name: 'Weather cancellation test config',
      provider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
    );
    final character = AICharacter(
      id: 'weather-cancel-character',
      name: 'Weather cancellation character',
      avatar: 'W',
      age: 30,
      role: '测试执行角色',
      personalityTags: const [],
      systemPrompt: '只按工具协议工作。',
      apiKey: '',
      apiProvider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
      apiConfigId: config.id,
    );
    await database.apiConfigBox.put(config.id, config);
    await database.aiCharacterBox.put(character.id, character);

    final weather = _BlockingWeatherForecastService();
    final runner = DefaultWorkTaskRunner(
      database: database,
      eventStore: eventStore,
      credentials: _TestCredentials(),
      gateway: _WeatherGateway(),
      weatherForecastService: weather,
      workspaceService: WorkModeWorkspaceService(
        db: database,
        grantService: grants,
      ),
      folderGrantService: grants,
      workspaceFileService: files,
      mutationService: mutations,
    );
    final task = AgentTask(
      id: 'weather-cancel-task',
      groupId: 'weather-cancel-group',
      characterId: character.id,
      userRequest: '帮我生成一份MD文档，记录未来7天的天气',
      workModeTask: true,
    );
    final cancellation = WorkTaskCancellation();
    final runFuture = runner.run(task, cancellation);

    await weather.started.future.timeout(const Duration(seconds: 2));
    cancellation.cancel();
    var timedOut = false;
    try {
      await runFuture.timeout(const Duration(milliseconds: 500));
    } on TimeoutException {
      timedOut = true;
      weather.release.complete(_forecast());
    }
    await runFuture;

    expect(timedOut, isFalse);
    expect(weather.receivedCancelToken, isNotNull);
    expect(task.status, AgentTaskStatus.interrupted);
  });
}

const _forecastDay = WeatherForecastDay(
  date: '2026-09-11',
  condition: '晴朗',
  weatherCode: 0,
  highCelsius: 27,
  lowCelsius: 19,
  precipitationProbability: 0,
  maxWindSpeedKmh: 12,
);

WeatherForecast _forecast() => const WeatherForecast(
      location: '上海',
      timezone: 'Asia/Shanghai',
      days: [_forecastDay],
    );

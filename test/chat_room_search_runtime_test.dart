import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/features/ai_governance/ai_governance_store.dart';
import 'package:chat_group/features/ai_governance/ai_request_gateway.dart';
import 'package:chat_group/features/chat_group/chat_room_search_runtime.dart';
import 'package:chat_group/features/web_search/data/search_settings_store.dart';
import 'package:chat_group/features/web_search/models/search_runtime_settings.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/lifecycle_hive.dart';

class _RecordingCredentialResolver implements ApiCredentialResolver {
  ApiConfig? lastConfig;

  @override
  Future<String?> resolve(ApiConfig config) async {
    lastConfig = config;
    return '${config.provider}-key';
  }
}

void main() {
  late Directory directory;
  late DatabaseService db;

  setUp(() async {
    directory = await openLifecycleHive();
    db = DatabaseService();
  });

  tearDown(() => closeLifecycleHive(directory, db));

  test('rebuilds native and planner routes after AI config changes', () async {
    const configId = 'chat-search-ai-config';
    final qwenConfig = ApiConfig(
      id: configId,
      name: '聊天 AI',
      provider: ApiProvider.qwen.name,
      modelName: 'qwen-plus',
      credentialId: 'credential.api-config.$configId',
      hasCredential: true,
    );
    final character = AICharacter(
      id: 'chat-search-character',
      name: '搜索角色',
      avatar: '搜',
      age: 20,
      role: '测试角色',
      personalityTags: const [],
      systemPrompt: 'test',
      apiKey: '',
      apiProvider: ApiProvider.qwen.name,
      modelName: 'qwen-plus',
      apiConfigId: configId,
    );
    await db.apiConfigBox.put(configId, qwenConfig);
    await db.aiCharacterBox.put(character.id, character);
    final settingsStore = SearchProviderConfigStore(db: db);
    await settingsStore.saveRuntimeSettings(
      const SearchRuntimeSettings(
        nativeSearchEnabled: true,
        queryPlanningEnabled: true,
      ),
    );

    final resolver = _RecordingCredentialResolver();
    final governance = AiGovernanceStore.forDatabase(db);
    final controller = ChatRoomSearchRuntimeController(
      conversationId: 'group-1',
      governanceStore: governance,
      aiGateway: AiRequestGateway(store: governance),
      credentialResolver: resolver,
      allCharacters: () => db.aiCharacterBox.values,
      resolveApiConfig: (value) => db.apiConfigBox.get(value.apiConfigId),
    );
    addTearDown(controller.dispose);

    controller.initialize();
    expect(controller.coordinator.providerRoutes.first.id,
        'native:qwen:qwen-plus');
    expect(
        controller.coordinator.queryPlanner?.config.provider, ApiProvider.qwen);
    expect(
      await controller.coordinator.queryPlanner?.config.resolveApiKey?.call(),
      'qwen-key',
    );
    expect(resolver.lastConfig?.provider, ApiProvider.qwen.name);

    final deepSeekConfig = ApiConfig(
      id: configId,
      name: '聊天 AI',
      provider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
      customBaseUrl: 'https://api.deepseek.com',
      credentialId: 'credential.api-config.$configId',
      hasCredential: true,
    );
    await db.apiConfigBox.put(configId, deepSeekConfig);

    controller.reloadIfChanged(isBusy: false);

    expect(controller.coordinator.providerRoutes.first.id,
        'builtin-duckduckgo-fallback');
    expect(controller.coordinator.queryPlanner?.config.provider,
        ApiProvider.deepseek);
    expect(controller.coordinator.queryPlanner?.config.model, 'deepseek-chat');
    expect(controller.coordinator.queryPlanner?.config.customBaseUrl,
        'https://api.deepseek.com');
    expect(
      await controller.coordinator.queryPlanner?.config.resolveApiKey?.call(),
      'deepseek-key',
    );
    expect(resolver.lastConfig?.provider, ApiProvider.deepseek.name);
  });
}

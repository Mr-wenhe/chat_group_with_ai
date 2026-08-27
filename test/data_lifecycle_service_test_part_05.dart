part of 'data_lifecycle_service_test.dart';

void _registerDataLifecycleServiceTestPart5() {
  test(
      'API config deletion fails closed when credential storage is unavailable',
      () async {
    service = DataLifecycleService(
      db: db,
      managedMediaDirectory: mediaDirectory,
      credentials: CredentialRepository(
        store: credentialStore,
        legacyStorage: MemoryLegacyCredentialStore(),
        secureStorageAvailable: false,
      ),
      clearExternalSettings: () async {},
    );
    await db.apiConfigBox.put(
      'unavailable',
      ApiConfig(
        id: 'unavailable',
        name: 'Unavailable',
        provider: 'deepseek',
        hasCredential: true,
      ),
    );

    final result = await service.deleteApiConfig('unavailable');

    expect(result.isComplete, isFalse);
    expect(result.incompleteItems, contains('API 凭据删除失败'));
    expect(db.apiConfigBox.containsKey('unavailable'), isTrue);
    expect(service.hasPendingOperation, isTrue);
  });

  test('clear scopes preserve only their documented preference set', () async {
    final attachment = File('${mediaDirectory.path}/chat.txt');
    await attachment.writeAsString('chat');
    final character = testCharacter('c1')..memorySummary = 'remember';
    final config = ApiConfig(
      id: 'a1',
      name: 'api',
      provider: 'deepseek',
      hasCredential: true,
    );
    await db.aiCharacterBox.put('c1', character);
    await db.apiConfigBox.put('a1', config);
    credentialStore.values[service.credentials.credentialIdFor('a1')] =
        'secret';
    await db.chatGroupBox.put(
      'g1',
      ChatGroup(id: 'g1', name: 'group', theme: '', aiCharacterIds: ['c1']),
    );
    await db.characterSkillBox.put(
      's1',
      CharacterSkill(
        id: 's1',
        characterId: 'c1',
        name: 'skill',
        domain: 'test',
        description: '',
        instructions: const [],
        requiredPermissions: const [],
      ),
    );
    await db.userProfileBox.put(
      'me',
      UserProfile(
        displayName: '用户',
        preferredAddress: '你',
        avatar: '我',
        bio: 'profile',
      ),
    );
    await db.permanentMemoryBox.put(
      'pm-g1',
      testPermanentMemory(id: 'pm-g1', originConversationId: 'g1'),
    );
    final globalId = RelationshipState.stableGlobalId(
      'c1',
      RelationshipTargetType.user,
      'user',
    );
    await db.relationshipEventBox.put(
      'event-g1',
      testRelationshipEvent(
        id: 'event-g1',
        sourceCharacterId: 'c1',
        targetType: RelationshipTargetType.user,
        targetId: 'user',
        originConversationId: 'g1',
        revision: 1,
        affinityAfter: 3,
      ),
    );
    await db.relationshipStateBox.putAll({
      'legacy-g1': RelationshipState(
        id: 'legacy-g1',
        groupId: 'g1',
        sourceCharacterId: 'c1',
        targetId: 'user',
        targetType: RelationshipTargetType.user,
      ),
      globalId: RelationshipState.global(
        id: globalId,
        sourceCharacterId: 'c1',
        targetType: RelationshipTargetType.user,
        targetId: 'user',
        affinity: 3,
        revision: 1,
        lastEventId: 'event-g1',
      ),
    });
    await db.messageBox.put(
      'm1',
      Message(
        id: 'm1',
        groupId: 'g1',
        senderId: 'c1',
        senderType: 'ai',
        content: 'chat',
        media: [MediaAttachment(type: 'file', localPath: attachment.path)],
      ),
    );
    await db.appSettingsBox.putAll({
      'theme_mode': 'light',
      DatabaseService.appSkinModeKey: 'golden',
      'tts_enabled': false,
      'ai_processing_dir': '/user/workspace',
      'pinned_group_ids': ['g1'],
      'work_mode_enabled:g1': true,
      'message_ids_by_group': {
        'g1': ['m1']
      },
    });

    expect(
        (await service.clear(DataClearScope.chatContent)).isComplete, isTrue);
    expect(db.messageBox.isEmpty, isTrue);
    expect(db.aiCharacterBox.get('c1')!.memorySummary, isEmpty);
    expect(db.aiCharacterBox.length, 1);
    expect(db.chatGroupBox.length, 1);
    expect(db.apiConfigBox.length, 1);
    expect(db.characterSkillBox.length, 1);
    expect(db.permanentMemoryBox.containsKey('pm-g1'), isTrue);
    expect(db.relationshipEventBox.containsKey('event-g1'), isTrue);
    expect(db.relationshipStateBox.containsKey(globalId), isTrue);
    expect(db.relationshipStateBox.containsKey('legacy-g1'), isFalse);
    expect(db.userProfileBox.containsKey('me'), isTrue);
    expect(credentialStore.values, isNotEmpty);
    expect(db.appSettingsBox.get('theme_mode'), 'light');
    expect(db.appSettingsBox.get('tts_enabled'), isFalse);
    expect(db.appSettingsBox.get('pinned_group_ids'), ['g1']);
    expect(db.appSettingsBox.containsKey('work_mode_enabled:g1'), isFalse);
    expect(await attachment.exists(), isFalse);

    expect(
        (await service.clear(DataClearScope.userContent)).isComplete, isTrue);
    expect(db.aiCharacterBox.isEmpty, isTrue);
    expect(db.chatGroupBox.isEmpty, isTrue);
    expect(db.apiConfigBox.isEmpty, isTrue);
    expect(db.characterSkillBox.isEmpty, isTrue);
    expect(db.permanentMemoryBox.isEmpty, isTrue);
    expect(db.relationshipEventBox.isEmpty, isTrue);
    expect(db.relationshipStateBox.isEmpty, isTrue);
    expect(db.userProfileBox.isEmpty, isTrue);
    expect(credentialStore.values, isEmpty);
    expect(db.appSettingsBox.get('theme_mode'), 'light');
    expect(db.appSettingsBox.get('tts_enabled'), isFalse);
    expect(db.appSettingsBox.get('ai_processing_dir'), '/user/workspace');
    expect(db.appSettingsBox.containsKey('pinned_group_ids'), isFalse);

    await Hive.close();
    await reopenLifecycleHive(hiveDirectory);
    expect(db.aiCharacterBox.isEmpty, isTrue);
    expect(db.chatGroupBox.isEmpty, isTrue);
    expect(db.messageBox.isEmpty, isTrue);
    expect(db.permanentMemoryBox.isEmpty, isTrue);
    expect(db.relationshipEventBox.isEmpty, isTrue);
    expect(db.relationshipStateBox.isEmpty, isTrue);
    expect(db.userProfileBox.isEmpty, isTrue);

    expect(
        (await service.clear(DataClearScope.factoryReset)).isComplete, isTrue);
    expect(db.appSettingsBox.isEmpty, isTrue);
    expect(
        (await service.clear(DataClearScope.factoryReset)).isComplete, isTrue);
  });

  test('search lifecycle clears cache, audit, policy, config, and credentials',
      () async {
    final searchCredentials = SearchCredentialRepository(
      store: credentialStore,
      secureStorageAvailable: true,
    );
    final searchSettings = SearchProviderConfigStore(
      box: db.appSettingsBox,
      credentials: searchCredentials,
      isRelease: true,
    );
    service = DataLifecycleService(
      db: db,
      managedMediaDirectory: mediaDirectory,
      credentials: testCredentials(credentialStore),
      searchProviderConfigStore: searchSettings,
      clearExternalSettings: () async {},
    );
    await db.appSettingsBox.put(SearchProviderConfigStore.configsKey, [
      {
        'id': 'search-1',
        'name': 'Brave',
        'provider': 'brave',
        'baseUrl': 'https://search.example.com',
        'credentialId': searchCredentials.credentialIdFor('search-1'),
        'hasCredential': true,
        'credentialRequired': true,
      },
    ]);
    await db.appSettingsBox.put(SearchProviderConfigStore.resultCacheKey, [
      {'url': 'https://search.example.com/cached'},
    ]);
    await db.appSettingsBox.put(AiGovernanceStore.globalSearchPolicyKey, 'ask');
    await db.appSettingsBox.put(
      AiGovernanceStore.conversationSearchPoliciesKey,
      {'group-1': 'auto'},
    );
    await db.appSettingsBox.put(AiGovernanceStore.searchAuditKey, [
      SearchAuditEntry(
        conversationId: 'group-1',
        query: 'safe query',
        searchedAt: DateTime.now().toUtc(),
        status: 'completed',
        sources: const [],
      ).toMap(),
    ]);
    credentialStore.values[searchCredentials.credentialIdFor('search-1')] =
        'search-secret';

    final result = await service.clear(DataClearScope.userContent);

    expect(result.isComplete, isTrue);
    expect(
      db.appSettingsBox.get(SearchProviderConfigStore.configsKey),
      isNull,
    );
    expect(
      db.appSettingsBox.get(SearchProviderConfigStore.resultCacheKey),
      isNull,
    );
    expect(
      db.appSettingsBox.get(AiGovernanceStore.searchAuditKey),
      isNull,
    );
    expect(
      db.appSettingsBox.get(AiGovernanceStore.globalSearchPolicyKey),
      isNull,
    );
    expect(credentialStore.values, isEmpty);
  });

  test('search credential deletion failure keeps config for retry', () async {
    final searchCredentials = SearchCredentialRepository(
      store: credentialStore,
      secureStorageAvailable: true,
    );
    final searchSettings = SearchProviderConfigStore(
      box: db.appSettingsBox,
      credentials: searchCredentials,
      isRelease: true,
    );
    service = DataLifecycleService(
      db: db,
      managedMediaDirectory: mediaDirectory,
      credentials: testCredentials(credentialStore),
      searchProviderConfigStore: searchSettings,
      clearExternalSettings: () async {},
    );
    await db.appSettingsBox.put(SearchProviderConfigStore.configsKey, [
      {
        'id': 'search-1',
        'name': 'Brave',
        'provider': 'brave',
        'baseUrl': 'https://search.example.com',
        'credentialId': searchCredentials.credentialIdFor('search-1'),
        'hasCredential': true,
      },
    ]);
    credentialStore.values[searchCredentials.credentialIdFor('search-1')] =
        'search-secret';
    credentialStore.failNextDelete = true;

    final first = await service.clear(DataClearScope.userContent);

    expect(first.isComplete, isFalse);
    expect(service.hasPendingOperation, isTrue);
    expect(searchSettings.findById('search-1'), isNotNull);
    expect(credentialStore.values, isNotEmpty);

    final retry = await service.retryPendingOperation();

    expect(retry.isComplete, isTrue);
    expect(service.hasPendingOperation, isFalse);
    expect(searchSettings.findById('search-1'), isNull);
    expect(credentialStore.values, isEmpty);
  });

  test('lifecycle retries an orphaned search credential repair marker',
      () async {
    final searchCredentials = SearchCredentialRepository(
      store: credentialStore,
      secureStorageAvailable: true,
    );
    final searchSettings = SearchProviderConfigStore(
      box: db.appSettingsBox,
      credentials: searchCredentials,
      isRelease: true,
    );
    service = DataLifecycleService(
      db: db,
      managedMediaDirectory: mediaDirectory,
      credentials: testCredentials(credentialStore),
      searchProviderConfigStore: searchSettings,
      clearExternalSettings: () async {},
    );
    final credentialId = searchCredentials.credentialIdFor('orphan-repair');
    await db.appSettingsBox.put(
      SearchProviderConfigStore.credentialRepairKey,
      {
        'orphan-repair': {
          'configId': 'orphan-repair',
          'credentialId': credentialId,
          'operation': 'delete',
        },
      },
    );
    credentialStore.values[credentialId] = 'orphan-secret';

    final result = await service.clear(DataClearScope.userContent);

    expect(result.isComplete, isTrue);
    expect(credentialStore.values, isEmpty);
    expect(
      db.appSettingsBox.get(SearchProviderConfigStore.credentialRepairKey),
      isNull,
    );
  });

  test('malformed search metadata is retained as an incomplete clear',
      () async {
    final searchSettings = SearchProviderConfigStore(
      box: db.appSettingsBox,
      credentials: SearchCredentialRepository(
        store: credentialStore,
        secureStorageAvailable: true,
      ),
      isRelease: true,
    );
    service = DataLifecycleService(
      db: db,
      managedMediaDirectory: mediaDirectory,
      credentials: testCredentials(credentialStore),
      searchProviderConfigStore: searchSettings,
      clearExternalSettings: () async {},
    );
    await db.appSettingsBox.put(SearchProviderConfigStore.configsKey, [
      {
        'id': '',
        'name': 'Malformed',
        'provider': 'brave',
        'baseUrl': 'https://search.example.com',
        'credentialId': 'credential.web-search.',
        'hasCredential': true,
      },
    ]);

    final result = await service.clear(DataClearScope.userContent);

    expect(result.isComplete, isFalse);
    expect(result.incompleteItems, contains('搜索配置清理失败'));
    expect(
      db.appSettingsBox.get(SearchProviderConfigStore.configsKey),
      isNotNull,
    );
    expect(service.hasPendingOperation, isTrue);
  });
}

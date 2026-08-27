part of 'data_lifecycle_service.dart';

extension _DataLifecycleServiceClear on DataLifecycleService {
  Future<DataLifecycleResult> _runClear(
    DataClearScope scope,
    DeletionTargets targets,
  ) async {
    final incomplete = <String>[];
    await _deleteTargetKeys(
      '消息清理失败',
      db.messageBox,
      targets.keysFor(DeletionTargetNames.messages),
      incomplete,
    );
    await _deleteTargetKeys(
      '群记忆清理失败',
      db.groupMemoryBox,
      targets.keysFor(DeletionTargetNames.groupMemories),
      incomplete,
    );
    await _deleteTargetKeys(
      '角色记忆清理失败',
      db.characterMemoryBox,
      targets.keysFor(DeletionTargetNames.characterMemories),
      incomplete,
    );
    await _deleteTargetKeys(
      '关系清理失败',
      db.relationshipStateBox,
      targets.keysFor(DeletionTargetNames.relationshipStates),
      incomplete,
    );
    await _deleteTargetKeys(
      '关系事件清理失败',
      db.relationshipEventBox,
      targets.keysFor(DeletionTargetNames.relationshipEvents),
      incomplete,
    );
    await _deleteTargetKeys(
      '永久记忆清理失败',
      db.permanentMemoryBox,
      targets.keysFor(DeletionTargetNames.permanentMemories),
      incomplete,
    );
    await _deleteTargetKeys(
      '任务清理失败',
      db.agentTaskBox,
      targets.keysFor(DeletionTargetNames.agentTasks),
      incomplete,
    );
    await _deleteTargetKeys(
      '工作区记录清理失败',
      db.workModeWorkspaceBox,
      targets.keysFor(DeletionTargetNames.workspaces),
      incomplete,
    );
    await _runner.attempt('角色长期记忆重置失败', incomplete, () async {
      for (final key in targets.keysFor(DeletionTargetNames.aiCharacters)) {
        final character = db.aiCharacterBox.get(key);
        if (character == null) continue;
        character.memorySummary = '';
        character.hourlyReplyCount = 0;
        character.lastReplyTimestamp = null;
        await db.aiCharacterBox.put(character.id, character);
      }
    });

    if (scope != DataClearScope.chatContent) {
      await _deleteTargetKeys(
        '技能清理失败',
        db.characterSkillBox,
        targets.keysFor(DeletionTargetNames.characterSkills),
        incomplete,
      );
      await _deleteTargetKeys(
        '群聊清理失败',
        db.chatGroupBox,
        targets.keysFor(DeletionTargetNames.chatGroups),
        incomplete,
      );
      await _deleteTargetKeys(
        '角色清理失败',
        db.aiCharacterBox,
        targets.keysFor(DeletionTargetNames.aiCharacters),
        incomplete,
      );
      await _deleteTargetKeys(
        '用户资料清理失败',
        db.userProfileBox,
        targets.keysFor(DeletionTargetNames.userProfiles),
        incomplete,
      );
      final deletableConfigIds = <String>[];
      for (final configId in targets
          .keysFor(DeletionTargetNames.apiConfigs)
          .whereType<String>()) {
        final deleted = await _runner.attempt(
          'API 凭据删除失败',
          incomplete,
          () => _deleteSecureCredential(configId),
        );
        if (deleted) {
          deletableConfigIds.add(configId);
        }
      }
      await _deleteTargetKeys(
        'API 配置清理失败',
        db.apiConfigBox,
        deletableConfigIds,
        incomplete,
      );
      await _runner.attempt('外部配置清理失败', incomplete, clearExternalSettings);
    }

    await _clearSearchData(scope, incomplete, targets: targets);

    await _runner.attempt('设置清理失败', incomplete, () async {
      switch (scope) {
        case DataClearScope.chatContent:
          await _settings.clearConversationSettings(
            targets: targets.appSettings,
          );
        case DataClearScope.userContent:
          await _settings.clearExceptPreferences(
            targets: targets.appSettings,
          );
        case DataClearScope.factoryReset:
          await _settings.clearExceptPendingOperation(
            targets: targets.appSettings,
          );
      }
      db.resetLifecycleCaches();
    });
    return _finish(incomplete, await cleanupOrphanMedia());
  }

  Future<void> _clearSearchData(
    DataClearScope scope,
    List<String> incomplete, {
    required DeletionTargets targets,
  }) async {
    await _runner.attempt(
      '搜索缓存清理失败',
      incomplete,
      () => SearchCacheController.clear(_searchSettings),
    );
    await _runner.attempt(
      '搜索审计清理失败',
      incomplete,
      _governance.clearSearchAudits,
    );
    if (scope == DataClearScope.chatContent) return;

    await _runner.attempt(
      '搜索凭据修复重试失败',
      incomplete,
      () async {
        await _searchSettings.retryPendingCredentialRepairs();
        if (_searchSettings.pendingCredentialRepairIds.isNotEmpty) {
          throw StateError('search credential repairs remain pending');
        }
      },
    );
    if (_searchSettings.hasMalformedCredentialRepairState) {
      incomplete.add('搜索凭据修复状态损坏');
      return;
    }

    final currentConfigs = _searchSettings.configs;
    final plannedIds =
        targets.boxKeys.containsKey(DeletionTargetNames.searchProviderConfigs)
            ? targets
                .keysFor(DeletionTargetNames.searchProviderConfigs)
                .whereType<String>()
                .toSet()
            : currentConfigs.map((config) => config.id).toSet();
    final configs = currentConfigs
        .where((config) => plannedIds.contains(config.id))
        .toList(growable: false);
    for (final config in configs) {
      await _runner.attempt(
        '搜索凭据删除失败',
        incomplete,
        () async {
          final result = await _searchSettings.delete(config.id);
          if (!result.isSuccess) {
            throw StateError('search credential deletion failed');
          }
        },
      );
    }
    await _runner.attempt(
      '搜索配置清理失败',
      incomplete,
      () async {
        await _searchSettings.clearConfigurationIfEmpty();
        if (_searchSettings.configs.isEmpty) {
          await _searchSettings.clearRuntimeSettings();
          await _governance.clearSearchPolicies();
        }
      },
    );
  }
}

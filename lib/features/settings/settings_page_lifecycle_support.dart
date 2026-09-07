part of 'settings_page.dart';

extension _SettingsPageLifecycleSupport on _SettingsPageState {
  DataLifecycleService _workModeDataLifecycleService() {
    final db = ref.read(databaseServiceProvider);
    // Once the persistent directory exists, silently falling back would make
    // a clear operation delete Hive data without quiescing its event/snapshot
    // stores. Only the pre-initialization test/startup state may use the
    // lightweight service.
    final persistentDataReady = db.dataDirPath?.isNotEmpty == true;
    try {
      final coordinator = ref.read(workTaskCoordinatorProvider);
      final eventStore = ref.read(workTaskEventStoreProvider);
      final snapshots = ref.read(workSnapshotServiceProvider);
      return DataLifecycleService(
        db: db,
        stopWorkModeTasks: coordinator.stopAllForDataClear,
        clearWorkModeArtifacts: () async {
          await eventStore.clearAll();
          await snapshots.clearAll();
        },
        resumeWorkModeTasks: coordinator.resumeAfterDataClear,
      );
    } on StateError {
      if (persistentDataReady) rethrow;
      // Lightweight settings callers may render before the database has a
      // persistent data directory. Keep ordinary data clearing available, but
      // do not invent a work-mode storage path or bypass its lifecycle gate.
      return DataLifecycleService(db: db);
    } on HiveError {
      if (persistentDataReady) rethrow;
      // The app-settings box can be unopened during the same lightweight
      // startup window. Wait for normal app initialization before wiring the
      // work-mode artifact callbacks.
      return DataLifecycleService(db: db);
    }
  }

  Future<void> _chooseAiProcessingDir() async {
    try {
      final selected = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择 AI 工作根目录',
        initialDirectory:
            _aiProcessingDirPath.isNotEmpty ? _aiProcessingDirPath : null,
      );
      if (selected == null || selected.trim().isEmpty) return;
      final dir = Directory(selected).absolute;
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final db = ref.read(databaseServiceProvider);
      await db.saveAiProcessingDirPath(dir.path);
      final path = await db.effectiveAiProcessingDirPath();
      if (!mounted) return;
      _safeSetState(() => _aiProcessingDirPath = path);
      AppToast.show(context, 'AI 工作根目录已更新', icon: Icons.folder_open_rounded);
    } catch (e) {
      if (!mounted) return;
      AppToast.show(
        context,
        '选择目录失败：${sanitizeWorkTaskError(e)}',
        icon: Icons.error_outline_rounded,
      );
    }
  }

  Future<void> _resetAiProcessingDir() async {
    final db = ref.read(databaseServiceProvider);
    await db.resetAiProcessingDirPath();
    final path = await db.effectiveAiProcessingDirPath();
    if (!mounted) return;
    _safeSetState(() => _aiProcessingDirPath = path);
    AppToast.show(context, '已恢复默认 AI 工作根目录', icon: Icons.restore_rounded);
  }

  String _compactPath(String path) {
    final normalized = path.replaceAll('\\', '/');
    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty && normalized.startsWith(home)) {
      return normalized.replaceFirst(home, '~');
    }
    if (normalized.length <= 58) return normalized;
    return '...${normalized.substring(normalized.length - 55)}';
  }

  Widget _statIcon(IconData icon, Color color) {
    return Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
            color: color.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(10)),
        child: Icon(icon, size: 18, color: color));
  }

  Widget _statLabel(String label, int value) {
    return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label,
              style: const TextStyle(fontSize: 11, color: Color(0xFF97A0B2))),
          Text(value.toString(),
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'monospace')),
        ]);
  }

  Widget _statValue(String text, ColorScheme cs) {
    return Text(text,
        style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: cs.onSurface,
            fontFamily: 'monospace'));
  }

  String _cachePercent(int cachedTokens, int inputTokens) {
    if (inputTokens <= 0) return '0.0%';
    return '${(cachedTokens / inputTokens * 100).toStringAsFixed(1)}%';
  }

  Future<void> _confirmClearData(
    BuildContext context,
    DataClearScope scope,
  ) async {
    final cs = Theme.of(context).colorScheme;
    final service = _workModeDataLifecycleService();
    final plan = await service.previewClear(scope);
    if (!context.mounted) return;
    final (title, description) = switch (scope) {
      DataClearScope.chatContent => (
          '清除聊天内容？',
          '将永久删除消息、附件、记忆、关系、任务、工作区记录和会话状态。角色、群聊、API 配置、主题、TTS 和目录偏好会保留。仅清理 App 内工作模式事件日志和撤销快照，不会删除授权目录中的项目真实文件。',
        ),
      DataClearScope.userContent => (
          '清除全部用户内容？',
          '将永久删除聊天内容、角色、群聊、技能、API 配置及安全凭据。主题、TTS 和目录偏好会保留。仅清理 App 内工作模式事件日志和撤销快照，不会删除授权目录中的项目真实文件。',
        ),
      DataClearScope.factoryReset => (
          '恢复出厂设置？',
          '将永久删除全部用户内容及安全凭据，并重置主题、TTS、目录等所有偏好。仅清理 App 内工作模式事件日志和撤销快照，不会删除授权目录中的项目真实文件。',
        ),
    };
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.warning_amber_rounded, color: cs.error, size: 28),
        title: Text(title),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(description),
                const SizedBox(height: 16),
                Text(
                  '将删除：${_clearCountSummary(plan, scope)}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Text(_clearDetailSummary(plan, scope)),
                if (plan.retainedCounts.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text('明确保留：${_retainedClearSummary(plan)}'),
                ],
                const SizedBox(height: 16),
                const Text('此操作不可撤销，请先导出高价值对话。'),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: cs.error),
            child: const Text('清除'),
          ),
        ],
      ),
    );

    if (confirm == true && context.mounted) {
      final db = ref.read(databaseServiceProvider);
      final result = await service.clear(scope);
      ref.invalidate(apiConfigsProvider);
      ref.invalidate(aiCharactersProvider);
      ref.invalidate(chatGroupsProvider);
      _tokenUsage = db.getTokenUsage();
      if (scope == DataClearScope.factoryReset) {
        ref.invalidate(appSkinModeProvider);
        _currentSkinMode = db.savedAppSkinMode;
        _isTtsEnabled = db.isTtsEnabled;
        await _loadAiProcessingDirPath();
      }
      await _loadLifecycleState();
      if (context.mounted) {
        if (result.isComplete) {
          AppToast.show(context, title.replaceFirst('？', '完成'),
              icon: Icons.cleaning_services_rounded);
        } else {
          await showIncompleteDeletionDialog(context, result);
        }
      }
    }
  }

  String _clearCountSummary(DeletionPlan plan, DataClearScope scope) {
    final entries = <String>[
      '${plan.count('messages')} 条消息',
      '${plan.count('attachments')} 个 App 管理附件',
      '${plan.count('groupMemories') + plan.count('characterMemories')} 条场合记忆',
      '${plan.count('relationshipStates')} 条关系快照',
      '${plan.count('relationshipEvents')} 条关系事件',
      '${plan.count('permanentMemories')} 条永久记忆',
    ];
    if (scope != DataClearScope.chatContent) {
      entries.addAll([
        '${plan.count('aiCharacters')} 个角色',
        '${plan.count('groups')} 个群聊',
        '${plan.count('apiConfigs')} 个 API 配置',
        '${plan.count('searchProviderConfigs')} 个搜索配置',
      ]);
    }
    return entries.join('、');
  }

  String _clearDetailSummary(DeletionPlan plan, DataClearScope scope) {
    final entries = <String>[
      '任务 ${plan.count('tasks')} 个',
      '工作区 ${plan.count('workspaces')} 条',
      '技能 ${plan.count('characterSkills')} 个',
      '会话状态 ${plan.count('settings')} 项',
      '会话索引 ${plan.count('sessionIndexes')} 项',
      '记忆 pin ${plan.count('memoryPins')} 个',
      '重试记录 ${plan.count('retryRecords')} 条',
      '工作模式事件/撤销快照：仅清理 App 内记录',
    ];
    if (scope != DataClearScope.chatContent) {
      entries.addAll([
        '凭据 ${plan.count('credentials')} 个',
        '搜索凭据 ${plan.count('searchCredentials')} 个',
        '用户资料 ${plan.count('userProfiles')} 条',
      ]);
    }
    return entries.join(' · ');
  }

  String _retainedClearSummary(DeletionPlan plan) {
    final entries = <String>[];
    for (final entry in const [
      ('aiCharacters', '角色'),
      ('groups', '群聊'),
      ('apiConfigs', 'API 配置'),
      ('searchProviderConfigs', '搜索配置'),
      ('permanentMemories', '永久记忆'),
      ('relationshipEvents', '关系事件'),
      ('globalRelationshipStates', '全局关系快照'),
      ('userProfiles', '用户资料'),
    ]) {
      final count = plan.retainedCount(entry.$1);
      if (count > 0) entries.add('$count 个${entry.$2}');
    }
    return entries.isEmpty ? '无额外数据' : entries.join('、');
  }

  Future<void> _openBackupRestore() async {
    final restored = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const BackupRestorePage()),
    );
    if (restored != true || !mounted) return;
    final db = ref.read(databaseServiceProvider);
    _safeSetState(() {
      _currentSkinMode = db.savedAppSkinMode;
      _isTtsEnabled = db.isTtsEnabled;
    });
    await _loadLifecycleState();
  }

  Future<void> _cleanupOrphanMedia() async {
    _safeSetState(() => _isCleaningMedia = true);
    final result = await DataLifecycleService(
      db: ref.read(databaseServiceProvider),
    ).cleanupOrphanMedia();
    await _loadLifecycleState();
    if (!mounted) return;
    _safeSetState(() => _isCleaningMedia = false);
    if (result.isComplete) {
      AppToast.show(context, '已清理 ${result.reclaimedFiles} 个孤儿附件',
          icon: Icons.cleaning_services_rounded);
    } else {
      await showIncompleteDeletionDialog(context, result);
    }
  }

  Future<void> _retryPendingDeletion() async {
    final result =
        await _workModeDataLifecycleService().retryPendingOperation();
    ref.invalidate(apiConfigsProvider);
    ref.invalidate(aiCharactersProvider);
    ref.invalidate(chatGroupsProvider);
    await _loadLifecycleState();
    if (!mounted) return;
    if (result.isComplete) {
      AppToast.show(context, '未完成删除已重试完成',
          icon: Icons.check_circle_outline_rounded);
    } else {
      await showIncompleteDeletionDialog(context, result);
    }
  }
}

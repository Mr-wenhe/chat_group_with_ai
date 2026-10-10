part of 'settings_page.dart';

extension _SettingsPageConfigSupport on _SettingsPageState {
  void _openConfigForm(BuildContext context, [ApiConfig? config]) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ApiConfigFormPage(config: config)),
    );
  }

  Future<void> _showDocumentCache() async {
    final clear = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('文档解析缓存'),
        content:
            Text('当前缓存 ${DocumentUnderstandingService.cachedDocumentCount} 个文档。'
                '缓存只在内存中保存，可由原附件重新解析。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('关闭'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('清除缓存'),
          ),
        ],
      ),
    );
    if (clear == true) {
      DocumentUnderstandingService.clearCache();
      if (mounted) _safeSetState(() {});
    }
  }

  /// 分区标题栏的「新增」按钮：无论是否已存在配置，都可随时创建新的 API Key。
  Widget _buildAddConfigButton(ColorScheme cs) {
    return FilledButton.icon(
      onPressed: () => _openConfigForm(context),
      icon: const Icon(Icons.add_rounded, size: 16),
      label: const Text('新增'),
      style: FilledButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }

  Future<void> _confirmDeleteConfig(
      BuildContext context, ApiConfig config) async {
    final cs = Theme.of(context).colorScheme;
    final plan = await DataLifecycleService(
      db: ref.read(databaseServiceProvider),
    ).previewApiConfig(config.id);
    if (!context.mounted) return;
    final replacements = ref
        .read(apiConfigsProvider)
        .where((candidate) => candidate.id != config.id)
        .toList(growable: false);
    var replacementId = '';
    final selection = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          icon: Icon(Icons.warning_amber_rounded, color: cs.error, size: 28),
          title: Text('删除「${config.name}」？'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('当前有 ${plan.count('characters')} 个角色使用该配置。'
                    '删除后旧凭据会同步移除，不会回退使用旧 Key。'),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  value: replacementId,
                  decoration: const InputDecoration(
                    labelText: '受影响角色',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    const DropdownMenuItem(
                      value: '',
                      child: Text('解绑（角色将无法回复）'),
                    ),
                    ...replacements.map(
                      (candidate) => DropdownMenuItem(
                        value: candidate.id,
                        child: Text('替换为 ${candidate.name}'),
                      ),
                    ),
                  ],
                  onChanged: (value) => setDialogState(
                    () => replacementId = value ?? '',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, replacementId),
              style: FilledButton.styleFrom(backgroundColor: cs.error),
              child: const Text('确认删除'),
            ),
          ],
        ),
      ),
    );

    if (selection != null && context.mounted) {
      // 悬空引用的清理由共享删除入口负责——它知道配置是否真的被移除，
      // 而这里只看调用是否返回是不够的：凭据删除失败时配置仍然存在，
      // 那时清掉引用等于让一次失败的删除顺带改掉全局选择。
      final result = await ref.read(apiConfigsProvider.notifier).deleteConfig(
            config.id,
            replacementConfigId: selection.isEmpty ? null : selection,
          );
      if (context.mounted) {
        if (result.isComplete) {
          AppToast.show(context, '「${config.name}」已删除',
              icon: Icons.delete_outline_rounded);
        } else {
          await showIncompleteDeletionDialog(context, result);
        }
      }
    }
  }

  /// 设置页上「AI 接话选人器」的当前状态描述。
  ///
  /// 引用失效（配置被删除、导入备份后指向了不存在的 id、存储值损坏）一律显示
  /// 成"未选择"，与实际行为一致：解析不到配置时不调用模型选人。
  String get _speakerPickerSubtitle {
    final db = ref.read(databaseServiceProvider);
    final id = AiSpeakerPickerSettings(db).selectedConfigId();
    if (id == null) return '未选择 · 使用本地规则选人，不额外调用模型';
    final config = db.apiConfigBox.get(id);
    if (config == null) {
      return '引用的配置已不存在 · 已回落本地规则，请重新选择';
    }
    if (!config.hasCredential) {
      return '${config.name} · 缺少凭据，暂时回落本地规则';
    }
    return '${config.name} · ${config.modelName}';
  }

  /// 选择选人器使用的 API 配置。
  ///
  /// 只把所选配置的 **id** 写进 app_settings：不保存明文 Key、凭据对象或配置
  /// 副本，也不要求为选人器新增任何 API Key。选人不影响各角色自己的发言配置。
  Future<void> _chooseSpeakerPickerConfig() async {
    final db = ref.read(databaseServiceProvider);
    final settings = AiSpeakerPickerSettings(db);
    final configs = ref.read(apiConfigsProvider);
    final validIds = {for (final config in configs) config.id};
    final selectedId = settings.selectedConfigId();
    // 失效引用按"未选择"呈现：给一个点了必然报错的选项比不给更糟。
    var draft = validIds.contains(selectedId) ? selectedId : null;

    final saved = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('AI 接话选人器'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '选人器按最新对话决定下一位由谁说。它是幕后的选人步骤，不是群成员，'
                  '不会产生聊天气泡；每位角色的实际发言仍使用各自绑定的配置。',
                  style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(dialogContext).colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  value: draft ?? '',
                  decoration: const InputDecoration(
                    labelText: '选人器使用的配置',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    const DropdownMenuItem(
                      value: '',
                      child: Text('不启用（使用本地规则）'),
                    ),
                    ...configs.map(
                      (config) => DropdownMenuItem(
                        value: config.id,
                        child: Text(config.name),
                      ),
                    ),
                  ],
                  onChanged: (value) => setDialogState(
                    () => draft = (value ?? '').isEmpty ? null : value,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('取消')),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, draft ?? ''),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    // null 表示用户取消；空串表示"不启用"。
    if (saved == null) return;
    await settings.select(saved);
    if (mounted) _safeSetState(() {});
  }

  Future<void> _testApiKey(BuildContext context, ApiConfig config) async {
    final cs = Theme.of(context).colorScheme;
    final provider = ApiProvider.values.firstWhere(
      (p) => p.name == config.provider,
      orElse: () => ApiProvider.deepseek,
    );
    final apiKey = await _credentialResolver.resolve(config);
    if (!context.mounted) return;
    if (apiKey == null) {
      AppToast.show(context, 'API 凭据不可用', icon: Icons.key_off_rounded);
      return;
    }

    // 更美观的加载对话框：正常进度圈 + 文字布局，使用主题色
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        contentPadding:
            const EdgeInsets.symmetric(vertical: 32, horizontal: 24),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(strokeWidth: 3, color: cs.primary),
            const SizedBox(height: 20),
            Text('正在测试 ${config.name}...',
                style: TextStyle(fontSize: 15, color: cs.onSurface)),
          ],
        ),
      ),
    );

    final result = await _apiService.testApiKey(
      apiKey: apiKey,
      provider: provider,
      apiProtocol: config.protocol,
      customBaseUrl: config.customBaseUrl,
      model: config.modelName,
    );

    if (context.mounted) Navigator.of(context).pop();
    if (!context.mounted) return;

    final isSuccess = result['success'] == true;
    if (isSuccess) {
      AppToast.show(context, '${config.name} 测试成功！${result['reply'] ?? ''}',
          icon: Icons.check_circle_outline_rounded);
    } else {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: Icon(Icons.error_outline_rounded,
              color: Theme.of(context).colorScheme.error, size: 28),
          title: Text('${config.name} 测试失败'),
          content: Text(result['message'] ?? '未知错误'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
          ],
        ),
      );
    }
  }

  String _skinLabel(AppSkinMode mode) {
    switch (mode) {
      case AppSkinMode.light:
        return '浅色';
      case AppSkinMode.dark:
        return '深色';
      case AppSkinMode.system:
        return '跟随系统';
      case AppSkinMode.golden:
        return '黄金';
    }
  }
}

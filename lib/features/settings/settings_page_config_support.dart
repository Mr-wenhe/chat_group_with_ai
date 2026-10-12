part of 'settings_page.dart';

extension _SettingsPageConfigSupport on _SettingsPageState {
  /// 设置页入口行上的一句话摘要。
  ///
  /// 与「API KEY 设置」页共用同一个收集点，因此入口行上的进度和进去之后的
  /// 进度不可能对不上。
  String get _apiKeyEntrySubtitle {
    final overview = collectApiKeyOverview(
      db: ref.read(databaseServiceProvider),
      apiConfigs: ref.read(apiConfigsProvider),
    );
    return '聊天、选人器、语音、图像与联网搜索 · ${overview.progressLabel}';
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

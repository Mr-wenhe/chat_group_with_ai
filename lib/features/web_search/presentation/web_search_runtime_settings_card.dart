import 'package:flutter/material.dart';

import '../models/search_runtime_settings.dart';

/// Edits search request defaults without coupling the settings page to search
/// orchestration or network code.
class WebSearchRuntimeSettingsCard extends StatefulWidget {
  final SearchRuntimeSettings initialSettings;
  final Future<void> Function(SearchRuntimeSettings settings) onSave;
  final Future<void> Function() onClearCache;

  const WebSearchRuntimeSettingsCard({
    super.key,
    required this.initialSettings,
    required this.onSave,
    required this.onClearCache,
  });

  @override
  State<WebSearchRuntimeSettingsCard> createState() =>
      _WebSearchRuntimeSettingsCardState();
}

class _WebSearchRuntimeSettingsCardState
    extends State<WebSearchRuntimeSettingsCard> {
  late final TextEditingController _localeController;
  late final TextEditingController _countryController;
  late int _maxResults;
  late bool _safeSearch;
  late bool _nativeSearchEnabled;
  late bool _queryPlanningEnabled;
  bool _saving = false;
  bool _clearing = false;

  static const _resultOptions = <int>[3, 5, 8, 10, 15, 20];

  @override
  void initState() {
    super.initState();
    _localeController =
        TextEditingController(text: widget.initialSettings.locale);
    _countryController = TextEditingController(
      text: widget.initialSettings.country ?? '',
    );
    _maxResults = widget.initialSettings.maxResults;
    _safeSearch = widget.initialSettings.safeSearch;
    _nativeSearchEnabled = widget.initialSettings.nativeSearchEnabled;
    _queryPlanningEnabled = widget.initialSettings.queryPlanningEnabled;
  }

  @override
  void dispose() {
    _localeController.dispose();
    _countryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '搜索运行参数',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            const Text('仅用于用户主动轮次；自动聊天和主动私聊不会触发第三方搜索。'),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('search-runtime-locale'),
              controller: _localeController,
              maxLength: 16,
              decoration: const InputDecoration(
                labelText: '地区/语言',
                hintText: 'zh-CN',
                helperText: '例如 zh-CN、en-US',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('search-runtime-country'),
              controller: _countryController,
              textCapitalization: TextCapitalization.characters,
              maxLength: 2,
              decoration: const InputDecoration(
                labelText: '搜索地区（ISO 国家码，可留空）',
                hintText: 'CN',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              key: const ValueKey('search-runtime-max-results'),
              value: _maxResults,
              decoration: const InputDecoration(
                labelText: '默认结果数',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final count in _availableResultOptions)
                  DropdownMenuItem(value: count, child: Text('$count 条')),
              ],
              onChanged: _saving
                  ? null
                  : (value) {
                      if (value != null) setState(() => _maxResults = value);
                    },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('安全搜索'),
              subtitle: const Text('尽量过滤成人或高风险结果'),
              value: _safeSearch,
              onChanged: _saving
                  ? null
                  : (value) => setState(() => _safeSearch = value),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('使用模型原生联网搜索'),
              subtitle: const Text('可能消耗当前会话的模型额度；仅支持明确声明能力的模型'),
              value: _nativeSearchEnabled,
              onChanged: _saving
                  ? null
                  : (value) => setState(() => _nativeSearchEnabled = value),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('使用 AI 改写搜索词'),
              subtitle: const Text('ask 模式会先确认 Planner，再确认最终外发搜索词'),
              value: _queryPlanningEnabled,
              onChanged: _saving
                  ? null
                  : (value) => setState(() => _queryPlanningEnabled = value),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.end,
              children: [
                OutlinedButton.icon(
                  onPressed: _saving || _clearing ? null : _clearCache,
                  icon: _clearing
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.cleaning_services_outlined),
                  label: const Text('清除搜索缓存'),
                ),
                FilledButton.icon(
                  onPressed: _saving || _clearing ? null : _save,
                  icon: _saving
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_outlined),
                  label: const Text('保存搜索参数'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final settings = SearchRuntimeSettings(
        locale: _localeController.text,
        country: _countryController.text,
        maxResults: _maxResults,
        safeSearch: _safeSearch,
        nativeSearchEnabled: _nativeSearchEnabled,
        queryPlanningEnabled: _queryPlanningEnabled,
      );
      await widget.onSave(settings);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('搜索参数已保存')),
        );
      }
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('保存搜索参数失败，请稍后重试')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  List<int> get _availableResultOptions {
    final options = {..._resultOptions, _maxResults}.toList()..sort();
    return options;
  }

  Future<void> _clearCache() async {
    setState(() => _clearing = true);
    try {
      await widget.onClearCache();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('搜索缓存已清除')),
        );
      }
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('清除搜索缓存失败，请稍后重试')),
        );
      }
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }
}

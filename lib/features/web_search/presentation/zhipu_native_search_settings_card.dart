import 'package:flutter/material.dart';

import '../data/zhipu_native_search_credential_store.dart';
import '../models/search_provider_config.dart';

/// Settings card for the single native Zhipu search credential.
///
/// Independent search-provider forms are intentionally not rendered here.
/// Keeping this card separate from the character API configuration makes the
/// spending boundary explicit: search always uses this key and never a
/// character's chat key.
class ZhipuNativeSearchSettingsCard extends StatefulWidget {
  final ZhipuNativeSearchCredentialStore store;

  const ZhipuNativeSearchSettingsCard({
    super.key,
    required this.store,
  });

  @override
  State<ZhipuNativeSearchSettingsCard> createState() =>
      _ZhipuNativeSearchSettingsCardState();
}

class _ZhipuNativeSearchSettingsCardState
    extends State<ZhipuNativeSearchSettingsCard> {
  late final TextEditingController _controller;
  bool _obscure = true;
  bool _hasCredential = false;
  bool _loading = true;
  bool _saving = false;
  bool _clearing = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
    _loadState();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.travel_explore_rounded),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '智谱 AI 原生联网搜索',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                if (!_loading)
                  Icon(
                    _hasCredential
                        ? Icons.check_circle_outline_rounded
                        : Icons.key_off_outlined,
                    color: _hasCredential
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '联网搜索统一调用智谱 Web Search API；此 Key 只用于搜索，不会写入角色 API 配置或备份文件。',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 14),
            TextField(
              key: const ValueKey('zhipu-native-search-api-key'),
              controller: _controller,
              obscureText: _obscure,
              enabled: !_loading && !_saving && !_clearing,
              maxLength: SearchProviderConfig.maxCredentialLength,
              decoration: InputDecoration(
                labelText:
                    _hasCredential ? 'API Key（留空保持当前值）' : '智谱 AI API Key',
                hintText: '请输入 open.bigmodel.cn 的 API Key',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  tooltip: _obscure ? '显示 Key' : '隐藏 Key',
                  icon: Icon(
                    _obscure
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                  onPressed: _loading || _saving || _clearing
                      ? null
                      : () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                spacing: 8,
                children: [
                  if (_hasCredential)
                    OutlinedButton.icon(
                      onPressed:
                          _loading || _saving || _clearing ? null : _clear,
                      icon: _clearing
                          ? const SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.delete_outline_rounded),
                      label: const Text('清除'),
                    ),
                  FilledButton.icon(
                    onPressed: _loading || _saving || _clearing ? null : _save,
                    icon: _saving
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save_outlined),
                    label: const Text('保存 Key'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _loadState() async {
    final state = await widget.store.state();
    if (!mounted) return;
    setState(() {
      _hasCredential = state.hasCredential;
      _loading = false;
    });
  }

  Future<void> _save() async {
    final value = _controller.text.trim();
    if (value.isEmpty && _hasCredential) {
      _showMessage('Key 输入为空，已保留当前凭据');
      return;
    }
    if (value.isEmpty) {
      _showMessage('请输入智谱 AI API Key');
      return;
    }
    setState(() => _saving = true);
    final result = await widget.store.save(value);
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (result.isSuccess) {
        _hasCredential = true;
        _controller.clear();
      }
    });
    if (result.isSuccess) {
      _showMessage(
        result.usedDevelopmentFallback
            ? '已保存（macOS Debug 使用本地开发回退）'
            : '智谱 AI 搜索 Key 已保存',
      );
    } else {
      _showMessage(result.message ?? '保存智谱 AI 搜索 Key 失败，请稍后重试');
    }
  }

  Future<void> _clear() async {
    setState(() => _clearing = true);
    final result = await widget.store.clear();
    if (!mounted) return;
    setState(() {
      _clearing = false;
      if (result.isSuccess) _hasCredential = false;
    });
    _showMessage(result.isSuccess ? '智谱 AI 搜索 Key 已清除' : '清除搜索 Key 失败，请稍后重试');
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

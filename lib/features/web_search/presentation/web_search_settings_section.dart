import 'package:flutter/material.dart';

import 'package:chat_group/features/settings/search_provider_config_form_page.dart';
import '../data/search_settings_store.dart';
import '../models/search_provider_config.dart';

/// Settings surface for search provider metadata. It deliberately delegates
/// all credential and validation behavior to [SearchProviderConfigStore].
class WebSearchSettingsSection extends StatefulWidget {
  final SearchProviderConfigStore store;

  const WebSearchSettingsSection({
    super.key,
    required this.store,
  });

  @override
  State<WebSearchSettingsSection> createState() =>
      _WebSearchSettingsSectionState();
}

class _WebSearchSettingsSectionState extends State<WebSearchSettingsSection> {
  @override
  Widget build(BuildContext context) {
    final configs = widget.store.configs;
    return Card(
      child: Column(
        children: [
          ListTile(
            title: const Text('搜索 Provider 配置'),
            subtitle: Text(
              configs.isEmpty
                  ? '尚未配置；Key 只保存到安全存储'
                  : '${configs.length} 个配置 · 恢复备份后需要重新绑定 Key',
            ),
            trailing: IconButton(
              tooltip: '添加 Provider',
              icon: const Icon(Icons.add_circle_outline),
              onPressed: () => _openForm(),
            ),
          ),
          for (final config in configs) _configTile(config),
        ],
      ),
    );
  }

  Widget _configTile(SearchProviderConfig config) {
    return ListTile(
      dense: true,
      title: Text('${config.name}${config.isDefault ? ' · 默认' : ''}'),
      subtitle: Text(
        '${config.provider.name} · ${config.enabled ? '已启用' : '已停用'} · '
        '${config.hasCredential ? '已绑定 Key' : '未绑定 Key'}',
      ),
      leading: Icon(
        config.hasCredential ? Icons.key_outlined : Icons.key_off_outlined,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: '编辑 Provider',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => _openForm(config),
          ),
          IconButton(
            tooltip: '删除 Provider',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _deleteConfig(config),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteConfig(SearchProviderConfig config) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除搜索 Provider？'),
        content: Text('将删除「${config.name}」及其绑定的安全凭据。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final result = await widget.store.delete(config.id);
    if (!mounted) return;
    if (result.isSuccess) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('搜索 Provider 已删除')),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('删除失败，安全凭据未完成清理')),
      );
    }
  }

  Future<void> _openForm([SearchProviderConfig? config]) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SearchProviderConfigFormPage(
          config: config,
          store: widget.store,
        ),
      ),
    );
    if (mounted) setState(() {});
  }
}

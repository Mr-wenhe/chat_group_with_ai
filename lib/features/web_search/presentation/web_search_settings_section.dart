import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

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
    if (kIsWeb) {
      return const Card(
        child: ListTile(
          leading: Icon(Icons.info_outline),
          title: Text('Web 端不支持联网搜索'),
          subtitle: Text('请使用 Android、iOS、macOS 或 Windows 版本。'),
        ),
      );
    }
    final configs = widget.store.configs;
    final pendingRepairIds = widget.store.pendingCredentialRepairIds;
    final malformedRepairState = widget.store.hasMalformedCredentialRepairState;
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
          if (pendingRepairIds.isNotEmpty || malformedRepairState)
            _pendingRepairTile(
              pendingRepairIds,
              malformed: malformedRepairState,
            ),
          for (final config in configs) _configTile(config),
        ],
      ),
    );
  }

  Widget _pendingRepairTile(
    List<String> ids, {
    bool malformed = false,
  }) {
    final preview = ids.take(3).join('、');
    final suffix = ids.length > 3 ? ' 等' : '';
    final hasMissingMetadata =
        ids.any((id) => widget.store.findById(id) == null);
    return ListTile(
      leading: const Icon(Icons.warning_amber_rounded, color: Colors.orange),
      title: Text(
        malformed ? '安全凭据修复状态损坏' : '待完成的安全凭据清理（${ids.length}）',
      ),
      subtitle: Text(
        malformed
            ? '本地修复记录无法解析，原始记录已保留；请先导出数据并联系支持。'
            : hasMissingMetadata
                ? '部分配置元数据已不存在，仍有凭据清理操作待重试：$preview$suffix'
                : '配置仍保留，凭据修复状态待清理：$preview$suffix',
      ),
      trailing: TextButton(
        onPressed: malformed ? null : _retryPendingCredentialRepairs,
        child: const Text('重试'),
      ),
    );
  }

  Future<void> _retryPendingCredentialRepairs() async {
    try {
      await widget.store.retryPendingCredentialRepairs();
      if (!mounted) return;
      setState(() {});
      final remaining = widget.store.pendingCredentialRepairIds.length;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            remaining == 0 ? '待处理凭据已清理' : '仍有 $remaining 个凭据清理待重试',
          ),
        ),
      );
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('凭据清理重试失败，请稍后再试')),
      );
    }
  }

  Widget _configTile(SearchProviderConfig config) {
    return SearchProviderConfigTile(
      config: config,
      onEdit: () => _openForm(config),
      onDelete: () => _deleteConfig(config),
      hasUnknownCredentialBinding:
          widget.store.hasUnknownCredentialBinding(config.id),
      onRepair: widget.store.canRepairUnknownCredentialBinding(config.id)
          ? () => _repairConfig(config)
          : null,
    );
  }

  Future<void> _repairConfig(SearchProviderConfig config) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('修复旧搜索凭据绑定？'),
        content: Text(
          '将删除「${config.name}」在搜索安全存储中的无法识别旧绑定，'
          '并要求重新输入 Key。此操作不会删除其他功能的凭据。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确认修复'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final result = await widget.store.repairUnknownCredentialBinding(config.id);
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.isSuccess
              ? '旧绑定已清理，请重新输入 Key'
              : (result.errorMessage ?? '旧绑定修复失败'),
        ),
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

class SearchProviderConfigTile extends StatelessWidget {
  final SearchProviderConfig config;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final VoidCallback? onRepair;
  final bool hasUnknownCredentialBinding;

  const SearchProviderConfigTile({
    super.key,
    required this.config,
    this.onEdit,
    this.onDelete,
    this.onRepair,
    this.hasUnknownCredentialBinding = false,
  });

  @override
  Widget build(BuildContext context) {
    final attentionText = config.requiresAttention ? ' · 需要重新验证凭据' : '';
    final unknownBindingText = hasUnknownCredentialBinding ? ' · 绑定无法识别' : '';
    return ListTile(
      dense: true,
      title: Text('${config.name}${config.isDefault ? ' · 默认' : ''}'),
      subtitle: Text(
        '${config.provider.name} · ${config.enabled ? '已启用' : '已停用'} · '
        '${config.hasCredential ? '已绑定 Key' : '未绑定 Key'}'
        '$attentionText$unknownBindingText',
      ),
      leading: Icon(
        config.requiresAttention || hasUnknownCredentialBinding
            ? Icons.warning_amber_rounded
            : config.hasCredential
                ? Icons.key_outlined
                : Icons.key_off_outlined,
        color: config.requiresAttention ? Colors.orange : null,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: '编辑 Provider',
            icon: const Icon(Icons.edit_outlined),
            onPressed: onEdit,
          ),
          if (onRepair != null)
            IconButton(
              tooltip: '修复旧凭据绑定',
              icon: const Icon(Icons.build_outlined),
              onPressed: onRepair,
            ),
          IconButton(
            tooltip: '删除 Provider',
            icon: const Icon(Icons.delete_outline),
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}

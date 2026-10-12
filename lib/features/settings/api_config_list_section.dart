import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:chat_group/core/database/data_lifecycle_service.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/core/theme/provider_style.dart';
import 'package:chat_group/core/widgets/app_widgets.dart';
import 'package:chat_group/core/widgets/data_lifecycle_result_dialog.dart';
import 'package:chat_group/core/widgets/top_toast.dart';
import 'package:chat_group/features/ai_governance/ai_governance_store.dart';
import 'package:chat_group/features/ai_governance/ai_request_gateway.dart';
import 'package:chat_group/features/settings/api_config_form_page.dart';
import 'package:chat_group/features/settings/providers/api_config_providers.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:chat_group/services/ai_providers/ai_api_service.dart';

/// 聊天与角色发言使用的 API 配置列表：新增 / 测试 / 编辑 / 删除。
///
/// 从设置页原「API 配置」区块整体搬出，供「API KEY 设置」页复用。搬动时
/// 逻辑逐字保留 —— 连接测试只用调用方本次输入的明文 Key 或已保存凭据，
/// 绝不为测试先写后读安全存储。
class ApiConfigListSection extends ConsumerStatefulWidget {
  const ApiConfigListSection({
    super.key,
    this.title = 'API 配置',
    this.subtitle = '管理 API Key、Base URL 和模型，角色可复用配置',
  });

  /// 小标题行文案；右侧始终渲染「新增」按钮。
  final String title;
  final String subtitle;

  @override
  ConsumerState<ApiConfigListSection> createState() =>
      _ApiConfigListSectionState();
}

class _ApiConfigListSectionState extends ConsumerState<ApiConfigListSection> {
  late final AiApiService _apiService;
  final _credentialResolver = SecureApiCredentialResolver();

  @override
  void initState() {
    super.initState();
    final db = ref.read(databaseServiceProvider);
    _apiService = AiApiService(
      AiRequestGateway(store: AiGovernanceStore.forDatabase(db)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final configs = ref.watch(apiConfigsProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(widget.title,
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface)),
            ),
            _buildAddConfigButton(cs),
          ],
        ),
        const SizedBox(height: 4),
        Text(widget.subtitle,
            style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
        const SizedBox(height: 12),
        if (configs.isEmpty)
          _buildEmptyState(cs)
        else
          ...configs.map((c) => _ApiConfigCard(
                config: c,
                cs: cs,
                onEdit: () => _openConfigForm(context, c),
                onDelete: () => _confirmDeleteConfig(context, c),
                onTest: () => _testApiKey(context, c),
              )),
      ],
    );
  }

  Widget _buildEmptyState(ColorScheme cs) {
    return AppCard(
      cs: cs,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Center(
            child: Column(
              children: [
                Icon(Icons.settings_remote_outlined,
                    size: 40,
                    color: cs.onSurfaceVariant.withValues(alpha: 0.4)),
                const SizedBox(height: 12),
                Text('还没有 API 配置',
                    style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant)),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: () => _openConfigForm(context),
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('创建配置'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 小标题栏的「新增」按钮：无论是否已存在配置，都可随时创建新的 API Key。
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

  void _openConfigForm(BuildContext context, [ApiConfig? config]) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ApiConfigFormPage(config: config)),
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
}

class _ApiConfigCard extends StatelessWidget {
  final ApiConfig config;
  final ColorScheme cs;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onTest;

  const _ApiConfigCard(
      {required this.config,
      required this.cs,
      required this.onEdit,
      required this.onDelete,
      required this.onTest});

  @override
  Widget build(BuildContext context) {
    final pColor = providerColor(config.provider);
    final label = providerLabel(config.provider);
    final maskedKey =
        config.hasCredential ? 'API Key 已保存 ••••••••' : '未设置 API Key';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: AppCard.decoration(cs),
      child: Row(
        children: [
          _buildAvatar(pColor),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    // 卡片右侧固定占着三个操作按钮，窄屏下留给名称的宽度可能只有
                    // 一百来像素。不给省略号就是整行溢出（既有缺陷，随卡片一起
                    // 搬过来时才在手机宽度上暴露），与下方模型行同一处理。
                    Flexible(
                      child: Text(config.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: cs.onSurface)),
                    ),
                    const SizedBox(width: 8),
                    // 徽章同样要能收缩：它自身就接近整行宽度时，光让名称省略
                    // 仍会剩下几像素的溢出。
                    Flexible(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: pColor.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                                color: pColor)),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  '${config.modelName} · ${config.protocol.label}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 2),
                Text(maskedKey,
                    style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurfaceVariant,
                        fontFamily: 'monospace')),
              ],
            ),
          ),
          Wrap(
            spacing: 4,
            children: [
              _actionButton(
                icon: Icons.bolt_rounded,
                label: '测试',
                color: cs.primary,
                onPressed: onTest,
              ),
              _actionButton(
                icon: Icons.edit_outlined,
                label: '编辑',
                color: cs.onSurfaceVariant,
                onPressed: onEdit,
              ),
              _actionButton(
                icon: Icons.delete_outline_rounded,
                label: '删除',
                color: cs.error,
                onPressed: onDelete,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _actionButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onPressed,
  }) {
    return TextButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 16),
      label: Text(label),
      style: TextButton.styleFrom(
        foregroundColor: color,
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _buildAvatar(Color pColor) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: pColor.withValues(alpha: 0.14),
        border: Border.all(color: pColor.withValues(alpha: 0.3), width: 1.5),
      ),
      child: Center(
          child: Text(config.name.isNotEmpty ? config.name[0] : '?',
              style: TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w600, color: pColor))),
    );
  }
}

import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/features/settings/providers/api_config_providers.dart';
import 'package:chat_group/features/settings/api_config_form_page.dart';
import 'package:chat_group/features/settings/export_page.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:chat_group/services/ai_providers/ai_api_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:chat_group/core/theme/provider_style.dart';
import 'package:chat_group/core/widgets/app_widgets.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  final _apiService = AiApiService();
  ThemeMode _currentThemeMode = ThemeMode.dark;
  bool _isTtsEnabled = true;
  Map<String, dynamic> _tokenUsage = {};

  @override
  void initState() {
    super.initState();
    final db = ref.read(databaseServiceProvider);
    _currentThemeMode = db.savedThemeMode;
    _isTtsEnabled = db.isTtsEnabled;
    _tokenUsage = db.getTokenUsage();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final apiConfigs = ref.watch(apiConfigsProvider);

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        backgroundColor: cs.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color(0xFF8B5CF6),
                      Color(0xFF6366F1),
                      Color(0xFF3B82F6)
                    ]),
                borderRadius: BorderRadius.circular(9),
              ),
              child: const Icon(Icons.settings_rounded,
                  size: 18, color: Colors.white),
            ),
            const SizedBox(width: 12),
            Text('设置',
                style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 22,
                    color: cs.onSurface)),
          ],
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
        children: [
          _SectionHeader(title: '应用信息', cs: cs),
          const SizedBox(height: 12),
          AppCard(
            cs: cs,
            children: [
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            Color(0xFF8B5CF6),
                            Color(0xFF6366F1),
                            Color(0xFF3B82F6)
                          ]),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.smart_toy_rounded,
                        size: 24, color: Colors.white),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('AI 群聊模拟器',
                            style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: cs.onSurface)),
                        Text('v1.0.0 · 本地存储',
                            style: TextStyle(
                                fontSize: 13, color: cs.onSurfaceVariant)),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 28),
          _SectionHeader(title: 'API 配置', cs: cs),
          const SizedBox(height: 4),
          Text('管理 API Key、Base URL 和模型，角色可复用配置',
              style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
          const SizedBox(height: 12),
          if (apiConfigs.isEmpty)
            AppCard(
              cs: cs,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Center(
                    child: Column(
                      children: [
                        Icon(Icons.settings_remote_outlined,
                            size: 40,
                            color: cs.onSurfaceVariant.withOpacity(0.4)),
                        const SizedBox(height: 12),
                        Text('还没有 API 配置',
                            style: TextStyle(
                                fontSize: 14, color: cs.onSurfaceVariant)),
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
            )
          else
            ...apiConfigs.map((c) => _ApiConfigCard(
                  config: c,
                  cs: cs,
                  onEdit: () => _openConfigForm(context, c),
                  onDelete: () => _confirmDeleteConfig(context, c),
                  onTest: () => _testApiKey(context, c),
                )),
          const SizedBox(height: 28),
          _SectionHeader(title: '外观', cs: cs),
          const SizedBox(height: 12),
          AppCard(
            cs: cs,
            margin: EdgeInsets.zero,
            children: [
              _SettingTile(
                cs: cs,
                icon: Icons.palette_outlined,
                iconColor: cs.tertiary,
                title: '外观',
                subtitle: _themeLabel(_currentThemeMode),
                onTap: () {},
                trailing: SegmentedButton<ThemeMode>(
                  segments: const [
                    ButtonSegment(
                        value: ThemeMode.light,
                        label: Icon(Icons.light_mode_rounded, size: 18),
                        tooltip: '浅色'),
                    ButtonSegment(
                        value: ThemeMode.system,
                        label: Icon(Icons.brightness_auto_rounded, size: 18),
                        tooltip: '跟随系统'),
                    ButtonSegment(
                        value: ThemeMode.dark,
                        label: Icon(Icons.dark_mode_rounded, size: 18),
                        tooltip: '深色'),
                  ],
                  selected: {_currentThemeMode},
                  onSelectionChanged: (Set<ThemeMode> sel) {
                    final mode = sel.first;
                    setState(() => _currentThemeMode = mode);
                    ref.read(databaseServiceProvider).saveThemeMode(mode);
                  },
                ),
              ),
              Divider(height: 1, color: cs.outlineVariant.withOpacity(0.5)),
              _SettingTile(
                cs: cs,
                icon: Icons.volume_up_outlined,
                iconColor: cs.tertiary,
                title: '语音朗读',
                subtitle: _isTtsEnabled ? '已开启' : '已关闭',
                onTap: () {},
                trailing: Switch(
                  value: _isTtsEnabled,
                  onChanged: (v) {
                    setState(() => _isTtsEnabled = v);
                    ref.read(databaseServiceProvider).saveTtsEnabled(v);
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 28),
          _buildTokenSection(cs),
          const SizedBox(height: 28),
          _SectionHeader(title: '数据管理', cs: cs),
          const SizedBox(height: 12),
          AppCard(
            cs: cs,
            margin: EdgeInsets.zero,
            children: [
              _SettingTile(
                cs: cs,
                icon: Icons.upload_rounded,
                iconColor: cs.primary,
                title: '导出对话',
                subtitle: '将群聊导出为 Markdown / JSON 并分享',
                onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ExportPage())),
              ),
              Divider(height: 1, color: cs.outlineVariant.withOpacity(0.5)),
              _SettingTile(
                cs: cs,
                icon: Icons.info_outline_rounded,
                iconColor: cs.primary,
                title: '关于',
                subtitle: '查看应用信息与开源许可',
                onTap: () {},
              ),
              Divider(height: 1, color: cs.outlineVariant.withOpacity(0.5)),
              _SettingTile(
                cs: cs,
                icon: Icons.cleaning_services_rounded,
                iconColor: cs.error,
                title: '清除所有数据',
                subtitle: '删除所有角色、群组、消息和 API 配置',
                onTap: () => _confirmClearData(context),
              ),
            ],
          ),
          const SizedBox(height: 32),
        ],
      ),
      bottomNavigationBar: AppBottomNav(currentIndex: 2, cs: cs),
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
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.warning_amber_rounded, color: cs.error, size: 28),
        title: Text('删除「${config.name}」？'),
        content: const Text('此操作不可撤销，使用该配置的角色将无法回复。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: cs.error),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (confirm == true && context.mounted) {
      await ref.read(apiConfigsProvider.notifier).deleteConfig(config.id);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('「${config.name}」已删除'),
              behavior: SnackBarBehavior.floating),
        );
      }
    }
  }

  Future<void> _testApiKey(BuildContext context, ApiConfig config) async {
    final cs = Theme.of(context).colorScheme;
    final provider = ApiProvider.values.firstWhere(
      (p) => p.name == config.provider,
      orElse: () => ApiProvider.deepseek,
    );

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
      apiKey: config.apiKey,
      provider: provider,
      customBaseUrl: config.customBaseUrl,
      model: config.modelName,
    );

    if (context.mounted) Navigator.of(context).pop();
    if (!context.mounted) return;

    final isSuccess = result['success'] == true;
    if (isSuccess) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${config.name} 测试成功！${result['reply'] ?? ''}'),
          backgroundColor: const Color(0xFF059669),
          behavior: SnackBarBehavior.floating,
        ),
      );
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

  String _themeLabel(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return '浅色';
      case ThemeMode.dark:
        return '深色';
      case ThemeMode.system:
        return '跟随系统';
    }
  }

  Widget _buildTokenSection(ColorScheme cs) {
    final totalInput = _tokenUsage['totalInput'] ?? 0;
    final totalOutput = _tokenUsage['totalOutput'] ?? 0;
    final totalCachedInput = _tokenUsage['totalCachedInput'] ?? 0;
    final requestCount = _tokenUsage['requestCount'] ?? 0;
    final byChar = _tokenUsage['byCharacter'] as Map<String, dynamic>? ?? {};
    final byGroup = _tokenUsage['byGroup'] as Map<String, dynamic>? ?? {};
    final db = ref.read(databaseServiceProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(title: 'Token 消耗', cs: cs),
        const SizedBox(height: 12),
        AppCard(
          cs: cs,
          margin: EdgeInsets.zero,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  _statIcon(Icons.input_rounded, cs.primary),
                  const SizedBox(width: 12),
                  Expanded(child: _statLabel('输入 Token', totalInput)),
                  _statValue(totalInput.toString(), cs),
                ],
              ),
            ),
            Divider(height: 1, color: cs.outlineVariant.withOpacity(0.5)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  _statIcon(Icons.output_rounded, cs.secondary),
                  const SizedBox(width: 12),
                  Expanded(child: _statLabel('输出 Token', totalOutput)),
                  _statValue(totalOutput.toString(), cs),
                ],
              ),
            ),
            Divider(height: 1, color: cs.outlineVariant.withOpacity(0.5)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  _statIcon(Icons.query_stats_rounded, cs.tertiary),
                  const SizedBox(width: 12),
                  Expanded(child: _statLabel('请求次数', requestCount)),
                  _statValue('$requestCount 次', cs),
                ],
              ),
            ),
            Divider(height: 1, color: cs.outlineVariant.withOpacity(0.5)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  _statIcon(Icons.offline_bolt_rounded, cs.primary),
                  const SizedBox(width: 12),
                  Expanded(child: _statLabel('缓存命中 Token', totalCachedInput)),
                  _statValue(_cachePercent(totalCachedInput, totalInput), cs),
                ],
              ),
            ),
            if (byGroup.isNotEmpty) ...[
              Divider(height: 1, color: cs.outlineVariant.withOpacity(0.5)),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Text('各群消耗',
                    style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurfaceVariant,
                        fontWeight: FontWeight.w600)),
              ),
              ...byGroup.entries.map((entry) {
                final data = Map<String, dynamic>.from(entry.value as Map);
                final groupIn = data['input'] ?? 0;
                final groupOut = data['output'] ?? 0;
                final groupCached = data['cached'] ?? 0;
                final groupCount = data['count'] ?? 0;
                final groupName =
                    db.chatGroupBox.get(entry.key)?.name ?? entry.key;
                return Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  child: Row(
                    children: [
                      Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                              color: cs.secondary,
                              borderRadius: BorderRadius.circular(2))),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(groupName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 13, color: cs.onSurface)),
                            Text(
                                '$groupCount 次 · 缓存 ${_cachePercent(groupCached, groupIn)}',
                                style: TextStyle(
                                    fontSize: 11, color: cs.onSurfaceVariant)),
                          ],
                        ),
                      ),
                      Text('${groupIn + groupOut}',
                          style: TextStyle(
                              fontSize: 13,
                              color: cs.onSurfaceVariant,
                              fontFamily: 'monospace')),
                    ],
                  ),
                );
              }),
              const SizedBox(height: 4),
            ],
            if (byChar.isNotEmpty) ...[
              Divider(height: 1, color: cs.outlineVariant.withOpacity(0.5)),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Text('各角色消耗',
                    style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurfaceVariant,
                        fontWeight: FontWeight.w600)),
              ),
              ...byChar.entries.map((entry) {
                final data = entry.value as Map<String, dynamic>;
                final charIn = data['input'] ?? 0;
                final charOut = data['output'] ?? 0;
                return Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Row(
                    children: [
                      Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                              color: cs.primary,
                              borderRadius: BorderRadius.circular(2))),
                      const SizedBox(width: 10),
                      Expanded(
                          child: Text(entry.key,
                              style: TextStyle(
                                  fontSize: 13, color: cs.onSurface))),
                      Text('${(charIn + charOut).toStringAsFixed(0)}',
                          style: TextStyle(
                              fontSize: 13,
                              color: cs.onSurfaceVariant,
                              fontFamily: 'monospace')),
                    ],
                  ),
                );
              }),
              const SizedBox(height: 4),
            ],
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(right: 12, bottom: 4),
              child: Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () async {
                    final db = ref.read(databaseServiceProvider);
                    await db.clearTokenUsage();
                    setState(() => _tokenUsage = db.getTokenUsage());
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                          content: Text('Token 统计已清零'),
                          behavior: SnackBarBehavior.floating));
                    }
                  },
                  icon: Icon(Icons.refresh_rounded, size: 16, color: cs.error),
                  label: Text('清零',
                      style: TextStyle(color: cs.error, fontSize: 12)),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _statIcon(IconData icon, Color color) {
    return Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
            color: color.withOpacity(0.14),
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

  Future<void> _confirmClearData(BuildContext context) async {
    final cs = Theme.of(context).colorScheme;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.warning_amber_rounded, color: cs.error, size: 28),
        title: const Text('清除所有数据？'),
        content: const Text('此操作不可撤销，所有角色、群组、消息和 API 配置将被永久删除。'),
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
      await db.clearAllData();
      ref.invalidate(apiConfigsProvider);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('所有数据已清除'), behavior: SnackBarBehavior.floating),
        );
      }
    }
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final ColorScheme cs;
  const _SectionHeader({required this.title, required this.cs});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(title,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: cs.primary,
                letterSpacing: 0.3)),
        const SizedBox(width: 12),
        Expanded(child: Divider(color: cs.outlineVariant, thickness: 0.5)),
      ],
    );
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
        config.apiKey.isNotEmpty ? 'API Key 已保存 ••••••••' : '未设置 API Key';

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
                    Text(config.name,
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: cs.onSurface)),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: pColor.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(label,
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                              color: pColor)),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
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
        color: pColor.withOpacity(0.14),
        border: Border.all(color: pColor.withOpacity(0.3), width: 1.5),
      ),
      child: Center(
          child: Text(config.name.isNotEmpty ? config.name[0] : '?',
              style: TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w600, color: pColor))),
    );
  }
}

class _SettingTile extends StatelessWidget {
  final ColorScheme cs;
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Widget? trailing;

  const _SettingTile({
    required this.cs,
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(icon, size: 22, color: iconColor),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: cs.onSurface)),
                  Text(subtitle,
                      style:
                          TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                size: 20, color: cs.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

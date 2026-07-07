import 'dart:math';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/features/ai_character/providers/ai_character_providers.dart';
import 'package:chat_group/features/settings/providers/api_config_providers.dart';
import 'package:chat_group/features/settings/api_config_form_page.dart';
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

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final characters = ref.watch(aiCharactersProvider);
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
                gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: const [Color(0xFF8B5CF6), Color(0xFF6366F1), Color(0xFF3B82F6)]),
                borderRadius: BorderRadius.circular(9),
              ),
              child: const Icon(Icons.settings_rounded, size: 18, color: Colors.white),
            ),
            const SizedBox(width: 12),
            Text('设置', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 22, color: cs.onSurface)),
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
                      gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: const [Color(0xFF8B5CF6), Color(0xFF6366F1), Color(0xFF3B82F6)]),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.smart_toy_rounded, size: 24, color: Colors.white),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('AI 群聊模拟器', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: cs.onSurface)),
                        Text('v1.0.0 · 本地存储', style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
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
          Text('管理 API Key、Base URL 和模型，角色可复用配置', style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
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
                        Icon(Icons.settings_remote_outlined, size: 40, color: cs.onSurfaceVariant.withOpacity(0.4)),
                        const SizedBox(height: 12),
                        Text('还没有 API 配置', style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant)),
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
          _SectionHeader(title: 'API Key 测试', cs: cs),
          const SizedBox(height: 4),
          Text('选择角色测试其 API 配置是否可用', style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
          const SizedBox(height: 12),

          if (characters.isEmpty)
            AppCard(
              cs: cs,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Center(
                    child: Text('还没有角色，请先创建', style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant)),
                  ),
                ),
              ],
            )
          else
            ...characters.map((c) => _ApiTestCard(
                  character: c,
                  cs: cs,
                  onTest: () => _testCharacterApi(context, c),
                )),

          const SizedBox(height: 28),
          _SectionHeader(title: '数据管理', cs: cs),
          const SizedBox(height: 12),
          AppCard(
            cs: cs,
            margin: EdgeInsets.zero,
            children: [
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

  Future<void> _confirmDeleteConfig(BuildContext context, ApiConfig config) async {
    final cs = Theme.of(context).colorScheme;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.warning_amber_rounded, color: cs.error, size: 28),
        title: Text('删除「${config.name}」？'),
        content: const Text('此操作不可撤销，使用该配置的角色将无法回复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
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
          SnackBar(content: Text('「${config.name}」已删除'), behavior: SnackBarBehavior.floating),
        );
      }
    }
  }

  Future<void> _testApiKey(BuildContext context, ApiConfig config) async {
    final provider = ApiProvider.values.firstWhere(
      (p) => p.name == config.provider,
      orElse: () => ApiProvider.deepseek,
    );

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2.5)),
        title: Text('正在测试 ${config.name}...'),
        content: const SizedBox(height: 4),
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
          icon: Icon(Icons.error_outline_rounded, color: Theme.of(context).colorScheme.error, size: 28),
          title: Text('${config.name} 测试失败'),
          content: Text(result['message'] ?? '未知错误'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
          ],
        ),
      );
    }
  }

  Future<void> _testCharacterApi(BuildContext context, AICharacter character) async {
    final db = ref.read(databaseServiceProvider);
    final config = character.apiConfigId.isNotEmpty
        ? db.apiConfigBox.get(character.apiConfigId)
        : null;

    if (config == null) {
      if (!context.mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: Icon(Icons.warning_amber_rounded, color: Theme.of(context).colorScheme.error, size: 28),
          title: Text('${character.name} 未配置 API'),
          content: const Text('该角色没有关联的 API 配置'),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭'))],
        ),
      );
      return;
    }

    final provider = ApiProvider.values.firstWhere(
      (p) => p.name == config.provider,
      orElse: () => ApiProvider.deepseek,
    );

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2.5)),
        title: Text('正在测试 ${character.name} 的 API...'),
        content: const SizedBox(height: 4),
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
          content: Text('${character.name} API 测试成功！${result['reply'] ?? ''}'),
          backgroundColor: const Color(0xFF059669),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } else {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: Icon(Icons.error_outline_rounded, color: Theme.of(context).colorScheme.error, size: 28),
          title: Text('${character.name} API 测试失败'),
          content: Text(result['message'] ?? '未知错误'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
          ],
        ),
      );
    }
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
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
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
      await db.apiConfigBox.clear();
      await db.aiCharacterBox.clear();
      await db.chatGroupBox.clear();
      await db.messageBox.clear();
      await db.groupMemoryBox.clear();
      ref.invalidate(apiConfigsProvider);
      ref.invalidate(aiCharactersProvider);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('所有数据已清除'), behavior: SnackBarBehavior.floating),
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
        Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: cs.primary, letterSpacing: 0.3)),
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

  const _ApiConfigCard({required this.config, required this.cs, required this.onEdit, required this.onDelete, required this.onTest});

  @override
  Widget build(BuildContext context) {
    final pColor = providerColor(config.provider);
    final label = providerLabel(config.provider);
    final maskedKey = config.apiKey.isNotEmpty
        ? '${config.apiKey.substring(0, min(8, config.apiKey.length))}${'*' * max(4, config.apiKey.length - 8)}'
        : '未设置';

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
                    Text(config.name, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: cs.onSurface)),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: pColor.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: pColor)),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(maskedKey, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant, fontFamily: 'monospace')),
              ],
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: Icon(Icons.bolt_rounded, size: 18, color: cs.primary),
                onPressed: onTest,
                tooltip: '测试',
              ),
              IconButton(
                icon: Icon(Icons.edit_outlined, size: 18, color: cs.onSurfaceVariant),
                onPressed: onEdit,
                tooltip: '编辑',
              ),
              IconButton(
                icon: Icon(Icons.delete_outline_rounded, size: 18, color: cs.error),
                onPressed: onDelete,
                tooltip: '删除',
              ),
            ],
          ),
        ],
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
      child: Center(child: Text(config.name.isNotEmpty ? config.name[0] : '?', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: pColor))),
    );
  }
}

class _ApiTestCard extends StatelessWidget {
  final AICharacter character;
  final ColorScheme cs;
  final VoidCallback onTest;

  const _ApiTestCard({required this.character, required this.cs, required this.onTest});

  @override
  Widget build(BuildContext context) {
    final pColor = providerColor(character.apiProvider);
    final label = providerLabel(character.apiProvider);

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
                    Text(character.name, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: cs.onSurface)),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: pColor.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: pColor)),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(character.apiProvider, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant, fontFamily: 'monospace')),
              ],
            ),
          ),
          FilledButton.icon(
            onPressed: onTest,
            icon: const Icon(Icons.bolt_rounded, size: 16),
            label: const Text('测试', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            style: FilledButton.styleFrom(
              backgroundColor: cs.primary,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAvatar(Color pColor) {
    final display = character.avatar.isNotEmpty ? character.avatar : (character.name.isNotEmpty ? character.name[0] : '?');
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: pColor.withOpacity(0.14),
        border: Border.all(color: pColor.withOpacity(0.3), width: 1.5),
      ),
      child: Center(child: Text(display, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: pColor))),
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

  const _SettingTile({
    required this.cs,
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
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
                  Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: cs.onSurface)),
                  Text(subtitle, style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, size: 20, color: cs.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

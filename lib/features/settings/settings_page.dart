import 'dart:io';

import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/database/data_lifecycle_models.dart';
import 'package:chat_group/core/database/data_lifecycle_service.dart';
import 'package:chat_group/features/settings/providers/api_config_providers.dart';
import 'package:chat_group/features/ai_character/providers/ai_character_providers.dart';
import 'package:chat_group/features/chat_group/providers/chat_group_providers.dart';
import 'package:chat_group/features/settings/ai_processing_directory_policy.dart';
import 'package:chat_group/features/settings/api_config_form_page.dart';
import 'package:chat_group/features/memory/memory_management_page.dart';
import 'package:chat_group/features/memory/memory_audit_filter.dart';
import 'package:chat_group/features/settings/export_page.dart';
import 'package:chat_group/features/settings/backup_restore_page.dart';
import 'package:chat_group/features/settings/user_profile_page.dart';
import 'package:chat_group/features/settings/ai_governance_page.dart';
import 'package:chat_group/features/memory/relationship_audit_page.dart';
import 'package:chat_group/features/document/document_understanding_service.dart';
import 'package:chat_group/features/search/global_search_page.dart';
import 'package:chat_group/features/ai_governance/ai_governance_store.dart';
import 'package:chat_group/features/ai_governance/ai_request_gateway.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:chat_group/services/ai_providers/ai_api_service.dart';
import 'package:chat_group/core/theme/app_theme.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:chat_group/core/theme/provider_style.dart';
import 'package:chat_group/core/widgets/app_widgets.dart';
import 'package:chat_group/core/widgets/data_lifecycle_result_dialog.dart';
import 'package:chat_group/core/widgets/top_toast.dart';
import 'package:chat_group/core/storage/secure_storage_service.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';

class _WeComField extends StatelessWidget {
  final ColorScheme cs;
  final String label;
  final TextEditingController controller;
  final bool obscure;

  const _WeComField({
    required this.cs,
    required this.label,
    required this.controller,
    this.obscure = false,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: cs.onSurfaceVariant),
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    );
  }
}

class _WeComConfigCard extends ConsumerStatefulWidget {
  const _WeComConfigCard();

  @override
  ConsumerState<_WeComConfigCard> createState() => _WeComConfigCardState();
}

class _WeComConfigCardState extends ConsumerState<_WeComConfigCard> {
  final _corpIdCtl = TextEditingController();
  final _corpSecretCtl = TextEditingController();
  final _agentIdCtl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cfg = await SecureStorageService().getWeComAppConfig();
    if (cfg != null && mounted) {
      _corpIdCtl.text = cfg['corpid'] ?? '';
      _corpSecretCtl.text = cfg['corpsecret'] ?? '';
      _agentIdCtl.text = cfg['agentid'] ?? '';
    }
  }

  @override
  void dispose() {
    _corpIdCtl.dispose();
    _corpSecretCtl.dispose();
    _agentIdCtl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final cfg = {
      'corpid': _corpIdCtl.text.trim(),
      'corpsecret': _corpSecretCtl.text.trim(),
      'agentid': _agentIdCtl.text.trim(),
    };
    if (cfg['corpid']!.isEmpty ||
        cfg['corpsecret']!.isEmpty ||
        cfg['agentid']!.isEmpty) {
      AppToast.show(context, '请填写完整的 corpid / corpsecret / agentid');
      return;
    }
    await SecureStorageService().saveWeComAppConfig(cfg);
    if (mounted) {
      AppToast.show(context, '企业微信推送配置已保存', icon: Icons.check);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AppCard(
      cs: cs,
      margin: EdgeInsets.zero,
      children: [
        _WeComField(cs: cs, label: 'Corp ID', controller: _corpIdCtl),
        const SizedBox(height: 12),
        _WeComField(
            cs: cs,
            label: 'Corp Secret',
            controller: _corpSecretCtl,
            obscure: true),
        const SizedBox(height: 12),
        _WeComField(cs: cs, label: 'Agent ID', controller: _agentIdCtl),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.save_outlined, size: 18),
            label: const Text('保存配置'),
          ),
        ),
      ],
    );
  }
}

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  late final AiApiService _apiService;
  final _credentialResolver = SecureApiCredentialResolver();
  AppSkinMode _currentSkinMode = AppSkinMode.dark;
  bool _isTtsEnabled = true;
  Map<String, dynamic> _tokenUsage = {};
  String _aiProcessingDirPath = '';
  MediaUsage _mediaUsage = MediaUsage.empty;
  bool _hasPendingDeletion = false;
  bool _isCleaningMedia = false;

  @override
  void initState() {
    super.initState();
    final db = ref.read(databaseServiceProvider);
    _apiService = AiApiService(
      AiRequestGateway(store: AiGovernanceStore.forDatabase(db)),
    );
    _currentSkinMode = db.savedAppSkinMode;
    _isTtsEnabled = db.isTtsEnabled;
    _tokenUsage = db.getTokenUsage();
    _loadAiProcessingDirPath();
    _loadLifecycleState();
  }

  Future<void> _loadLifecycleState() async {
    final service = DataLifecycleService(db: ref.read(databaseServiceProvider));
    final usage = await service.mediaUsage();
    if (!mounted) return;
    setState(() {
      _mediaUsage = usage;
      _hasPendingDeletion = service.hasPendingOperation;
    });
  }

  Future<void> _loadAiProcessingDirPath() async {
    final db = ref.read(databaseServiceProvider);
    final path = await resolveAiProcessingDirectoryLabel(
      isWeb: kIsWeb,
      nativePathLoader: db.effectiveAiProcessingDirPath,
    );
    if (mounted) {
      setState(() => _aiProcessingDirPath = path);
    }
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
                        Text('v1.1.0 · 本地存储',
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
          _SectionHeader(
            title: 'API 配置',
            cs: cs,
            action: _buildAddConfigButton(cs),
          ),
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
                            color: cs.onSurfaceVariant.withValues(alpha: 0.4)),
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
          const SizedBox(height: 12),
          AppCard(
            cs: cs,
            margin: EdgeInsets.zero,
            children: [
              _SettingTile(
                cs: cs,
                icon: Icons.manage_search_rounded,
                iconColor: cs.primary,
                title: '全局搜索',
                subtitle: '离线搜索群聊、私聊、角色名和附件文件名；可清除与重建索引',
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const GlobalSearchPage(),
                )),
              ),
              Divider(
                  height: 1, color: cs.outlineVariant.withValues(alpha: 0.5)),
              _SettingTile(
                cs: cs,
                icon: Icons.document_scanner_outlined,
                iconColor: cs.primary,
                title: '文档解析缓存',
                subtitle:
                    '${DocumentUnderstandingService.cachedDocumentCount} 个本地文档 · 可随时清除并按需重建',
                onTap: _showDocumentCache,
              ),
              Divider(
                  height: 1, color: cs.outlineVariant.withValues(alpha: 0.5)),
              _SettingTile(
                cs: cs,
                icon: Icons.policy_outlined,
                iconColor: cs.primary,
                title: '模型、成本与联网治理',
                subtitle: '能力注册表、预算、费用账本、联网策略与脱敏诊断',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const AiGovernancePage()),
                ),
              ),
            ],
          ),
          const SizedBox(height: 28),
          _SectionHeader(
            title: '企业微信推送',
            cs: cs,
          ),
          const SizedBox(height: 4),
          const Text('配置自建应用 corpid/corpsecret/agentid，即可在聊天页把消息推送给同事或群',
              style: TextStyle(fontSize: 13, color: Color(0xFF888888))),
          const SizedBox(height: 12),
          const _WeComConfigCard(),
          const SizedBox(height: 28),
          _SectionHeader(
            title: '我的资料',
            cs: cs,
          ),
          const SizedBox(height: 4),
          Text('编辑你的全球显示名和人物信息卡',
              style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
          const SizedBox(height: 12),
          AppCard(
            cs: cs,
            margin: EdgeInsets.zero,
            children: [
              _SettingTile(
                cs: cs,
                icon: Icons.person_outline_rounded,
                iconColor: cs.primary,
                title: _buildProfileTitle(cs),
                subtitle: _buildProfileSubtitle(cs),
                onTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const UserProfilePage()),
                  );
                  if (mounted) setState(() {});
                },
              ),
            ],
          ),
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
                subtitle: _skinLabel(_currentSkinMode),
                onTap: () {},
                trailing: SegmentedButton<AppSkinMode>(
                  segments: const [
                    ButtonSegment(
                        value: AppSkinMode.light,
                        label: Icon(Icons.light_mode_rounded, size: 18),
                        tooltip: '浅色'),
                    ButtonSegment(
                        value: AppSkinMode.system,
                        label: Icon(Icons.brightness_auto_rounded, size: 18),
                        tooltip: '跟随系统'),
                    ButtonSegment(
                        value: AppSkinMode.dark,
                        label: Icon(Icons.dark_mode_rounded, size: 18),
                        tooltip: '深色'),
                    ButtonSegment(
                        value: AppSkinMode.golden,
                        label: Icon(Icons.workspace_premium_rounded, size: 18),
                        tooltip: '黄金'),
                  ],
                  selected: {_currentSkinMode},
                  onSelectionChanged: (Set<AppSkinMode> sel) {
                    final mode = sel.first;
                    setState(() => _currentSkinMode = mode);
                    ref.read(appSkinModeProvider.notifier).setSkin(mode);
                  },
                ),
              ),
              Divider(
                  height: 1, color: cs.outlineVariant.withValues(alpha: 0.5)),
              _SettingTile(
                cs: cs,
                icon: Icons.volume_up_outlined,
                iconColor: cs.tertiary,
                title: '语音朗读',
                subtitle: _isTtsEnabled
                    ? '已开启 · 右键或长按 AI 消息后选择“朗读”，使用系统语音'
                    : '已关闭 · 开启后可从消息操作菜单朗读 AI 回复',
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
          _SectionHeader(title: 'AI 工作根目录', cs: cs),
          const SizedBox(height: 12),
          AppCard(
            cs: cs,
            margin: EdgeInsets.zero,
            children: [
              _SettingTile(
                cs: cs,
                icon: Icons.folder_open_rounded,
                iconColor: cs.secondary,
                title: '工作根目录',
                subtitle: _aiProcessingDirPath.isEmpty
                    ? '正在读取目录...'
                    : kIsWeb
                        ? _aiProcessingDirPath
                        : _compactPath(_aiProcessingDirPath),
                onTap: kIsWeb ? null : _chooseAiProcessingDir,
              ),
              if (!kIsWeb) ...[
                Divider(
                    height: 1, color: cs.outlineVariant.withValues(alpha: 0.5)),
                _SettingTile(
                  cs: cs,
                  icon: Icons.restore_rounded,
                  iconColor: cs.secondary,
                  title: '恢复默认目录',
                  subtitle: '默认作为 AI 工具服务 workspace，保存在应用数据目录的 ai_files 中',
                  onTap: _resetAiProcessingDir,
                ),
              ],
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
              Divider(
                  height: 1, color: cs.outlineVariant.withValues(alpha: 0.5)),
              _SettingTile(
                cs: cs,
                icon: Icons.backup_rounded,
                iconColor: cs.primary,
                title: '完整备份与恢复',
                subtitle: '版本化备份、导入预览、冲突处理与失败回滚（不含 API Key）',
                onTap: _openBackupRestore,
              ),
              Divider(
                  height: 1, color: cs.outlineVariant.withValues(alpha: 0.5)),
              _SettingTile(
                cs: cs,
                icon: Icons.memory_rounded,
                iconColor: cs.primary,
                title: '永久记忆审计',
                subtitle: '查看和管理所有 AI 的全局永久记忆',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                      builder: (_) => const MemoryManagementPage(
                            scope: MemoryConversationScope.settings(),
                          )),
                ),
              ),
              Divider(
                  height: 1, color: cs.outlineVariant.withValues(alpha: 0.5)),
              _SettingTile(
                cs: cs,
                icon: Icons.account_tree_outlined,
                iconColor: cs.primary,
                title: '关系审计',
                subtitle: '查看全局方向关系、事件时间线并管理人工状态',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const RelationshipAuditPage(),
                  ),
                ),
              ),
              Divider(
                  height: 1, color: cs.outlineVariant.withValues(alpha: 0.5)),
              _SettingTile(
                cs: cs,
                icon: Icons.info_outline_rounded,
                iconColor: cs.primary,
                title: '关于',
                subtitle: '查看应用信息与开源许可',
                onTap: () {},
              ),
              Divider(
                  height: 1, color: cs.outlineVariant.withValues(alpha: 0.5)),
              _SettingTile(
                cs: cs,
                icon: Icons.cleaning_services_rounded,
                iconColor: cs.secondary,
                title: '媒体占用',
                subtitle: '${_formatBytes(_mediaUsage.totalBytes)} · '
                    '${_mediaUsage.orphanFiles} 个孤儿文件可清理',
                onTap: _isCleaningMedia ? null : _cleanupOrphanMedia,
              ),
              if (_hasPendingDeletion) ...[
                Divider(
                    height: 1, color: cs.outlineVariant.withValues(alpha: 0.5)),
                _SettingTile(
                  cs: cs,
                  icon: Icons.sync_problem_rounded,
                  iconColor: cs.error,
                  title: '重试未完成删除',
                  subtitle: '上次删除部分完成；重试是幂等操作',
                  onTap: _retryPendingDeletion,
                ),
              ],
              Divider(
                  height: 1, color: cs.outlineVariant.withValues(alpha: 0.5)),
              _SettingTile(
                cs: cs,
                icon: Icons.forum_outlined,
                iconColor: cs.error,
                title: '清除聊天内容',
                subtitle: '删除消息、记忆、关系、任务和会话状态；保留角色、群聊、API 配置及偏好',
                onTap: () =>
                    _confirmClearData(context, DataClearScope.chatContent),
              ),
              Divider(
                  height: 1, color: cs.outlineVariant.withValues(alpha: 0.5)),
              _SettingTile(
                cs: cs,
                icon: Icons.delete_sweep_outlined,
                iconColor: cs.error,
                title: '清除全部用户内容',
                subtitle: '另删除角色、群聊、技能和 API 配置；保留主题、TTS 和目录偏好',
                onTap: () =>
                    _confirmClearData(context, DataClearScope.userContent),
              ),
              Divider(
                  height: 1, color: cs.outlineVariant.withValues(alpha: 0.5)),
              _SettingTile(
                cs: cs,
                icon: Icons.restart_alt_rounded,
                iconColor: cs.error,
                title: '恢复出厂设置',
                subtitle: '删除全部用户内容，并重置主题、TTS、目录等偏好',
                onTap: () =>
                    _confirmClearData(context, DataClearScope.factoryReset),
              ),
            ],
          ),
          const SizedBox(height: 32),
        ],
      ),
      bottomNavigationBar: AppBottomNav(currentIndex: 3, cs: cs),
    );
  }

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
      if (mounted) setState(() {});
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

  Widget _buildTokenSection(ColorScheme cs) {
    final totalInput = _tokenUsage['totalInput'] ?? 0;
    final totalOutput = _tokenUsage['totalOutput'] ?? 0;
    final totalCachedInput = _tokenUsage['totalCachedInput'] ?? 0;
    final requestCount = _tokenUsage['requestCount'] ?? 0;
    final byChar = _tokenUsage['byCharacter'] is Map
        ? Map<String, dynamic>.from(_tokenUsage['byCharacter'] as Map)
        : <String, dynamic>{};
    final byGroup = _tokenUsage['byGroup'] is Map
        ? Map<String, dynamic>.from(_tokenUsage['byGroup'] as Map)
        : <String, dynamic>{};
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
            Divider(height: 1, color: cs.outlineVariant.withValues(alpha: 0.5)),
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
            Divider(height: 1, color: cs.outlineVariant.withValues(alpha: 0.5)),
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
            Divider(height: 1, color: cs.outlineVariant.withValues(alpha: 0.5)),
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
              Divider(
                  height: 1, color: cs.outlineVariant.withValues(alpha: 0.5)),
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
              Divider(
                  height: 1, color: cs.outlineVariant.withValues(alpha: 0.5)),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Text('各角色消耗',
                    style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurfaceVariant,
                        fontWeight: FontWeight.w600)),
              ),
              ...byChar.entries.map((entry) {
                final data = entry.value is Map
                    ? Map<String, dynamic>.from(entry.value as Map)
                    : <String, dynamic>{};
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
                      AppToast.show(context, 'Token 统计已清零',
                          icon: Icons.refresh_rounded);
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
      setState(() => _aiProcessingDirPath = path);
      AppToast.show(context, 'AI 工作根目录已更新', icon: Icons.folder_open_rounded);
    } catch (e) {
      if (!mounted) return;
      AppToast.show(context, '选择目录失败：$e', icon: Icons.error_outline_rounded);
    }
  }

  Future<void> _resetAiProcessingDir() async {
    final db = ref.read(databaseServiceProvider);
    await db.resetAiProcessingDirPath();
    final path = await db.effectiveAiProcessingDirPath();
    if (!mounted) return;
    setState(() => _aiProcessingDirPath = path);
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
    final service = DataLifecycleService(db: ref.read(databaseServiceProvider));
    final plan = await service.previewClear(scope);
    if (!context.mounted) return;
    final (title, description) = switch (scope) {
      DataClearScope.chatContent => (
          '清除聊天内容？',
          '将永久删除消息、附件、记忆、关系、任务、工作区记录和会话状态。角色、群聊、API 配置、主题、TTS 和目录偏好会保留。',
        ),
      DataClearScope.userContent => (
          '清除全部用户内容？',
          '将永久删除聊天内容、角色、群聊、技能、API 配置及安全凭据。主题、TTS 和目录偏好会保留。',
        ),
      DataClearScope.factoryReset => (
          '恢复出厂设置？',
          '将永久删除全部用户内容及安全凭据，并重置主题、TTS、目录等所有偏好。',
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
      '${plan.count('attachments')} 个附件',
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
    ];
    if (scope != DataClearScope.chatContent) {
      entries.addAll([
        '凭据 ${plan.count('credentials')} 个',
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
    setState(() {
      _currentSkinMode = db.savedAppSkinMode;
      _isTtsEnabled = db.isTtsEnabled;
    });
    await _loadLifecycleState();
  }

  Future<void> _cleanupOrphanMedia() async {
    setState(() => _isCleaningMedia = true);
    final result = await DataLifecycleService(
      db: ref.read(databaseServiceProvider),
    ).cleanupOrphanMedia();
    await _loadLifecycleState();
    if (!mounted) return;
    setState(() => _isCleaningMedia = false);
    if (result.isComplete) {
      AppToast.show(context, '已清理 ${result.reclaimedFiles} 个孤儿附件',
          icon: Icons.cleaning_services_rounded);
    } else {
      await showIncompleteDeletionDialog(context, result);
    }
  }

  Future<void> _retryPendingDeletion() async {
    final result = await DataLifecycleService(
      db: ref.read(databaseServiceProvider),
    ).retryPendingOperation();
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

  String _buildProfileTitle(ColorScheme cs) {
    try {
      final name = ref
          .read(databaseServiceProvider)
          .userProfileBox
          .get('me')
          ?.displayName
          .trim();
      if (name != null && name.isNotEmpty) return name;
    } on Object {
      // Box not yet opened in test environments.
    }
    return '我';
  }

  String _buildProfileSubtitle(ColorScheme cs) {
    try {
      final profile =
          ref.read(databaseServiceProvider).userProfileBox.get('me');
      if (profile == null) return '尚未设置人物信息卡';
      final parts = <String>[];
      if (profile.preferredAddress.trim().isNotEmpty) {
        parts.add('称呼：${profile.preferredAddress.trim()}');
      }
      if (profile.bio.trim().isNotEmpty) {
        parts.add(profile.bio.trim());
      }
      if (profile.interests.isNotEmpty) {
        parts.add('兴趣：${profile.interests.join('、')}');
      }
      if (parts.isEmpty) return '点击编辑你的资料';
      return parts.join(' · ');
    } on Object {
      return '尚未设置人物信息卡';
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final ColorScheme cs;
  final Widget? action;
  const _SectionHeader({required this.title, required this.cs, this.action});

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
        if (action != null) ...[
          const SizedBox(width: 10),
          action!,
        ],
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
                        color: pColor.withValues(alpha: 0.12),
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

class _SettingTile extends StatelessWidget {
  final ColorScheme cs;
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
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
            if (trailing != null)
              trailing!
            else if (onTap != null)
              Icon(Icons.chevron_right_rounded,
                  size: 20, color: cs.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

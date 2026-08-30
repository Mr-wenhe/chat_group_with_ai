part of 'settings_page.dart';

extension _SettingsPageBuild on _SettingsPageState {
  Widget _buildPage(BuildContext context) {
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
                  if (mounted) _safeSetState(() {});
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
                    _safeSetState(() => _currentSkinMode = mode);
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
                    _safeSetState(() => _isTtsEnabled = v);
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
          _SectionHeader(title: '工作模式 AI Agent', cs: cs),
          const SizedBox(height: 12),
          WorkModeAgentSettingsSection(
            service: _workFolderGrantService,
            snapshotService: _tryReadWorkSnapshotService(),
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
}

import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/database/data_lifecycle_models.dart';
import 'package:chat_group/core/database/data_lifecycle_service.dart';
import 'package:chat_group/core/models/character_presets.dart';
import 'package:chat_group/features/ai_character/action_skill_count.dart';
import 'package:chat_group/features/direct_chat/pinned_ordering.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'ai_character_form_page.dart';
import 'providers/ai_character_providers.dart';
import 'package:chat_group/core/theme/app_theme.dart';
import 'package:chat_group/core/theme/provider_style.dart';
import 'package:chat_group/core/widgets/app_widgets.dart';
import 'package:chat_group/core/widgets/data_lifecycle_result_dialog.dart';
import 'package:chat_group/core/widgets/top_toast.dart';
import 'package:chat_group/features/chat_group/providers/chat_group_providers.dart';
import 'package:chat_group/features/settings/providers/api_config_providers.dart';

class AICharacterListPage extends ConsumerStatefulWidget {
  const AICharacterListPage({super.key});

  @override
  ConsumerState<AICharacterListPage> createState() =>
      _AICharacterListPageState();
}

class _AICharacterListPageState extends ConsumerState<AICharacterListPage> {
  final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final db = ref.read(databaseServiceProvider);
    final characters = ref.watch(aiCharactersProvider);
    final query = _searchController.text.trim().toLowerCase();
    final filteredCharacters = query.isEmpty
        ? characters
        : characters.where((c) {
            final haystack =
                '${c.name} ${c.gender.label} ${c.role} ${c.personalityTags.join(' ')}'
                    .toLowerCase();
            return haystack.contains(query);
          }).toList();
    final pinnedIds = db.pinnedCharacterIds();
    final orderedCharacters = PinnedOrdering.sortCharacters(
      filteredCharacters,
      pinnedIds: pinnedIds,
    );
    // 获取全部 API 配置，用于「批量替换模型」工具栏；少于 2 个配置时无替换意义
    final apiConfigs = ref.watch(apiConfigsProvider);
    final groups = ref.watch(chatGroupsProvider);
    // 构建 id → ApiConfig 映射，供卡片按 apiConfigId 查找关联配置（Bug 4）
    final configMap = {for (final c in apiConfigs) c.id: c};

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
                gradient: AppTheme.primaryGradient,
                borderRadius: BorderRadius.circular(9),
              ),
              child: const Icon(Icons.smart_toy_rounded,
                  size: 18, color: Colors.white),
            ),
            const SizedBox(width: 12),
            Text('AI 角色',
                style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 22,
                    color: cs.onSurface)),
          ],
        ),
      ),
      body: Column(
        children: [
          if (apiConfigs.isEmpty || characters.isEmpty || groups.isEmpty)
            _buildSetupChecklist(context, cs,
                hasConfig: apiConfigs.isNotEmpty,
                hasCharacter: characters.isNotEmpty,
                hasGroup: groups.isNotEmpty),
          // 存在 ≥2 个配置时才支持批量替换（只有一个配置没有替换目标）
          if (apiConfigs.length >= 2)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
              child: Row(
                children: [
                  Icon(Icons.swap_horiz_rounded, size: 16, color: cs.primary),
                  const SizedBox(width: 6),
                  Text('批量将使用某模型的角色换为另一模型',
                      style:
                          TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: () => _batchReplaceConfig(context, ref),
                    icon: const Icon(Icons.sync_alt_rounded, size: 14),
                    label: const Text('批量替换', style: TextStyle(fontSize: 12)),
                    style: TextButton.styleFrom(foregroundColor: cs.primary),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
            child: TextField(
              controller: _searchController,
              decoration: appInputDecoration(
                '搜索角色',
                '按名字、角色或标签搜索',
                Icons.search_rounded,
                cs,
              ).copyWith(
                suffixIcon: _searchController.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close_rounded, size: 18),
                        tooltip: '清空搜索',
                        onPressed: () {
                          _searchController.clear();
                          setState(() {});
                        },
                      ),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          Expanded(
            child: characters.isEmpty
                ? _buildEmptyState(cs)
                : orderedCharacters.isEmpty
                    ? Center(
                        child: Text('未找到匹配角色',
                            style: TextStyle(
                                fontSize: 14, color: cs.onSurfaceVariant)),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.all(20),
                        itemCount: orderedCharacters.length,
                        itemBuilder: (context, index) {
                          final character = orderedCharacters[index];
                          return _CharacterCard(
                            character: character,
                            cs: cs,
                            isPinned: pinnedIds.contains(character.id),
                            onTap: () => _editCharacter(context, character),
                            onDelete: () =>
                                _confirmDelete(context, ref, character),
                            onTogglePin: () =>
                                _togglePinnedCharacter(character.id),
                            onToggle: () {
                              character.isActive = !character.isActive;
                              character.save();
                              ref.invalidate(aiCharactersProvider);
                            },
                            // 点击模型标签可单独切换该角色关联的 API 配置（Bug 2/4）
                            onConfigChange: () =>
                                _changeSingleConfig(context, ref, character),
                            // 传入关联配置：优先显示配置名而非角色旧 provider 名（Bug 4）
                            linkedConfig: configMap[character.apiConfigId],
                            onDirectChat: () =>
                                _openDirectChat(context, character),
                          );
                        },
                      ),
          ),
        ],
      ),
      floatingActionButton: AppFab(
        onPressed: () => _addCharacter(context),
        icon: Icons.add_rounded,
        label: '创建角色',
      ),
      bottomNavigationBar: AppBottomNav(currentIndex: 0, cs: cs),
    );
  }

  Widget _buildSetupChecklist(
    BuildContext context,
    ColorScheme cs, {
    required bool hasConfig,
    required bool hasCharacter,
    required bool hasGroup,
  }) {
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 8, 20, 4),
      padding: const EdgeInsets.all(14),
      decoration: AppCard.decoration(cs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.route_rounded, size: 18, color: cs.primary),
              const SizedBox(width: 8),
              Text('开始使用',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: cs.onSurface)),
            ],
          ),
          const SizedBox(height: 10),
          _setupStep(cs, hasConfig, '创建 API 配置', () {
            Navigator.pushNamed(context, '/settings');
          }),
          _setupStep(
              cs, hasCharacter, '创建 AI 角色', () => _addCharacter(context)),
          _setupStep(cs, hasGroup, '创建群聊并发送第一条消息', () {
            Navigator.pushReplacementNamed(context, '/groups');
          }),
        ],
      ),
    );
  }

  Widget _setupStep(
      ColorScheme cs, bool done, String label, VoidCallback onTap) {
    return InkWell(
      onTap: done ? null : onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Icon(
                done
                    ? Icons.check_circle_rounded
                    : Icons.radio_button_unchecked,
                size: 17,
                color: done ? cs.primary : cs.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Text(label,
                  style: TextStyle(
                      fontSize: 13,
                      color: done ? cs.onSurfaceVariant : cs.onSurface)),
            ),
            if (!done)
              Icon(Icons.chevron_right_rounded,
                  size: 18, color: cs.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(ColorScheme cs) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              color: cs.primaryContainer.withValues(alpha: 0.5),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.person_add_rounded, size: 44, color: cs.primary),
          ),
          const SizedBox(height: 24),
          Text('还没有 AI 角色',
              style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface)),
          const SizedBox(height: 8),
          Text('点击右下角创建你的第一个 AI',
              style: TextStyle(fontSize: 14, color: cs.onSurfaceVariant)),
        ],
      ),
    );
  }

  /// FAB 入口：弹出「从空白创建 / 用预设快速创建」菜单。
  void _addCharacter(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    showModalBottomSheet(
      context: context,
      backgroundColor: cs.surface,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.add_rounded, color: cs.primary),
              title: const Text('从空白创建'),
              subtitle: const Text('从零填写角色信息'),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const AICharacterFormPage()));
              },
            ),
            ListTile(
              leading: Icon(Icons.auto_awesome_rounded, color: cs.primary),
              title: const Text('用预设快速创建'),
              subtitle: const Text('套用内置人设模板'),
              onTap: () {
                Navigator.pop(ctx);
                _quickCreateFromPreset(context);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 从预设库选择 → 跳转到已预填的表单页（仍要求选 ApiConfig）。
  Future<void> _quickCreateFromPreset(BuildContext context) async {
    final preset = await _showPresetPicker(context);
    if (preset != null && context.mounted) {
      Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => AICharacterFormPage(preset: preset)));
    }
  }

  /// 预设选择底部弹窗，返回选中的 [CharacterPreset]。
  Future<CharacterPreset?> _showPresetPicker(BuildContext context) async {
    final cs = Theme.of(context).colorScheme;
    return showModalBottomSheet<CharacterPreset>(
      context: context,
      backgroundColor: cs.surface,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.72,
        maxChildSize: 0.92,
        minChildSize: 0.4,
        expand: false,
        builder: (_, controller) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Row(
                children: [
                  Icon(Icons.auto_awesome_rounded, color: cs.primary, size: 18),
                  const SizedBox(width: 8),
                  Text('选择角色预设',
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: cs.onSurface)),
                  const Spacer(),
                  IconButton(
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => Navigator.pop(ctx),
                      tooltip: '关闭'),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: GridView.count(
                controller: controller,
                crossAxisCount: 2,
                padding: const EdgeInsets.all(16),
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 1.25,
                children: CharacterPreset.presets
                    .map((p) => _presetTile(p, cs, ctx))
                    .toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 预设网格单元（与表单页保持一致样式）。
  Widget _presetTile(CharacterPreset p, ColorScheme cs, BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      color: cs.surfaceContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => Navigator.pop(context, p),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: cs.primary.withValues(alpha: 0.12)),
                    child: Center(
                        child: Text(p.avatar,
                            style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                                color: cs.primary))),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                      child: Text(p.name,
                          style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: cs.onSurface),
                          overflow: TextOverflow.ellipsis)),
                ],
              ),
              const SizedBox(height: 8),
              Text(p.role,
                  style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
              const SizedBox(height: 6),
              Expanded(
                child: Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: p.personalityTags
                      .take(3)
                      .map((t) => Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                                color: cs.primaryContainer,
                                borderRadius: BorderRadius.circular(6)),
                            child: Text(t,
                                style: TextStyle(
                                    fontSize: 11,
                                    color: cs.onPrimaryContainer)),
                          ))
                      .toList(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _editCharacter(BuildContext context, AICharacter character) {
    Navigator.of(context).push(MaterialPageRoute(
        builder: (context) => AICharacterFormPage(character: character)));
  }

  Future<void> _openDirectChat(
    BuildContext context,
    AICharacter character,
  ) async {
    await Navigator.of(context).pushNamed('/dm/${character.id}');
    if (mounted) setState(() {});
  }

  Future<void> _togglePinnedCharacter(String characterId) async {
    await ref.read(databaseServiceProvider).togglePinnedCharacter(characterId);
    if (mounted) setState(() {});
  }

  Future<void> _confirmDelete(
      BuildContext context, WidgetRef ref, AICharacter character) async {
    final service = DataLifecycleService(db: ref.read(databaseServiceProvider));
    final plan = await service.previewCharacter(character.id);
    if (!context.mounted) return;
    var policy = CharacterDeletionPolicy.keepMessageHistory;
    var displayedPlan = plan;
    final selectedPolicy = await showDialog<CharacterDeletionPolicy>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          icon: Icon(Icons.delete_outline_rounded,
              color: Theme.of(context).colorScheme.error, size: 28),
          title: Text('删除「${character.name}」？'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '关联统计：${displayedPlan.count('groups')} 个群聊、'
                    '${displayedPlan.retainedCount('groupMessages')} 条群聊历史、'
                    '${displayedPlan.count('mentions')} 条消息提及引用。',
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '永久记忆：该 AI 作为 observer ${displayedPlan.count('observerPermanentMemories')} 条；'
                    '其他 observer 关于它 ${displayedPlan.count('subjectPermanentMemories')} 条。',
                  ),
                  Text(
                    '关系快照：作为 source ${displayedPlan.count('sourceRelationshipStates')} 条，'
                    '作为 target ${displayedPlan.count('targetRelationshipStates')} 条；'
                    '事件 source ${displayedPlan.count('sourceRelationshipEvents')} 条，'
                    'target ${displayedPlan.count('targetRelationshipEvents')} 条。',
                  ),
                  Text(
                    '角色辅助数据：${displayedPlan.count('skills')} 个技能、'
                    '${displayedPlan.count('tasks')} 个任务、'
                    '${displayedPlan.count('workspaces')} 条工作区、'
                    '${displayedPlan.count('memoryPins')} 个 memory pin、'
                    '${displayedPlan.count('retryRecords')} 条重试记录、'
                    '${displayedPlan.count('settings')} 项私聊索引/状态。',
                  ),
                  RadioListTile<CharacterDeletionPolicy>(
                    contentPadding: EdgeInsets.zero,
                    value: CharacterDeletionPolicy.keepMessageHistory,
                    groupValue: policy,
                    title: const Text('保留历史消息'),
                    subtitle: const Text(
                      '从群组移除角色，删除技能、任务、记忆和关系；群聊与私聊历史保留为只读“已删除角色”。',
                    ),
                    onChanged: (value) async {
                      if (value == null) return;
                      setDialogState(() => policy = value);
                      final next = await service.previewCharacter(
                        character.id,
                        policy: value,
                      );
                      if (context.mounted) {
                        setDialogState(() => displayedPlan = next);
                      }
                    },
                  ),
                  RadioListTile<CharacterDeletionPolicy>(
                    contentPadding: EdgeInsets.zero,
                    value: CharacterDeletionPolicy.deleteRelatedData,
                    groupValue: policy,
                    title: const Text('同时删除私聊历史'),
                    subtitle: const Text(
                      '群聊历史仍保留；私聊消息及其无其他引用的 APP 附件一并删除。',
                    ),
                    onChanged: (value) async {
                      if (value == null) return;
                      setDialogState(() => policy = value);
                      final next = await service.previewCharacter(
                        character.id,
                        policy: value,
                      );
                      if (context.mounted) {
                        setDialogState(() => displayedPlan = next);
                      }
                    },
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消')),
            FilledButton(
              onPressed: () => Navigator.pop(context, policy),
              style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error),
              child: const Text('确认删除'),
            ),
          ],
        ),
      ),
    );
    if (selectedPolicy != null) {
      final result = await ref
          .read(aiCharactersProvider.notifier)
          .deleteCharacter(character.id, policy: selectedPolicy);
      ref.invalidate(chatGroupsProvider);
      if (!result.isComplete && context.mounted) {
        await showIncompleteDeletionDialog(context, result);
      }
    }
  }

  /// 批量替换配置：选择「源配置」与「目标配置」，
  /// 将所有当前使用源配置的角色对齐到目标配置。
  /// API Key 仅由共享配置的凭据仓库持有，故角色侧 apiKey 清空。
  Future<void> _batchReplaceConfig(BuildContext context, WidgetRef ref) async {
    final cs = Theme.of(context).colorScheme;
    final apiConfigs = ref.read(apiConfigsProvider);
    final characters = ref.read(aiCharactersProvider);
    if (apiConfigs.length < 2) {
      AppToast.show(context, '至少需要两个配置才能批量替换',
          icon: Icons.info_outline_rounded);
      return;
    }

    // 每个配置当前被多少角色使用
    final usageCount = <String, int>{
      for (final c in apiConfigs) c.id: 0,
    };
    for (final ch in characters) {
      usageCount[ch.apiConfigId] = (usageCount[ch.apiConfigId] ?? 0) + 1;
    }

    // 默认源：第一个有角色使用的配置；没有则提示无角色可替换
    String sourceId = apiConfigs
        .firstWhere(
          (c) => (usageCount[c.id] ?? 0) > 0,
          orElse: () => apiConfigs.first,
        )
        .id;
    if ((usageCount[sourceId] ?? 0) == 0) {
      AppToast.show(context, '当前没有角色关联任何配置，无需替换',
          icon: Icons.info_outline_rounded);
      return;
    }
    // 默认目标：第一个不等于源的配置
    String targetId = apiConfigs.firstWhere((c) => c.id != sourceId).id;

    final result = await showDialog<({String sourceId, String targetId})>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          // 源只列有角色正在使用的配置（0 使用的配置无需替换，不作为可选源）
          final sourceCandidates = apiConfigs
              .where((c) => (usageCount[c.id] ?? 0) > 0)
              .toList(growable: false);
          // 目标下拉排除当前源，源变化时若目标==源则重置
          final targetCandidates =
              apiConfigs.where((c) => c.id != sourceId).toList();
          if (!targetCandidates.any((c) => c.id == targetId)) {
            targetId = targetCandidates.first.id;
          }
          final affected = usageCount[sourceId] ?? 0;
          final sourceConfig = apiConfigs.firstWhere((c) => c.id == sourceId);
          final targetConfig = apiConfigs.firstWhere((c) => c.id == targetId);

          return AlertDialog(
            title: const Text('批量替换模型配置'),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('源配置（当前正在使用的）',
                      style:
                          TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<String>(
                    value: sourceId,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: sourceCandidates
                        .map((c) => DropdownMenuItem(
                              value: c.id,
                              child: Text(
                                '${c.name} (${c.provider}) · ${usageCount[c.id] ?? 0} 个角色',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ))
                        .toList(),
                    onChanged: (v) {
                      if (v == null) return;
                      setDialogState(() => sourceId = v);
                    },
                  ),
                  const SizedBox(height: 14),
                  Text('目标配置（替换为）',
                      style:
                          TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<String>(
                    value: targetId,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: targetCandidates
                        .map((c) => DropdownMenuItem(
                              value: c.id,
                              child: Text('${c.name} (${c.provider})',
                                  overflow: TextOverflow.ellipsis),
                            ))
                        .toList(),
                    onChanged: (v) {
                      if (v == null) return;
                      setDialogState(() => targetId = v);
                    },
                  ),
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: cs.primaryContainer.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '将把 $affected 个使用「${sourceConfig.name}」的角色'
                      '替换为「${targetConfig.name}」（模型 ${targetConfig.modelName}）',
                      style:
                          TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
              FilledButton(
                onPressed: affected == 0
                    ? null
                    : () => Navigator.pop(
                        ctx, (sourceId: sourceId, targetId: targetId)),
                child: Text('替换 $affected 个角色'),
              ),
            ],
          );
        },
      ),
    );

    if (result == null || !context.mounted) return;
    final target = apiConfigs.firstWhere((c) => c.id == result.targetId);
    final source = apiConfigs.firstWhere((c) => c.id == result.sourceId);
    final matched = characters
        .where((c) => c.apiConfigId == result.sourceId)
        .toList(growable: false);
    for (final c in matched) {
      c.apiConfigId = target.id;
      c.apiKey = '';
      c.apiProvider = target.provider;
      c.modelName = target.modelName;
      c.customBaseUrl = target.customBaseUrl;
      c.save();
    }
    ref.invalidate(aiCharactersProvider);
    if (context.mounted) {
      AppToast.show(
        context,
        '已将 ${matched.length} 个角色从「${source.name}」替换为「${target.name}」',
        icon: Icons.sync_alt_rounded,
      );
    }
  }

  /// 单独修改某个角色关联的 API 配置：弹窗下拉选择目标配置，
  /// 选中后将该角色的全部 API 字段对齐到所选配置（Bug 2）。
  Future<void> _changeSingleConfig(
      BuildContext context, WidgetRef ref, AICharacter character) async {
    final cs = Theme.of(context).colorScheme;
    final apiConfigs = ref.read(apiConfigsProvider);
    if (apiConfigs.isEmpty) {
      if (context.mounted) {
        AppToast.show(context, '暂无可用配置，请先在设置中创建',
            icon: Icons.info_outline_rounded);
      }
      return;
    }

    // 当前已关联配置（若不存在于列表则默认选第一个），保证下拉 value 始终有效
    final initialId = character.apiConfigId.isNotEmpty &&
            apiConfigs.any((c) => c.id == character.apiConfigId)
        ? character.apiConfigId
        : apiConfigs.first.id;

    String selectedId = initialId;
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text('修改「${character.name}」的配置'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('选择要切换到的配置:',
                  style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: selectedId,
                isExpanded: true,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: apiConfigs
                    .map((c) => DropdownMenuItem(
                          value: c.id,
                          child: Text('${c.name} (${c.provider})',
                              overflow: TextOverflow.ellipsis),
                        ))
                    .toList(),
                onChanged: (v) {
                  if (v != null) setDialogState(() => selectedId = v);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, selectedId),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );

    if (result != null && context.mounted) {
      // 从配置列表中安全查找目标配置（下拉项均来自该列表，必然存在）
      final target = apiConfigs.where((c) => c.id == result).firstOrNull;
      if (target == null) return;
      character.apiConfigId = target.id;
      character.apiKey = '';
      character.apiProvider = target.provider;
      character.modelName = target.modelName;
      character.customBaseUrl = target.customBaseUrl;
      character.save();
      ref.invalidate(aiCharactersProvider);
      if (context.mounted) {
        AppToast.show(context, '已将「${character.name}」切换为「${target.name}」配置',
            icon: Icons.tune_rounded);
      }
    }
  }
}

class _CharacterCard extends StatelessWidget {
  final AICharacter character;
  final ColorScheme cs;
  final bool isPinned;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback onTogglePin;
  final VoidCallback onToggle;
  final VoidCallback onDirectChat;
  final ApiConfig? linkedConfig;
  final VoidCallback? onConfigChange;

  const _CharacterCard({
    required this.character,
    required this.cs,
    required this.isPinned,
    required this.onTap,
    required this.onDelete,
    required this.onTogglePin,
    required this.onToggle,
    required this.onDirectChat,
    this.linkedConfig,
    this.onConfigChange,
  });

  @override
  Widget build(BuildContext context) {
    final pColor = providerColor(character.apiProvider);
    final label = providerLabel(character.apiProvider);

    // 优先使用关联配置的信息（Bug 4）：若角色已关联 ApiConfig，
    // 标签与配色均以该配置为准，而非角色自身存储的旧 provider 名。
    // 用局部变量承接，确保空安全的类型提升（final 字段在三元表达式中无法直接提升）。
    final config = linkedConfig;
    final displayColor =
        config != null ? providerColor(config.provider) : pColor;
    final displayLabel = config != null ? config.name : label;
    final skillCount = actionSkillCountFor(character);

    return Dismissible(
      key: Key(character.id),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => onDelete(),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
            color: cs.errorContainer, borderRadius: BorderRadius.circular(18)),
        child: Icon(Icons.delete_outline_rounded, color: cs.error),
      ),
      child: Card(
        margin: const EdgeInsets.only(bottom: 12),
        elevation: 0,
        color:
            character.isActive ? cs.surfaceContainer : cs.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(
            color: character.isActive
                ? displayColor.withValues(alpha: 0.35)
                : cs.outlineVariant,
            width: character.isActive ? 1.5 : 1,
          ),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                _buildAvatar(displayColor),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(character.name,
                              style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: cs.onSurface)),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                                color: displayColor.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(6)),
                            child: Text(displayLabel,
                                style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: displayColor)),
                          ),
                          if (!character.isActive) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                  color: cs.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(6)),
                              child: Text('停用',
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: cs.onSurfaceVariant)),
                            ),
                          ],
                          if (character.agenticEnabled) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                  color: cs.tertiaryContainer,
                                  borderRadius: BorderRadius.circular(6)),
                              child: Text('行动 $skillCount',
                                  style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: cs.onTertiaryContainer)),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text('${character.gender.label} · ${character.role} · ${character.age}岁',
                          style: TextStyle(
                              fontSize: 13, color: cs.onSurfaceVariant)),
                      if (character.personalityTags.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children:
                              character.personalityTags.take(4).map((tag) {
                            return Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                  color: cs.primaryContainer,
                                  borderRadius: BorderRadius.circular(6)),
                              child: Text(tag,
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: cs.onPrimaryContainer)),
                            );
                          }).toList(),
                        ),
                      ],
                    ],
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      onPressed: onTogglePin,
                      icon: Icon(
                        isPinned
                            ? Icons.push_pin_rounded
                            : Icons.push_pin_outlined,
                        size: 20,
                      ),
                      color: isPinned ? cs.primary : cs.onSurfaceVariant,
                      tooltip: isPinned ? '取消置顶' : '置顶',
                    ),
                    // 显示当前模型名称，点击可单独切换该角色关联的 API 配置
                    if (character.modelName.isNotEmpty)
                      GestureDetector(
                        onTap: onConfigChange,
                        child: Container(
                          margin: const EdgeInsets.only(right: 4),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          constraints: const BoxConstraints(maxWidth: 120),
                          decoration: BoxDecoration(
                            color: cs.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            character.modelName,
                            style: TextStyle(
                                fontSize: 11,
                                fontFamily: 'monospace',
                                color: cs.onSurfaceVariant),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    IconButton(
                      onPressed: onDirectChat,
                      icon: const Icon(Icons.chat_bubble_outline_rounded,
                          size: 20),
                      color: cs.primary,
                      tooltip: '私聊',
                    ),
                    TextButton.icon(
                      onPressed: onToggle,
                      icon: Icon(
                        character.isActive
                            ? Icons.toggle_on_rounded
                            : Icons.toggle_off_rounded,
                        size: 20,
                      ),
                      label: Text(character.isActive ? '启用中' : '已停用'),
                      style: TextButton.styleFrom(
                        foregroundColor: character.isActive
                            ? cs.primary
                            : cs.onSurfaceVariant,
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        textStyle: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w600),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline_rounded, size: 20),
                      onPressed: onDelete,
                      color: cs.error,
                      tooltip: '删除',
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAvatar(Color pColor) {
    final displayAvatar = character.avatar.isNotEmpty
        ? character.avatar
        : (character.name.isNotEmpty ? character.name[0] : '?');
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: pColor.withValues(alpha: 0.14),
        border: Border.all(color: pColor.withValues(alpha: 0.3), width: 1.5),
      ),
      child: Stack(
        children: [
          Center(
              child: Text(displayAvatar,
                  style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      color: pColor))),
          if (!character.isActive)
            const Positioned.fill(
                child: DecoratedBox(
              decoration:
                  BoxDecoration(shape: BoxShape.circle, color: Colors.black26),
              child: Icon(Icons.pause_rounded, size: 16, color: Colors.white70),
            )),
        ],
      ),
    );
  }
}

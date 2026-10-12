import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:chat_group/core/widgets/app_widgets.dart';
import 'package:chat_group/features/settings/ai_speaker_picker_dialog.dart';
import 'package:chat_group/features/settings/api_config_list_section.dart';
import 'package:chat_group/features/settings/api_key_settings_snapshot.dart';
import 'package:chat_group/features/settings/api_key_settings_status.dart';
import 'package:chat_group/features/settings/image_service_settings_page.dart';
import 'package:chat_group/features/settings/providers/api_config_providers.dart';
import 'package:chat_group/features/settings/search_credential_settings_page.dart';
import 'package:chat_group/features/settings/voice_service_settings_page.dart';
import 'package:chat_group/features/settings/widgets/api_key_entry_tile.dart';
import 'package:chat_group/providers/providers.dart';

/// 全部 API Key 的集中入口。
///
/// 这里只做两件事：报出每一类凭据**配没配、缺什么**，以及把用户送到真正
/// 填写它们的既有页面。本页不新增任何存储，也不改动任何保存逻辑 ——
/// 密钥仍然各自走原来的安全存储通道。
class ApiKeySettingsPage extends ConsumerStatefulWidget {
  const ApiKeySettingsPage({super.key});

  @override
  ConsumerState<ApiKeySettingsPage> createState() => _ApiKeySettingsPageState();
}

class _ApiKeySettingsPageState extends ConsumerState<ApiKeySettingsPage> {
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final db = ref.read(databaseServiceProvider);
    final configs = ref.watch(apiConfigsProvider);

    final overview = collectApiKeyOverview(db: db, apiConfigs: configs);
    ApiKeyStatusEntry entryOf(String id) =>
        overview.entries.firstWhere((entry) => entry.id == id);

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        backgroundColor: cs.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: const Text('API KEY 设置'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 80),
        children: [
          _introCard(cs, overview),
          const SizedBox(height: 24),
          AppSectionHeader(title: '对话', cs: cs),
          const SizedBox(height: 12),
          ApiConfigListSection(
            title: '聊天与角色发言',
            subtitle: entryOf(ApiKeyCategory.chat).summary,
          ),
          const SizedBox(height: 8),
          _tileCard(cs, [
            _speakerPickerTile(cs, entryOf(ApiKeyCategory.speakerPicker)),
          ]),
          const SizedBox(height: 24),
          AppSectionHeader(title: '能力扩展', cs: cs),
          const SizedBox(height: 12),
          _tileCard(cs, [
            ApiKeyEntryTile(
              cs: cs,
              icon: Icons.record_voice_over_outlined,
              title: '语音服务 · 火山引擎',
              status: entryOf(ApiKeyCategory.voice).summary,
              state: _stateOf(entryOf(ApiKeyCategory.voice)),
              hint: '在火山引擎控制台开通「语音合成」与「流式语音识别」，'
                  '把 App ID / Access Token 与资源 ID 填进来。'
                  '未配置时：语音输入按钮置灰，AI 回复无法朗读。',
              onTap: () => _openPage(const VoiceServiceSettingsPage()),
            ),
            _divider(cs),
            ApiKeyEntryTile(
              cs: cs,
              icon: Icons.image_outlined,
              title: '图像服务 · IP 形象生成',
              status: entryOf(ApiKeyCategory.image).summary,
              state: _stateOf(entryOf(ApiKeyCategory.image)),
              hint: '填服务商地址、模型名与 Key（智谱 cogview-4-flash、'
                  'OpenAI dall-e-3、通义 wanx-v1）。'
                  '未配置时：角色无法生成 IP 形象。',
              onTap: () => _openPage(const ImageServiceSettingsPage()),
            ),
          ]),
          const SizedBox(height: 24),
          AppSectionHeader(title: '联网', cs: cs),
          const SizedBox(height: 12),
          _tileCard(cs, [
            ApiKeyEntryTile(
              cs: cs,
              icon: Icons.travel_explore_outlined,
              title: '搜索服务',
              status: entryOf(ApiKeyCategory.search).summary,
              state: _stateOf(entryOf(ApiKeyCategory.search)),
              hint: '支持 Tavily / Brave 等 Provider，也可用智谱原生搜索。'
                  '未配置时联网搜索不可用（DuckDuckGo 百科兜底不受影响）。'
                  '搜索策略在「模型、成本与联网治理」里开关。',
              onTap: () => _openPage(const SearchCredentialSettingsPage()),
            ),
          ]),
        ],
      ),
    );
  }

  /// 选人器不持有 Key，所以它的徽章用中性色：不配也能用，只是换成本地规则。
  Widget _speakerPickerTile(ColorScheme cs, ApiKeyStatusEntry entry) {
    return ApiKeyEntryTile(
      cs: cs,
      icon: Icons.multiple_stop_rounded,
      title: 'AI 接话选人器',
      status: entry.summary,
      state: ApiKeyEntryState.optional,
      hint: '它不保存 Key，只借用上面某条配置来决定"下一位由谁说"。'
          '不选择也能正常聊天，此时按本地规则选人、不额外调用模型。',
      onTap: () async {
        await showSpeakerPickerConfigDialog(context: context, ref: ref);
        if (mounted) setState(() {});
      },
    );
  }

  ApiKeyEntryState _stateOf(ApiKeyStatusEntry entry) =>
      entry.configured ? ApiKeyEntryState.ready : ApiKeyEntryState.missing;

  Widget _divider(ColorScheme cs) =>
      Divider(height: 1, color: cs.outlineVariant.withValues(alpha: 0.5));

  Widget _tileCard(ColorScheme cs, List<Widget> children) =>
      AppCard(cs: cs, margin: EdgeInsets.zero, children: children);

  /// 子页面会就地改写 app_settings 里的语音 / 图像配置，本页直接读这些值，
  /// 因此返回后必须重建一次才能反映最新状态。
  Future<void> _openPage(Widget page) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
    if (mounted) setState(() {});
  }

  Widget _introCard(ColorScheme cs, ApiKeyOverview overview) {
    final missing = ApiKeyOverview.countedCategories.where((id) {
      final entry = overview.entries.firstWhere(
        (candidate) => candidate.id == id,
        orElse: () =>
            const ApiKeyStatusEntry(id: '', configured: true, summary: ''),
      );
      return !entry.configured;
    }).toList(growable: false);

    return AppCard(
      cs: cs,
      margin: EdgeInsets.zero,
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.lock_outline_rounded, size: 18, color: cs.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('密钥只保存在本机',
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: cs.onSurface)),
                  ),
                  Text(overview.progressLabel,
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: overview.allConfigured
                              ? cs.primary
                              : cs.onSurfaceVariant)),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '所有 API Key 都只保存在本机：macOS 写入应用数据目录内的本地库'
                '（明文，不经系统钥匙串），其余平台写入系统安全存储'
                '（钥匙串 / Keystore）。都不会出现在备份、导出文件或聊天记录里；'
                '换机或重装后需要重新填写。',
                style: TextStyle(
                    fontSize: 13, height: 1.5, color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: overview.configuredCount / overview.total,
                  minHeight: 5,
                  backgroundColor: cs.outlineVariant.withValues(alpha: 0.4),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                missing.isEmpty
                    ? '四类密钥都已配置，可以正常使用全部能力。'
                    : '还缺：${missing.map(_categoryLabel).join(' / ')}',
                style: TextStyle(
                    fontSize: 12,
                    color: missing.isEmpty ? cs.primary : cs.error),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 只用于顶部"还缺哪些"的文案；计数口径见 [ApiKeyOverview.countedCategories]。
  String _categoryLabel(String categoryId) {
    switch (categoryId) {
      case ApiKeyCategory.chat:
        return '聊天';
      case ApiKeyCategory.voice:
        return '语音';
      case ApiKeyCategory.image:
        return '图像';
      case ApiKeyCategory.search:
        return '搜索';
      default:
        return categoryId;
    }
  }
}

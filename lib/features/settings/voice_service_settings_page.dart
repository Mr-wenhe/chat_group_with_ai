import 'package:chat_group/core/audio/voice_catalog.dart';
import 'package:chat_group/core/audio/voice_service_config.dart';
import 'package:chat_group/core/widgets/app_widgets.dart';
import 'package:chat_group/core/widgets/top_toast.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 全局语音服务配置页（设置 → API 配置 → 语音服务）。
///
/// - API Key：仅写入安全存储（[DatabaseService.bindVoiceApiKey]），本页不落明文；
/// - 资源 ID 与默认音色：写入 `app_settings`（[VoiceServiceConfig]）。
class VoiceServiceSettingsPage extends ConsumerStatefulWidget {
  const VoiceServiceSettingsPage({super.key});

  @override
  ConsumerState<VoiceServiceSettingsPage> createState() =>
      _VoiceServiceSettingsPageState();
}

class _VoiceServiceSettingsPageState
    extends ConsumerState<VoiceServiceSettingsPage> {
  late final TextEditingController _ttsResourceController;
  late final TextEditingController _asrResourceController;
  String? _defaultVoiceId;
  bool _apiKeyBound = false;
  bool _isBusy = false;

  @override
  void initState() {
    super.initState();
    final cfg = ref.read(databaseServiceProvider).voiceServiceConfig;
    _ttsResourceController = TextEditingController(text: cfg.ttsResourceId);
    _asrResourceController = TextEditingController(text: cfg.asrResourceId);
    _defaultVoiceId = cfg.defaultVoiceId;
    _apiKeyBound = cfg.apiKeyBound;
    _syncKeyPresence();
  }

  /// 页面每次进入都校验一次真实密钥是否在安全存储里（用户可能在外清过）。
  /// 一次性异步读，成功回调仅 setState 一次，不会形成重建循环。
  Future<void> _syncKeyPresence() async {
    final key = await ref.read(databaseServiceProvider).readVoiceApiKey();
    if (!mounted) return;
    final present = key != null && key.isNotEmpty;
    if (present != _apiKeyBound) {
      setState(() => _apiKeyBound = present);
    }
  }

  @override
  void dispose() {
    _ttsResourceController.dispose();
    _asrResourceController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        backgroundColor: cs.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('语音服务',
            style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 18,
                color: cs.onSurface)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          AppSectionHeader(title: '火山引擎语音服务', cs: cs),
          const SizedBox(height: 4),
          Text(
            '开启后：AI 回复可流式朗读（TTS），麦克风输入可转文字（ASR）。'
            'API Key 保存在系统安全存储，不会写入聊天数据。',
            style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          AppCard(
            cs: cs,
            children: [
              Row(
                children: [
                  Icon(
                      _apiKeyBound
                          ? Icons.verified_user_outlined
                          : Icons.key_off_outlined,
                      size: 20,
                      color: _apiKeyBound ? cs.primary : cs.onSurfaceVariant),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('API Key',
                            style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: cs.onSurface)),
                        const SizedBox(height: 2),
                        Text(
                          _apiKeyBound
                              ? '已绑定安全凭据 · ${List.filled(12, '•').join()}'
                              : '未绑定 · 群聊语音功能不可用',
                          style: TextStyle(
                              fontSize: 13,
                              color: _apiKeyBound
                                  ? cs.primary
                                  : cs.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  if (_apiKeyBound)
                    TextButton(
                      onPressed: _isBusy ? null : _promptUnbindKey,
                      child: Text('移除',
                          style: TextStyle(color: cs.error, fontSize: 13)),
                    ),
                  TextButton.icon(
                    onPressed: _isBusy ? null : _promptBindKey,
                    icon: const Icon(Icons.key_rounded, size: 16),
                    label: Text(_apiKeyBound ? '更换' : '绑定',
                        style: const TextStyle(fontSize: 13)),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          AppCard(
            cs: cs,
            children: [
              Text('资源 ID',
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface)),
              const SizedBox(height: 2),
              Text('一般保持默认值即可，需与你的火山开通的服务一致。',
                  style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
              const SizedBox(height: 14),
              TextFormField(
                controller: _ttsResourceController,
                decoration: appInputDecoration('TTS 资源 ID',
                    volcTtsDefaultResourceId, Icons.graphic_eq_rounded, cs),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _asrResourceController,
                decoration: appInputDecoration('ASR 资源 ID',
                    volcAsrDefaultResourceId, Icons.mic_rounded, cs),
              ),
            ],
          ),
          const SizedBox(height: 12),
          AppCard(
            cs: cs,
            children: [
              Text('默认音色',
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface)),
              const SizedBox(height: 2),
              Text('角色没有单独指定音色时，用它朗读该角色的回复。',
                  style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
              const SizedBox(height: 14),
              DropdownButtonFormField<String>(
                key: const Key('default-voice-dropdown'),
                value: _defaultVoiceId,
                isExpanded: true,
                decoration: appInputDecoration(
                    '默认音色', null, Icons.person_pin_rounded, cs),
                items: [
                  const DropdownMenuItem<String>(
                    value: null,
                    child: Text('不设默认（未指定音色的角色不出声）'),
                  ),
                  ...voicePresets.map((preset) => DropdownMenuItem<String>(
                        value: preset.id,
                        child: Text('${preset.name} · ${preset.id}',
                            overflow: TextOverflow.ellipsis),
                      )),
                ],
                onChanged: (value) => setState(() => _defaultVoiceId = value),
              ),
            ],
          ),
          const SizedBox(height: 20),
          AppPrimaryButton(
            onPressed: _isBusy ? null : _saveMeta,
            icon: Icons.check_rounded,
            label: '保存配置',
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Future<void> _promptBindKey() async {
    final controller = TextEditingController();
    final obscure = ValueNotifier<bool>(true);
    final cs = Theme.of(context).colorScheme;
    final entered = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(_apiKeyBound ? '更换 API Key' : '绑定 API Key',
            style: TextStyle(fontSize: 17, color: cs.onSurface)),
        content: ValueListenableBuilder<bool>(
          valueListenable: obscure,
          builder: (_, show, __) => TextField(
            controller: controller,
            obscureText: show,
            autofocus: true,
            decoration: appInputDecoration(
                    '火山引擎 API Key', '粘贴 AppKey', Icons.key_outlined, cs)
                .copyWith(
              suffixIcon: IconButton(
                icon: Icon(
                    show
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    size: 18),
                onPressed: () => obscure.value = !obscure.value,
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    obscure.dispose();

    final key = entered?.trim() ?? '';
    if (key.isEmpty) return;
    setState(() => _isBusy = true);
    final db = ref.read(databaseServiceProvider);
    final error = await db.bindVoiceApiKey(key);
    if (!mounted) return;
    setState(() {
      _isBusy = false;
      _apiKeyBound = error == null;
    });
    AppToast.show(
      context,
      error ?? '语音 API Key 已绑定',
      icon: error == null
          ? Icons.check_circle_outline_rounded
          : Icons.error_outline_rounded,
    );
  }

  Future<void> _promptUnbindKey() async {
    final cs = Theme.of(context).colorScheme;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('移除语音 API Key？',
            style: TextStyle(fontSize: 17, color: cs.onSurface)),
        content: const Text('群聊语音功能将不可用，但不会删除其他数据。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _isBusy = true);
    await ref.read(databaseServiceProvider).unbindVoiceApiKey();
    if (!mounted) return;
    setState(() {
      _isBusy = false;
      _apiKeyBound = false;
    });
    AppToast.show(context, '已移除语音 API Key', icon: Icons.check_rounded);
  }

  Future<void> _saveMeta() async {
    if (_isBusy) return;
    setState(() => _isBusy = true);
    final db = ref.read(databaseServiceProvider);
    final next = VoiceServiceConfig(
      ttsResourceId: _ttsResourceController.text.trim().isEmpty
          ? volcTtsDefaultResourceId
          : _ttsResourceController.text.trim(),
      asrResourceId: _asrResourceController.text.trim().isEmpty
          ? volcAsrDefaultResourceId
          : _asrResourceController.text.trim(),
      defaultVoiceId: _defaultVoiceId,
      apiKeyBound: _apiKeyBound,
    );
    await db.saveVoiceServiceConfig(next);
    if (!mounted) return;
    setState(() => _isBusy = false);
    AppToast.show(context, '语音服务配置已保存', icon: Icons.check_rounded);
  }
}

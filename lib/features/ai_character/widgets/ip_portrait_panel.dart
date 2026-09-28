import 'dart:async';

import 'package:chat_group/core/audio/voice_catalog.dart';
import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/database/database_service_image.dart';
import 'package:chat_group/core/database/database_service_provider.dart';
import 'package:chat_group/core/images/image_generation_service.dart';
import 'package:chat_group/core/images/image_style_presets.dart';
import 'package:chat_group/core/images/ip_image_prompt_builder.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/core/widgets/character_avatar.dart';
import 'package:chat_group/core/widgets/top_toast.dart';
import 'package:chat_group/features/ai_character/ip_visual_description_llm.dart';
import 'package:chat_group/features/ai_character/widgets/ip_portrait_draft_tracker.dart';
import 'package:chat_group/features/settings/image_service_settings_page.dart';
import 'package:chat_group/features/settings/providers/api_config_providers.dart';
import 'package:chat_group/services/chat_api_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const double kIpPortraitPreviewSize = 96;
const String kIpImageFileName = 'ip.png';
const String kIpImageUnconfiguredMessage = '尚未配置图像服务，请先到 设置 → 图像服务 完成配置';
const String kIpImageWriteFailedMessage = 'IP 形象保存到本地失败，请重试';
const String kIpImageGenericFailedMessage = 'IP 形象生成失败，请重试';

/// 角色表单内的「IP 形象」面板：按角色定义自动生成形象，并可一键设为头像。
///
/// 生成**即落盘**（[DatabaseService.writeBytesToAiCharacterDir]），因为生成是
/// 用户等待 30–120s 的产出，丢弃代价高。文件回收决策交给 [IpPortraitDraftTracker]，
/// 本类只负责调用它并执行删除 —— 见该类注释里的两条回收底线。
class IpPortraitPanel extends ConsumerStatefulWidget {
  const IpPortraitPanel({
    super.key,
    required this.draftBuilder,
    required this.characterId,
    required this.initialRelPath,
    required this.initialAvatarFromIp,
    required this.initialStyle,
    required this.onChanged,
  });

  /// 取表单**当前草稿**（姓名/年龄/职业/性格/人设都还在内存里），拼 prompt 用。
  final AICharacter Function() draftBuilder;

  /// 落盘目录名含角色 id，因此新建角色也必须先预分配 id（见表单页）。
  final String characterId;

  /// 以下三项**仅在 initState 读取一次**；此后变更一律经 [onChanged] 单向上报。
  final String initialRelPath;
  final bool initialAvatarFromIp;
  final String initialStyle;

  final void Function(String relPath, bool avatarFromIp, String style) onChanged;

  @override
  ConsumerState<IpPortraitPanel> createState() => IpPortraitPanelState();
}

class IpPortraitPanelState extends ConsumerState<IpPortraitPanel> {
  late final IpPortraitDraftTracker _tracker;
  late final DatabaseService _db;
  late bool _avatarFromIp;
  late String _style;
  bool _isGenerating = false;
  String? _errorMessage;

  /// 最近一次**实际发给生图服务**的 prompt。
  ///
  /// 拼装是全自动的，用户看不见就只能对着图猜哪句话出了问题。留一份原文
  /// 在「查看 Prompt」里摊出来，能直接复制走比对。
  String? _lastPrompt;

  /// 上一次生成是否真用上了 LLM 外观改写。
  ///
  /// 和 [_lastPrompt] 一起看才有意义：同样是「prompt 不对」，走没走 LLM
  /// 完全是两条排查路径。
  bool? _lastUsedLlm;

  @override
  void initState() {
    super.initState();
    _tracker = IpPortraitDraftTracker(initialRelPath: widget.initialRelPath);
    _db = ref.read(databaseServiceProvider);
    _avatarFromIp = widget.initialAvatarFromIp;
    _style = widget.initialStyle;
  }

  /// 表单持久化成功后点名调用（[GlobalKey]）：把「被换下的既有文件 / 本次会话
  /// 多余文件」的回收从「放弃时」改判为「现在」。必须早于 `dispose`，否则
  /// `dispose` 会按「放弃」把本次生成的图删掉。
  void markCommitted() {
    for (final path in _tracker.markCommitted()) {
      unawaited(_db.deleteAiCharacterFile(path));
    }
  }

  @override
  void dispose() {
    for (final path in _tracker.discard()) {
      unawaited(_db.deleteAiCharacterFile(path));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('IP 形象', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildPreview(context, cs),
            const SizedBox(width: 14),
            Expanded(child: _buildControls(context, cs)),
          ],
        ),
      ],
    );
  }

  Widget _buildPreview(BuildContext context, ColorScheme cs) {
    final image = _db.characterMediaImage(_tracker.currentRelPath);
    return GestureDetector(
      // 96px 缩略图看不出生成质量（脸部/文字瑕疵），有图时点开可放大细看。
      onTap: image == null ? null : () => _showFullPreview(context, image),
      child: CharacterAvatar(
        key: const ValueKey('ip-portrait-preview'),
        fallbackText: '',
        size: kIpPortraitPreviewSize,
        image: image,
        shape: BoxShape.rectangle,
        borderRadius: BorderRadius.circular(12),
        background: cs.surfaceContainerHighest,
        child: Icon(Icons.image_outlined, size: 36, color: cs.onSurfaceVariant),
      ),
    );
  }

  /// 放大查看当前形象。[InteractiveViewer] 支持捏合，因为瑕疵常在细节里。
  void _showFullPreview(BuildContext context, ImageProvider image) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        backgroundColor: Colors.black87,
        child: GestureDetector(
          onTap: () => Navigator.pop(dialogContext),
          child: InteractiveViewer(
            maxScale: 4,
            child: Image(image: image, fit: BoxFit.contain),
          ),
        ),
      ),
    );
  }

  Widget _buildControls(BuildContext context, ColorScheme cs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _referenceHint(),
          key: const ValueKey('ip-portrait-reference-hint'),
          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 2),
        Text(
          _rewriteSourceLabel(),
          key: const ValueKey('ip-portrait-rewrite-source'),
          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        _buildStyleDropdown(cs),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _buildGenerateButton(context, cs),
            if (_tracker.hasImage) ...[
              _buildAvatarToggleButton(context, cs),
              _buildClearButton(context, cs),
            ],
            _buildPromptButton(context),
          ],
        ),
        if (_isGenerating) ...[
          const SizedBox(height: 8),
          const LinearProgressIndicator(),
        ],
        if (_errorMessage != null) ...[
          const SizedBox(height: 8),
          Text(
            _errorMessage!,
            key: const ValueKey('ip-portrait-error'),
            style: TextStyle(fontSize: 12, color: cs.error),
          ),
        ],
        if (!_db.imageServiceConfig.isConfigured)
          TextButton(
            key: const ValueKey('ip-portrait-open-settings'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ImageServiceSettingsPage()),
            ),
            child: const Text('前往设置'),
          ),
      ],
    );
  }

  /// 说明形象会参考哪些字段 —— 尤其是音色，它不在表单的「外貌」区域，
  /// 不点明用户不会想到它会影响长相。
  String _referenceHint() {
    final voiceName = voicePresetById(widget.draftBuilder().voiceId)?.name;
    final suffix = voiceName == null ? '' : '、朗读音色（$voiceName）';
    return '自动从性格、人设$suffix 提炼长相';
  }

  /// 外观描述由谁产出。**必须可见**：LLM 改写失败时会静默回落本地模板，
  /// 上一版就因为草稿漏带 `apiConfigId` 而永远走本地模板，出图不对却完全
  /// 无从排查 —— 静默回落等于把 bug 藏起来。
  String _rewriteSourceLabel() {
    final configId = widget.draftBuilder().apiConfigId;
    if (configId.isEmpty) return '外观描述：本地模板（未绑定聊天模型）';
    final config = ref.read(apiConfigsProvider.notifier).getById(configId);
    if (config == null) return '外观描述：本地模板（聊天配置已失效）';
    return '外观描述：由聊天模型「${config.name}」改写';
  }

  Widget _buildStyleDropdown(ColorScheme cs) {
    return DropdownButtonFormField<String>(
      key: const ValueKey('ip-portrait-style'),
      value: resolveImageStylePreset(_style).id,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: '画风',
        labelStyle: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      ),
      items: kImageStylePresets
          .map((preset) => DropdownMenuItem<String>(
                value: preset.id,
                child: Text(preset.label,
                    overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
              ))
          .toList(),
      onChanged: _isGenerating
          ? null
          : (value) {
              if (value == null) return;
              _style = value;
              widget.onChanged(_tracker.currentRelPath, _avatarFromIp, _style);
              setState(() {});
            },
    );
  }

  Widget _buildGenerateButton(BuildContext context, ColorScheme cs) {
    return FilledButton.icon(
      key: const ValueKey('ip-portrait-generate'),
      // 生成期间禁用，杜绝重复点击双计费。
      onPressed: _isGenerating ? null : _onGenerate,
      icon: _isGenerating
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.auto_awesome_outlined, size: 18),
      label: Text(_tracker.hasImage ? '重新生成' : '生成形象'),
    );
  }

  Widget _buildAvatarToggleButton(BuildContext context, ColorScheme cs) {
    return OutlinedButton(
      key: const ValueKey('ip-portrait-toggle-avatar'),
      onPressed: _toggleAvatar,
      child: Text(_avatarFromIp ? '取消头像' : '设为头像'),
    );
  }

  Widget _buildClearButton(BuildContext context, ColorScheme cs) {
    return TextButton(
      key: const ValueKey('ip-portrait-clear'),
      onPressed: _clearImage,
      child: const Text('清除形象'),
    );
  }

  Widget _buildPromptButton(BuildContext context) {
    return TextButton(
      key: const ValueKey('ip-portrait-show-prompt'),
      onPressed: () => _showPrompt(context),
      child: const Text('查看 Prompt'),
    );
  }

  /// 弹窗顶部的一句话，讲清这份 prompt 是哪条路径拼出来的。
  ///
  /// 三态必须分开说：预览（还没生成）、生成时真用了 LLM、生成时静默回落了
  /// 本地模板。混成一句「这是 prompt」就又回到「图不对只能猜」的老路。
  String _promptNote(String? sent) {
    if (sent == null) {
      return '以下是本地模板拼装的预览。点「生成形象」后这里会换成真实发出的原文。';
    }
    return _lastUsedLlm == true
        ? '以下是最近一次生成真实发出的原文，外观描述由聊天模型改写。'
        : '以下是最近一次生成真实发出的原文。外观描述走的是本地模板 '
            '—— 聊天模型那次改写没生效，所以只有性格没有长相。';
  }

  /// 把实际发出的 prompt 摊开。
  ///
  /// 「图不对」十次有九次出在 prompt，但 prompt 是自动拼的，用户看不见就只能
  /// 猜。这里给一条能直接复制走比对的通道。没生成过时先按本地模板拼一份预览，
  /// 并明确标注它和真实请求的差别。
  void _showPrompt(BuildContext context) {
    final sent = _lastPrompt;
    final prompt = sent ??
        buildIpImagePrompt(
          widget.draftBuilder(),
          style: resolveImageStylePreset(_style),
        );
    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final cs = Theme.of(dialogContext).colorScheme;
        return AlertDialog(
          title: const Text('生图 Prompt'),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _promptNote(sent),
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                  const SizedBox(height: 8),
                  SelectableText(prompt),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _onGenerate() async {
    final config = _db.imageServiceConfig;
    final apiKey = await _db.readImageApiKey();
    if (!mounted) return;
    if (!config.isConfigured || apiKey == null || apiKey.trim().isEmpty) {
      setState(() => _errorMessage = kIpImageUnconfiguredMessage);
      AppToast.show(
        context,
        kIpImageUnconfiguredMessage,
        icon: Icons.image_not_supported_outlined,
      );
      return;
    }

    setState(() {
      _isGenerating = true;
      _errorMessage = null;
    });
    try {
      final draft = widget.draftBuilder();
      final description = await _describeVisual(draft);
      final prompt = buildIpImagePrompt(
        draft,
        style: resolveImageStylePreset(_style),
        visualDescription: description,
      );
      // 生成失败也要留下 prompt：查「图为什么不对」时恰恰是最需要看它的时刻。
      _lastPrompt = prompt;
      _lastUsedLlm = description != null;
      final bytes = await ImageGenerationService(config: config, apiKey: apiKey)
          .generate(prompt: prompt);
      final relPath = await _writePortrait(bytes);
      if (!mounted) return;
      _tracker.adopt(relPath);
      widget.onChanged(relPath, _avatarFromIp, _style);
      setState(() {});
    } on ImageGenerationException catch (error) {
      if (mounted) setState(() => _errorMessage = error.message);
    } on Object {
      if (mounted) setState(() => _errorMessage = kIpImageGenericFailedMessage);
    } finally {
      if (mounted) setState(() => _isGenerating = false);
    }
  }

  /// 让角色绑定的聊天模型把人设提炼成视觉描述。
  ///
  /// **任何失败都返回 null**，由 [buildIpImagePrompt] 的本地模板兜住：改写是
  /// 增益项，不该让整次生成失败。没绑聊天 ApiConfig 的角色直接走本地模板。
  Future<String?> _describeVisual(AICharacter draft) async {
    final configId = draft.apiConfigId;
    if (configId.isEmpty) return null;
    final config =
        ref.read(apiConfigsProvider.notifier).getById(configId);
    if (config == null) return null;
    try {
      return await IpVisualDescriptionLlm(
        api: ChatApiService(),
        credentials: SecureApiCredentialResolver(),
      ).describe(draft, config);
    } on Object {
      return null;
    }
  }

  Future<String> _writePortrait(List<int> bytes) async {
    final draft = widget.draftBuilder();
    final attachment = await _db.writeBytesToAiCharacterDir(
      bytes: bytes,
      fileName: kIpImageFileName,
      characterId: widget.characterId,
      characterName: draft.name,
      type: 'image',
    );
    final relPath = _db.aiCharacterMediaRelPath(attachment.localPath);
    if (relPath == null || relPath.isEmpty) {
      throw const ImageGenerationException(kIpImageWriteFailedMessage);
    }
    return relPath;
  }

  void _toggleAvatar() {
    _avatarFromIp = !_avatarFromIp;
    widget.onChanged(_tracker.currentRelPath, _avatarFromIp, _style);
    setState(() {});
  }

  void _clearImage() {
    _tracker.clear();
    _avatarFromIp = false;
    widget.onChanged('', false, _style);
    setState(() {});
  }
}

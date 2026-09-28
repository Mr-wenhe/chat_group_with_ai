import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:chat_group/core/images/image_generation_service.dart';
import 'package:chat_group/core/images/image_provider_presets.dart';
import 'package:chat_group/core/images/image_service_config.dart';
import 'package:chat_group/core/widgets/app_widgets.dart';

/// 生图调用签名。抽成 typedef 是为了让预览卡片可注入假实现，
/// 从而在不碰网络的前提下断言「用的是草稿配置 + 已绑定 Key」。
typedef ImageGenerate = Future<Uint8List> Function(
  ImageServiceConfig config,
  String prompt,
);

/// 设置页的「生成预览」卡片：用**当前表单草稿**的服务地址/模型/尺寸/质量
/// 真实调一次生图接口，并就地展示结果。
///
/// 为什么放在设置页而不是只留在角色表单：配置错误的表现统一是 404 / 429 /
/// 401，用户必须在**改配置的同一个界面**立刻验证，否则只能跑到角色表单去试，
/// 把「配置问题」误判成「生成功能坏了」。
///
/// **凭据红线**：只读取**已正式绑定**的 Key（`DatabaseService.readImageApiKey`），
/// 全程不为本次预览写入/回读/删除安全存储。弹窗新输入的 Key 仍由「绑定」按钮
/// 走正式保存流程，预览不做临时 Key 测试。
class ImageGenerationPreviewCard extends StatefulWidget {
  const ImageGenerationPreviewCard({
    super.key,
    required this.draft,
    required this.apiKeyBound,
    required this.readApiKey,
    this.generate,
  });

  /// 表单**草稿**配置（未必已点「保存配置」）—— 预览要反映用户正在编辑的值，
  /// 否则改完模型名还得先保存才能看到效果。
  final ImageServiceConfig draft;

  /// 是否已绑定 API Key（由设置页持有，预览不自行探测）。
  final bool apiKeyBound;

  /// 读取**已正式绑定**的 Key。收窄成单个回调而不是整个 `DatabaseService`：
  /// 本卡片只该有「读凭据」这一个权限，凭据红线也因此变成可断言的接缝
  /// （测试能证明预览从不写入/删除安全存储）。
  final Future<String?> Function() readApiKey;

  /// 仅供测试注入；为 null 时走真实 [ImageGenerationService]。
  final ImageGenerate? generate;

  @override
  State<ImageGenerationPreviewCard> createState() =>
      _ImageGenerationPreviewCardState();
}

class _ImageGenerationPreviewCardState
    extends State<ImageGenerationPreviewCard> {
  bool _isGenerating = false;
  Uint8List? _previewBytes;
  String? _errorMessage;

  bool get _canGenerate =>
      widget.apiKeyBound &&
      widget.draft.baseUrl.trim().isNotEmpty &&
      widget.draft.model.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AppCard(
      cs: cs,
      children: [
        Text('生成预览',
            style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: cs.onSurface)),
        const SizedBox(height: 2),
        Text(
          widget.apiKeyBound
              ? '用当前填写的服务地址与模型真实生成一张样张，确认配置可用。'
              : '先绑定 API Key 后才能生成预览。',
          style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 14),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildPreviewBox(context, cs),
            const SizedBox(width: 14),
            Expanded(child: _buildActions(context, cs)),
          ],
        ),
      ],
    );
  }

  Widget _buildPreviewBox(BuildContext context, ColorScheme cs) {
    final bytes = _previewBytes;
    return GestureDetector(
      // 有图才可点开放大：小尺寸预览不足以判断生成质量。
      onTap: bytes == null ? null : () => _showFullPreview(context, bytes),
      child: Container(
        key: const ValueKey('image-preview-box'),
        width: 96,
        height: 96,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: bytes == null
            ? Icon(Icons.image_outlined, size: 36, color: cs.onSurfaceVariant)
            : Image.memory(bytes, fit: BoxFit.cover),
      ),
    );
  }

  Widget _buildActions(BuildContext context, ColorScheme cs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FilledButton.icon(
          key: const ValueKey('image-preview-generate'),
          onPressed: _isGenerating || !_canGenerate ? null : _onGenerate,
          icon: _isGenerating
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.auto_awesome_outlined, size: 18),
          label: Text(_previewBytes == null ? '生成预览' : '重新生成'),
        ),
        if (_isGenerating) ...[
          const SizedBox(height: 8),
          const LinearProgressIndicator(),
        ],
        if (_errorMessage != null) ...[
          const SizedBox(height: 8),
          Text(
            _errorMessage!,
            key: const ValueKey('image-preview-error'),
            style: TextStyle(fontSize: 12, color: cs.error),
          ),
        ],
        if (_previewBytes != null && !_isGenerating) ...[
          const SizedBox(height: 8),
          Text('点击左侧图片可放大查看',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
        ],
      ],
    );
  }

  Future<void> _onGenerate() async {
    final apiKey = await widget.readApiKey();
    if (!mounted) return;
    if (apiKey == null || apiKey.trim().isEmpty) {
      setState(() => _errorMessage = '未找到已绑定的 API Key，请先在上方绑定');
      return;
    }

    setState(() {
      _isGenerating = true;
      _errorMessage = null;
    });
    try {
      // 用草稿配置而非已保存配置：用户改完模型名要能立刻验证，不必先落盘。
      final bytes = await _generate(widget.draft, apiKey, kImagePreviewPrompt);
      if (!mounted) return;
      setState(() => _previewBytes = bytes);
    } on ImageGenerationException catch (error) {
      if (mounted) setState(() => _errorMessage = error.message);
    } on Object {
      if (mounted) setState(() => _errorMessage = '预览生成失败，请重试');
    } finally {
      if (mounted) setState(() => _isGenerating = false);
    }
  }

  Future<Uint8List> _generate(
    ImageServiceConfig config,
    String apiKey,
    String prompt,
  ) {
    final injected = widget.generate;
    if (injected != null) return injected(config, prompt);
    return ImageGenerationService(config: config, apiKey: apiKey)
        .generate(prompt: prompt);
  }

  /// 点击小图放大查看。用 [InteractiveViewer] 支持捏合，因为生成图细节
  /// （脸部/文字瑕疵）在 96px 缩略图里根本看不出来。
  void _showFullPreview(BuildContext context, Uint8List bytes) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        backgroundColor: Colors.black87,
        child: GestureDetector(
          onTap: () => Navigator.pop(dialogContext),
          child: InteractiveViewer(
            maxScale: 4,
            child: Image.memory(bytes, fit: BoxFit.contain),
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:chat_group/core/database/database_service_image.dart';
import 'package:chat_group/core/images/image_provider_presets.dart';
import 'package:chat_group/core/images/image_service_config.dart';
import 'package:chat_group/core/widgets/app_widgets.dart';
import 'package:chat_group/core/widgets/top_toast.dart';
import 'package:chat_group/features/settings/widgets/image_generation_preview_card.dart';
import 'package:chat_group/providers/providers.dart';

/// 全局图像服务配置页（设置 → 图像服务）。
///
/// - API Key：仅写入安全存储（[DatabaseService.bindImageApiKey]），本页不落明文；
/// - baseUrl / 模型 / 尺寸 / 质量：写入 `app_settings`（[ImageServiceConfig]）。
///
/// **刻意不提供「测试连接」按钮**：生图本身就是连通性验证，从根上消除
/// 「为测试先临时写入/回读/删除安全存储」这条红线的触发面。
class ImageServiceSettingsPage extends ConsumerStatefulWidget {
  const ImageServiceSettingsPage({super.key});

  @override
  ConsumerState<ImageServiceSettingsPage> createState() =>
      _ImageServiceSettingsPageState();
}

class _ImageServiceSettingsPageState
    extends ConsumerState<ImageServiceSettingsPage> {
  late final TextEditingController _baseUrlController;
  late final TextEditingController _modelController;
  String _size = kDefaultImageSize;
  String _quality = '';
  String _presetId = kImageProviderPresetCustomId;
  bool _disableWatermark = false;
  bool _apiKeyBound = false;
  bool _isBusy = false;

  @override
  void initState() {
    super.initState();
    final cfg = ref.read(databaseServiceProvider).imageServiceConfig;
    _baseUrlController = TextEditingController(text: cfg.baseUrl);
    _modelController = TextEditingController(text: cfg.model);
    // 走 normalizeImageSize 而不是单纯查列表：已存的非法尺寸（如曾作为选项提供
    // 过的 512x512）在这里自愈成该服务商的建议值，用户看到的就是真实会发出的值。
    _size = normalizeImageSize(cfg.size, baseUrl: cfg.baseUrl);
    _quality = kImageQualityOptions.contains(cfg.quality) ? cfg.quality : '';
    _presetId = imageProviderPresetIdForPrefix(cfg.baseUrl);
    _disableWatermark = cfg.disableWatermark;
    _apiKeyBound = cfg.apiKeyBound;
    _syncKeyPresence();
  }

  /// 页面每次进入都校验一次真实密钥是否在安全存储里（用户可能在外清过）。
  /// 一次性异步读，成功回调仅 setState 一次，不会形成重建循环。
  Future<void> _syncKeyPresence() async {
    final key = await ref.read(databaseServiceProvider).readImageApiKey();
    if (!mounted) return;
    final present = key != null && key.isNotEmpty;
    if (present != _apiKeyBound) {
      setState(() => _apiKeyBound = present);
    }
  }

  @override
  void dispose() {
    _baseUrlController.dispose();
    _modelController.dispose();
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
        title: Text('图像服务',
            style: TextStyle(
                fontWeight: FontWeight.w600, fontSize: 18, color: cs.onSurface)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          AppSectionHeader(title: 'IP 形象生成', cs: cs),
          const SizedBox(height: 4),
          Text(
            '开启后：可在角色编辑页根据角色定义一键生成 IP 形象。'
            '支持 OpenAI / 智谱 / 通义 / 火山方舟等 images/generations 兼容接口。'
            'API Key 保存在系统安全存储，不会写入聊天数据。',
            style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          _buildKeyCard(cs),
          const SizedBox(height: 12),
          _buildEndpointCard(cs),
          const SizedBox(height: 12),
          _buildOutputCard(cs),
          const SizedBox(height: 12),
          _buildPreviewCard(),
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

  Widget _buildKeyCard(ColorScheme cs) {
    return AppCard(
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
                        : '未绑定 · IP 形象生成不可用',
                    style: TextStyle(
                        fontSize: 13,
                        color:
                            _apiKeyBound ? cs.primary : cs.onSurfaceVariant),
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
    );
  }

  Widget _buildEndpointCard(ColorScheme cs) {
    final preset = imageProviderPresetById(_presetId);
    return AppCard(
      cs: cs,
      children: [
        Text('服务地址与模型',
            style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: cs.onSurface)),
        const SizedBox(height: 2),
        Text('请求会发往 {服务地址}/images/generations；选服务商可自动带出正确前缀。',
            style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
        const SizedBox(height: 14),
        _buildProviderDropdown(cs),
        const SizedBox(height: 12),
        TextFormField(
          controller: _baseUrlController,
          // 手改地址时不能还挂着预设选中态，否则「选了 A 却填 B 的地址」很迷惑。
          onChanged: (_) => setState(
              () => _presetId = kImageProviderPresetCustomId),
          decoration: appInputDecoration(
              '服务地址',
              preset?.apiPrefix ?? 'https://api.openai.com/v1',
              Icons.link_rounded,
              cs),
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _modelController,
          onChanged: (_) => setState(() {}),
          decoration: appInputDecoration('模型名',
              preset?.modelHint ?? 'dall-e-3', Icons.auto_awesome_motion_rounded, cs),
        ),
        if (preset != null && preset.sampleModels.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: preset.sampleModels
                .map((model) => ActionChip(
                      key: ValueKey('image-model-suggest-$model'),
                      label: Text(model, style: const TextStyle(fontSize: 12)),
                      onPressed: () =>
                          setState(() => _modelController.text = model),
                    ))
                .toList(),
          ),
        ],
      ],
    );
  }

  Widget _buildProviderDropdown(ColorScheme cs) {
    return DropdownButtonFormField<String>(
      key: const Key('image-provider-dropdown'),
      value: _presetId,
      isExpanded: true,
      decoration:
          appInputDecoration('服务商', null, Icons.cloud_outlined, cs),
      items: [
        for (final preset in kImageProviderPresets)
          DropdownMenuItem<String>(
            value: preset.id,
            child: Text(preset.label, overflow: TextOverflow.ellipsis),
          ),
        const DropdownMenuItem<String>(
          value: kImageProviderPresetCustomId,
          child: Text('自定义', overflow: TextOverflow.ellipsis),
        ),
      ],
      onChanged: (value) {
        if (value == null) return;
        setState(() {
          _presetId = value;
          final preset = imageProviderPresetById(value);
          if (preset != null) {
            _baseUrlController.text = preset.apiPrefix;
            // 仅在用户还没自定义模型时带出建议值，不覆盖手填内容。
            if (preset.sampleModels.isNotEmpty && _modelController.text.isEmpty) {
              _modelController.text = preset.sampleModels.first;
            }
            // 尺寸/质量则**无条件对齐**该家合法枚举：选预设就是在声明「我用这家」，
            // 填错的表现是 400 而不是配置错误，比覆盖掉用户手填的值更省事。
            if (preset.recommendedSize.isNotEmpty) {
              _size = preset.recommendedSize;
            }
            if (preset.recommendedQuality.isNotEmpty) {
              _quality = preset.recommendedQuality;
            }
          }
        });
      },
    );
  }

  /// 生成预览卡：用当前草稿真实调一次生图接口。见 [ImageGenerationPreviewCard]。
  Widget _buildPreviewCard() {
    return ImageGenerationPreviewCard(
      draft: _draftConfig(),
      apiKeyBound: _apiKeyBound,
      readApiKey: () => ref.read(databaseServiceProvider).readImageApiKey(),
    );
  }

  /// 把**表单当前值**（未必要已保存）收成一份配置，供预览与保存共用。
  ImageServiceConfig _draftConfig() => ImageServiceConfig(
        baseUrl: _baseUrlController.text.trim(),
        model: _modelController.text.trim(),
        size: _size,
        quality: _quality,
        disableWatermark: _disableWatermark,
        apiKeyBound: _apiKeyBound,
      );

  Widget _buildOutputCard(ColorScheme cs) {
    return AppCard(
      cs: cs,
      children: [
        Text('出图参数',
            style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: cs.onSurface)),
        const SizedBox(height: 2),
        Text('不同服务的合法枚举不同；选服务商时会自动带出该家的建议值。'
            '质量默认不发送以最大化兼容。',
            style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
        const SizedBox(height: 14),
        DropdownButtonFormField<String>(
          key: const Key('image-size-dropdown'),
          value: _size,
          isExpanded: true,
          decoration:
              appInputDecoration('尺寸', null, Icons.aspect_ratio_rounded, cs),
          items: [
            // 合法但不在预设列表里的自定义尺寸（如 1472x1088）必须能显示并保留，
            // 否则进一次设置页再点保存就会把它悄悄换成默认值 —— 用户根本不会发现。
            if (!kImageSizeOptions.contains(_size))
              DropdownMenuItem<String>(
                value: _size,
                child: Text(_size, overflow: TextOverflow.ellipsis),
              ),
            ...kImageSizeOptions.map((size) => DropdownMenuItem<String>(
                  value: size,
                  child: Text(size, overflow: TextOverflow.ellipsis),
                )),
          ],
          onChanged: (value) => setState(() => _size = value ?? kDefaultImageSize),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          key: const Key('image-quality-dropdown'),
          value: _quality,
          isExpanded: true,
          decoration:
              appInputDecoration('质量', null, Icons.high_quality_rounded, cs),
          items: kImageQualityOptions
              .map((quality) => DropdownMenuItem<String>(
                    value: quality,
                    child: Text(quality.isEmpty ? '不发送' : quality,
                        overflow: TextOverflow.ellipsis),
                  ))
              .toList(),
          onChanged: (value) => setState(() => _quality = value ?? ''),
        ),
        const SizedBox(height: 12),
        _buildWatermarkSwitch(cs),
      ],
    );
  }

  /// 去水印开关。默认关闭（即不发 `watermark_enabled`）：OpenAI 等实现不认这个
  /// 字段，无条件发会把可用配置打成 400；智谱 `glm-image` 则默认打显式 AI 水印。
  Widget _buildWatermarkSwitch(ColorScheme cs) {
    return SwitchListTile(
      key: const ValueKey('image-disable-watermark'),
      value: _disableWatermark,
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text('去除 AI 水印',
          style: TextStyle(fontSize: 14, color: cs.onSurface)),
      subtitle: Text(
        '发送 watermark_enabled: false。仅对支持该字段的服务生效；'
        '智谱需先到「个人中心 → 安全管理 → 去水印管理」签署免责声明，否则请求会被拒。',
        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
      ),
      onChanged: (value) => setState(() => _disableWatermark = value),
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
                    '图像服务 API Key', '粘贴 Key', Icons.key_outlined, cs)
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
    // 弹窗输入的 Key 直接作为参数传入正式绑定流程，全程不落任何临时存储。
    final error = await ref.read(databaseServiceProvider).bindImageApiKey(key);
    if (!mounted) return;
    setState(() {
      _isBusy = false;
      _apiKeyBound = error == null;
    });
    AppToast.show(
      context,
      error ?? '图像 API Key 已绑定',
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
        title: Text('移除图像 API Key？',
            style: TextStyle(fontSize: 17, color: cs.onSurface)),
        content: const Text('IP 形象生成将不可用，但不会删除已生成的形象。'),
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
    await ref.read(databaseServiceProvider).unbindImageApiKey();
    if (!mounted) return;
    setState(() {
      _isBusy = false;
      _apiKeyBound = false;
    });
    AppToast.show(context, '已移除图像 API Key', icon: Icons.check_rounded);
  }

  Future<void> _saveMeta() async {
    if (_isBusy) return;
    setState(() => _isBusy = true);
    final next = _draftConfig();
    await ref.read(databaseServiceProvider).saveImageServiceConfig(next);
    if (!mounted) return;
    setState(() => _isBusy = false);
    AppToast.show(context, '图像服务配置已保存', icon: Icons.check_rounded);
  }
}

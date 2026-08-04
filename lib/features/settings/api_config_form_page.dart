import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/core/widgets/app_widgets.dart';
import 'package:chat_group/core/widgets/top_toast.dart';
import 'package:chat_group/features/ai_governance/ai_governance_store.dart';
import 'package:chat_group/features/ai_governance/ai_request_gateway.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:chat_group/services/ai_providers/ai_api_service.dart';
import './providers/api_config_providers.dart';

class ApiConfigFormPage extends ConsumerStatefulWidget {
  final ApiConfig? config;

  const ApiConfigFormPage({super.key, this.config});

  @override
  ConsumerState<ApiConfigFormPage> createState() => _ApiConfigFormPageState();
}

class _ApiConfigFormPageState extends ConsumerState<ApiConfigFormPage> {
  final _formKey = GlobalKey<FormState>();
  late final AiApiService _apiService;
  final _credentialResolver = SecureApiCredentialResolver();
  late TextEditingController _nameController;
  late TextEditingController _modelController;
  late TextEditingController _apiKeyController;
  late TextEditingController _baseUrlController;
  ApiProvider _selectedProvider = ApiProvider.deepseek;
  String _selectedModel = '';
  bool _obscureApiKey = true;
  bool _isSaving = false;
  bool _isTesting = false;

  @override
  void initState() {
    super.initState();
    final db = ref.read(databaseServiceProvider);
    _apiService = AiApiService(
      AiRequestGateway(store: AiGovernanceStore.forDatabase(db)),
    );
    final c = widget.config;
    _nameController = TextEditingController(text: c?.name ?? '');
    _modelController = TextEditingController(text: c?.modelName ?? '');
    // 密钥不会从持久化模型回填到编辑框；留空代表保留现有安全凭据。
    _apiKeyController = TextEditingController();
    _baseUrlController = TextEditingController(text: c?.customBaseUrl ?? '');
    _selectedProvider = _parseProvider(c?.provider);
    _selectedModel =
        c?.modelName ?? ApiProvider.defaultModels[_selectedProvider.name] ?? '';
    if (_selectedProvider != ApiProvider.custom) {
      _modelController.text = _selectedModel;
    }
  }

  ApiProvider _parseProvider(String? name) {
    if (name == null) return ApiProvider.deepseek;
    try {
      return ApiProvider.values.firstWhere((p) => p.name == name);
    } catch (_) {
      return ApiProvider.deepseek;
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _modelController.dispose();
    _apiKeyController.dispose();
    _baseUrlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isCustom = _selectedProvider == ApiProvider.custom;

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        backgroundColor: cs.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(widget.config == null ? '新建 API 配置' : '编辑 API 配置',
            style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 18,
                color: cs.onSurface)),
        actions: [
          TextButton.icon(
            onPressed: _isSaving ? null : _save,
            icon: Icon(
                widget.config == null
                    ? Icons.add_circle_rounded
                    : Icons.check_rounded,
                color: cs.primary),
            label: Text(widget.config == null ? '创建' : '保存',
                style:
                    TextStyle(color: cs.primary, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            AppSectionHeader(title: 'API 配置', cs: cs),
            const SizedBox(height: 12),
            AppCard(
              cs: cs,
              children: [
                TextFormField(
                  controller: _nameController,
                  decoration: appInputDecoration('配置名称 *', '例如：我的 DeepSeek',
                      Icons.bookmark_outline_rounded, cs),
                  validator: (v) => v?.isEmpty ?? true ? '请输入名称' : null,
                ),
                const SizedBox(height: 14),
                DropdownButtonFormField<ApiProvider>(
                  value: _selectedProvider,
                  decoration: appInputDecoration(
                      'API 提供商 *', null, Icons.public_outlined, cs),
                  items: ApiProvider.values.map((p) {
                    return DropdownMenuItem(value: p, child: Text(p.label));
                  }).toList(),
                  onChanged: (v) {
                    if (v != null) {
                      setState(() {
                        _selectedProvider = v;
                        if (v == ApiProvider.custom) {
                          _selectedModel = '';
                          _modelController.text = '';
                        } else {
                          _selectedModel =
                              ApiProvider.defaultModels[v.name] ?? '';
                          _modelController.text = _selectedModel;
                        }
                      });
                    }
                  },
                ),
                const SizedBox(height: 14),
                if (isCustom) ...[
                  TextFormField(
                    controller: _baseUrlController,
                    decoration: appInputDecoration('Base URL *',
                        'https://your-api.com/v1', Icons.link_rounded, cs),
                    validator: (v) =>
                        v?.isEmpty ?? true ? '请输入 Base URL' : null,
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _modelController,
                    decoration: appInputDecoration(
                        '模型名称 *', '输入模型 ID', Icons.model_training_outlined, cs),
                    validator: (v) => v?.isEmpty ?? true ? '请输入模型名称' : null,
                  ),
                ] else ...[
                  DropdownButtonFormField<String>(
                    value: _selectedModel.isNotEmpty &&
                            (ApiProvider.providerModels[_selectedProvider.name]
                                    ?.contains(_selectedModel) ??
                                false)
                        ? _selectedModel
                        : null,
                    decoration: appInputDecoration(
                        '模型 *', null, Icons.model_training_outlined, cs),
                    items:
                        (ApiProvider.providerModels[_selectedProvider.name] ??
                                [])
                            .map((model) {
                      return DropdownMenuItem(
                          value: model,
                          child: Text(model,
                              style: const TextStyle(
                                  fontFamily: 'monospace', fontSize: 13)));
                    }).toList(),
                    onChanged: (v) {
                      _selectedModel = v ?? '';
                      _modelController.text = _selectedModel;
                    },
                    validator: (v) => v == null ? '请选择模型' : null,
                  ),
                  const SizedBox(height: 14),
                ],
                TextFormField(
                  controller: _apiKeyController,
                  decoration: appInputDecoration(
                          widget.config == null
                              ? 'API Key *'
                              : 'API Key（留空保持当前值）',
                          '输入新的 API Key',
                          Icons.key_outlined,
                          cs)
                      .copyWith(
                    suffixIcon: IconButton(
                      icon: Icon(
                          _obscureApiKey
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                          size: 18),
                      onPressed: () =>
                          setState(() => _obscureApiKey = !_obscureApiKey),
                    ),
                  ),
                  obscureText: _obscureApiKey,
                  validator: (v) {
                    if (widget.config != null && (v?.trim().isEmpty ?? true)) {
                      return null;
                    }
                    return v?.trim().isEmpty ?? true ? '请输入 API Key' : null;
                  },
                ),
              ],
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _isSaving || _isTesting ? null : _testCurrentConfig,
              icon: _isTesting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.bolt_rounded, size: 18),
              label: Text(_isTesting ? '正在测试...' : '测试连接'),
            ),
            const SizedBox(height: 12),
            AppPrimaryButton(
              onPressed: _isSaving ? null : _save,
              icon: widget.config == null
                  ? Icons.add_circle_rounded
                  : Icons.check_rounded,
              label: widget.config == null ? '创建配置' : '保存配置',
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Future<void> _testCurrentConfig() async {
    if (!_formKey.currentState!.validate() || _isTesting) return;
    setState(() => _isTesting = true);
    final provider = _selectedProvider;
    final model =
        _selectedModel.isEmpty ? _modelController.text.trim() : _selectedModel;
    try {
      final enteredApiKey = _apiKeyController.text.trim();
      final apiKey = enteredApiKey.isNotEmpty
          ? enteredApiKey
          : widget.config == null
              ? null
              : await _credentialResolver.resolve(widget.config!);
      if (!mounted) return;
      if (apiKey == null || apiKey.isEmpty) {
        AppToast.show(context, '安全 API 凭据不可用', icon: Icons.key_off_outlined);
        return;
      }
      final result = await _apiService.testApiKey(
        apiKey: apiKey,
        provider: provider,
        customBaseUrl: _baseUrlController.text.trim(),
        model: model,
      );
      if (!mounted) return;
      final success = result['success'] == true;
      AppToast.show(
        context,
        success ? '连接测试成功' : '连接测试失败: ${result['message'] ?? '未知错误'}',
        icon: success
            ? Icons.check_circle_outline_rounded
            : Icons.error_outline_rounded,
      );
    } catch (_) {
      if (mounted) {
        AppToast.show(context, '连接测试失败', icon: Icons.error_outline_rounded);
      }
    } finally {
      if (mounted) setState(() => _isTesting = false);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate() || _isSaving) return;
    _isSaving = true;
    setState(() {});

    try {
      final config = ApiConfig(
        id: widget.config?.id,
        name: _nameController.text.trim(),
        provider: _selectedProvider.name,
        modelName: _selectedModel.isEmpty
            ? _modelController.text.trim()
            : _selectedModel,
        apiKey: _apiKeyController.text.trim(),
        customBaseUrl: _baseUrlController.text.trim(),
        createdAt: widget.config?.createdAt,
      );

      if (widget.config == null) {
        await ref.read(apiConfigsProvider.notifier).addConfig(config);
      } else {
        await ref.read(apiConfigsProvider.notifier).updateConfig(config);
      }

      if (mounted) {
        AppToast.show(context, widget.config == null ? '配置已创建' : '配置已更新',
            icon: Icons.check_circle_outline_rounded);
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        // 避免把 StateError 的异常类型与内部文案直接暴露给最终用户
        final message = e is StateError ? e.message : e.toString();
        AppToast.show(context, '保存失败：$message',
            icon: Icons.error_outline_rounded);
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }
}

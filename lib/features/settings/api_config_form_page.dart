import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_provider.dart';
import './providers/api_config_providers.dart';

class ApiConfigFormPage extends ConsumerStatefulWidget {
  final ApiConfig? config;

  const ApiConfigFormPage({super.key, this.config});

  @override
  ConsumerState<ApiConfigFormPage> createState() => _ApiConfigFormPageState();
}

class _ApiConfigFormPageState extends ConsumerState<ApiConfigFormPage> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _nameController;
  late TextEditingController _modelController;
  late TextEditingController _apiKeyController;
  late TextEditingController _baseUrlController;
  ApiProvider _selectedProvider = ApiProvider.deepseek;
  String _selectedModel = '';
  bool _obscureApiKey = true;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    final c = widget.config;
    _nameController = TextEditingController(text: c?.name ?? '');
    _modelController = TextEditingController(text: c?.modelName ?? '');
    _apiKeyController = TextEditingController(text: c?.apiKey ?? '');
    _baseUrlController = TextEditingController(text: c?.customBaseUrl ?? '');
    _selectedProvider = _parseProvider(c?.provider);
    _selectedModel = c?.modelName ?? ApiProvider.defaultModels[_selectedProvider.name] ?? '';
    if (_selectedProvider != ApiProvider.custom) {
      _modelController.text = _selectedModel;
    }
  }

  ApiProvider _parseProvider(String? name) {
    if (name == null) return ApiProvider.deepseek;
    try { return ApiProvider.values.firstWhere((p) => p.name == name); } catch (_) { return ApiProvider.deepseek; }
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
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 18, color: cs.onSurface)),
        actions: [
          TextButton.icon(
            onPressed: _isSaving ? null : _save,
            icon: Icon(widget.config == null ? Icons.add_circle_rounded : Icons.check_rounded, color: cs.primary),
            label: Text(widget.config == null ? '创建' : '保存', style: TextStyle(color: cs.primary, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            _buildSectionHeader('API 配置', cs),
            const SizedBox(height: 12),
            _buildCard(cs, [
              TextFormField(
                controller: _nameController,
                decoration: _inputDecoration('配置名称 *', '例如：我的 DeepSeek', Icons.bookmark_outline_rounded, cs),
                validator: (v) => v?.isEmpty ?? true ? '请输入名称' : null,
              ),
              const SizedBox(height: 14),
              DropdownButtonFormField<ApiProvider>(
                value: _selectedProvider,
                decoration: _inputDecoration('API 提供商 *', null, Icons.public_outlined, cs),
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
                        _selectedModel = ApiProvider.defaultModels[v.name] ?? '';
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
                  decoration: _inputDecoration('Base URL *', 'https://your-api.com/v1', Icons.link_rounded, cs),
                  validator: (v) => v?.isEmpty ?? true ? '请输入 Base URL' : null,
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _modelController,
                  decoration: _inputDecoration('模型名称 *', '输入模型 ID', Icons.model_training_outlined, cs),
                  validator: (v) => v?.isEmpty ?? true ? '请输入模型名称' : null,
                ),
              ] else ...[
                DropdownButtonFormField<String>(
                  value: _selectedModel.isNotEmpty &&
                          (ApiProvider.providerModels[_selectedProvider.name]?.contains(_selectedModel) ?? false)
                      ? _selectedModel
                      : null,
                  decoration: _inputDecoration('模型 *', null, Icons.model_training_outlined, cs),
                  items: (ApiProvider.providerModels[_selectedProvider.name] ?? []).map((model) {
                    return DropdownMenuItem(value: model, child: Text(model, style: const TextStyle(fontFamily: 'monospace', fontSize: 13)));
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
                decoration: _inputDecoration('API Key *', '输入你的 API Key', Icons.key_outlined, cs).copyWith(
                  suffixIcon: IconButton(
                    icon: Icon(_obscureApiKey ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 18),
                    onPressed: () => setState(() => _obscureApiKey = !_obscureApiKey),
                  ),
                ),
                obscureText: _obscureApiKey,
                validator: (v) => v?.isEmpty ?? true ? '请输入 API Key' : null,
              ),
            ]),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title, ColorScheme cs) {
    return Row(
      children: [
        Text(title, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: cs.primary, letterSpacing: 0.8)),
        const SizedBox(width: 12),
        Expanded(child: Divider(color: cs.primary.withOpacity(0.15), thickness: 0.5)),
      ],
    );
  }

  Widget _buildCard(ColorScheme cs, List<Widget> children) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: cs.outlineVariant.withOpacity(0.5))),
      color: cs.surfaceContainerHighest.withOpacity(0.4),
      child: Padding(padding: const EdgeInsets.all(16), child: Column(children: children)),
    );
  }

  InputDecoration _inputDecoration(String label, String? hint, IconData icon, ColorScheme cs) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      prefixIcon: Icon(icon, size: 18),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: cs.outlineVariant)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: cs.outlineVariant)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: cs.primary, width: 1.5)),
      filled: true,
      fillColor: cs.surfaceContainerHighest.withOpacity(0.4),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      labelStyle: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
      hintStyle: TextStyle(fontSize: 13, color: cs.onSurfaceVariant.withOpacity(0.5)),
    );
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
        modelName: _selectedModel.isEmpty ? _modelController.text.trim() : _selectedModel,
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
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(widget.config == null ? '配置已创建' : '配置已更新'), behavior: SnackBarBehavior.floating),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存失败: $e'), behavior: SnackBarBehavior.floating, backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }
}

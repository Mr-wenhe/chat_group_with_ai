import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/models/api_protocol.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/core/widgets/app_widgets.dart';
import 'package:chat_group/core/widgets/top_toast.dart';
import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/ai_governance/ai_governance_store.dart';
import 'package:chat_group/features/ai_governance/ai_request_gateway.dart';
import 'package:chat_group/features/ai_governance/model_capability_registry.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:chat_group/services/ai_providers/ai_api_service.dart';
import './providers/api_config_providers.dart';
import './widgets/model_capability_fields.dart';

class ApiConfigFormPage extends ConsumerStatefulWidget {
  final ApiConfig? config;

  const ApiConfigFormPage({super.key, this.config});

  @override
  ConsumerState<ApiConfigFormPage> createState() => _ApiConfigFormPageState();
}

class _ApiConfigFormPageState extends ConsumerState<ApiConfigFormPage> {
  final _formKey = GlobalKey<FormState>();
  late final AiApiService _apiService;
  late final AiGovernanceStore _governanceStore;
  final _credentialResolver = SecureApiCredentialResolver();
  final _registry = ModelCapabilityRegistry();
  late TextEditingController _nameController;
  late TextEditingController _modelController;
  late TextEditingController _apiKeyController;
  late TextEditingController _baseUrlController;
  final FocusNode _baseUrlFocusNode = FocusNode();
  final FocusNode _modelFocusNode = FocusNode();
  late final ModelCapabilityController _capabilityController;
  late ModelCapability _capabilityBuiltin;
  ApiProvider _selectedProvider = ApiProvider.deepseek;
  ApiProtocol _selectedProtocol = ApiProtocol.defaultValue;
  String _selectedModel = '';
  bool _obscureApiKey = true;
  bool _isSaving = false;
  bool _isTesting = false;

  /// 能力字段当前是为哪个「提供商/模型」回填的。只在模型身份真的变了才重新回填，
  /// 否则用户在字段上的编辑会被一次失焦build抹掉。
  String _capabilitySeededFor = '';

  /// 用户点了「恢复内置默认」：保存时清除声明而不是写入新声明。
  bool _restoreBuiltin = false;

  @override
  void initState() {
    super.initState();
    final db = ref.read(databaseServiceProvider);
    _governanceStore = AiGovernanceStore.forDatabase(db);
    _apiService = AiApiService(AiRequestGateway(store: _governanceStore));
    final c = widget.config;
    _nameController = TextEditingController(text: c?.name ?? '');
    _modelController = TextEditingController(text: c?.modelName ?? '');
    // 密钥不会从持久化模型回填到编辑框；留空代表保留现有安全凭据。
    _apiKeyController = TextEditingController();
    _baseUrlController = TextEditingController(text: c?.customBaseUrl ?? '');
    _selectedProvider = _parseProvider(c?.provider);
    _selectedProtocol = ApiProtocol.fromName(c?.apiProtocol);
    _selectedModel =
        c?.modelName ?? ApiProvider.defaultModels[_selectedProvider.name] ?? '';
    if (_selectedProvider != ApiProvider.custom) {
      _modelController.text = _selectedModel;
    }
    _capabilityBuiltin = _resolveBuiltinCapability();
    _capabilityController = ModelCapabilityController(_effectiveCapability());
    _capabilitySeededFor = _capabilityModelKey;
    _capabilityController.addListener(_onCapabilityEdited);
    _modelFocusNode.addListener(_onModelFocusChanged);
  }

  ApiProvider _parseProvider(String? name) {
    if (name == null) return ApiProvider.deepseek;
    try {
      return ApiProvider.values.firstWhere((p) => p.name == name);
    } catch (_) {
      return ApiProvider.deepseek;
    }
  }

  /// Custom providers use the text field as the source of truth. In
  /// particular, an edited existing config must not reuse its old model ID.
  String get _configuredModelName {
    if (_selectedProvider == ApiProvider.custom) {
      return _modelController.text.trim();
    }
    return _selectedModel.isNotEmpty
        ? _selectedModel
        : _modelController.text.trim();
  }

  /// 能力字段的回填边界：提供商或模型名任一改变都要重新回填。
  String get _capabilityModelKey =>
      '${_selectedProvider.name}/$_configuredModelName';

  bool get _hasStoredDeclaration => _storedDeclaration() != null;

  CustomModelCapability? _storedDeclaration() =>
      _governanceStore.customCapability(
        _selectedProvider.name,
        _configuredModelName,
      );

  /// 该模型当前生效的能力：内置快照与已存声明的合并结果。
  ModelCapability _effectiveCapability() => _resolveCapability(
        _storedDeclaration(),
      );

  /// 该模型的内置快照值；未知模型会落到保守降级值。
  ModelCapability _resolveBuiltinCapability() => _resolveCapability(null);

  ModelCapability _resolveCapability(CustomModelCapability? custom) =>
      _registry.resolve(
        provider: _selectedProvider,
        modelId: _configuredModelName,
        custom: custom,
      );

  /// 模型身份变了才把字段回填为新模型的生效值。
  void _reseedCapabilityFields() {
    if (_capabilityModelKey == _capabilitySeededFor) return;
    _capabilityController.seed(_effectiveCapability());
    _capabilityBuiltin = _resolveBuiltinCapability();
    _capabilitySeededFor = _capabilityModelKey;
    _restoreBuiltin = false;
  }

  /// 用户动手改过字段，就不再是「恢复内置默认」待执行状态。
  void _onCapabilityEdited() {
    if (_restoreBuiltin) _restoreBuiltin = false;
  }

  /// 自定义提供商的模型名是手输的，只在失焦时重新回填，避免每个按键都清空编辑。
  void _onModelFocusChanged() {
    if (_modelFocusNode.hasFocus) return;
    if (_capabilityModelKey == _capabilitySeededFor) return;
    setState(_reseedCapabilityFields);
  }

  void _restoreCapabilityBuiltin() {
    setState(() {
      _capabilityController.seed(_resolveBuiltinCapability());
      // 必须在 seed 之后置位：seed 的 notifyListeners 会走 _onCapabilityEdited。
      _restoreBuiltin = true;
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _modelController.dispose();
    _apiKeyController.dispose();
    _baseUrlController.dispose();
    _baseUrlFocusNode.dispose();
    _modelFocusNode.removeListener(_onModelFocusChanged);
    _modelFocusNode.dispose();
    _capabilityController.removeListener(_onCapabilityEdited);
    _capabilityController.dispose();
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
                        if (v != ApiProvider.custom) {
                          _selectedProtocol = ApiProtocol.defaultValue;
                        }
                        if (v == ApiProvider.custom) {
                          _selectedModel = '';
                          _modelController.text = '';
                        } else {
                          _selectedModel =
                              ApiProvider.defaultModels[v.name] ?? '';
                          _modelController.text = _selectedModel;
                        }
                        _reseedCapabilityFields();
                      });
                    }
                  },
                ),
                const SizedBox(height: 14),
                if (isCustom) ...[
                  DropdownButtonFormField<ApiProtocol>(
                    value: _selectedProtocol,
                    isExpanded: true,
                    decoration: appInputDecoration(
                      '上游格式 *',
                      null,
                      Icons.alt_route_rounded,
                      cs,
                    ),
                    items: ApiProtocol.values
                        .map((protocol) => DropdownMenuItem(
                              value: protocol,
                              child: Text(
                                protocol.label,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ))
                        .toList(),
                    onChanged: (v) {
                      if (v != null) setState(() => _selectedProtocol = v);
                    },
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      _selectedProtocol.description,
                      style:
                          TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '请选择与 Base URL 对应的上游协议；本应用不会自动开启或依赖本地路由。',
                      style: TextStyle(
                        fontSize: 11,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Semantics(
                    container: true,
                    textField: true,
                    label: 'Base URL 输入框',
                    onTap: _baseUrlFocusNode.requestFocus,
                    child: TextFormField(
                      key: const Key('api-config-base-url'),
                      controller: _baseUrlController,
                      focusNode: _baseUrlFocusNode,
                      decoration: appInputDecoration(
                        'Base URL *',
                        _selectedProtocol.baseUrlHint,
                        Icons.link_rounded,
                        cs,
                      ),
                      validator: (v) =>
                          v?.trim().isEmpty ?? true ? '请输入 Base URL' : null,
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _modelController,
                    focusNode: _modelFocusNode,
                    decoration: appInputDecoration(
                        '模型名称 *', '输入模型 ID', Icons.model_training_outlined, cs),
                    validator: (v) =>
                        v?.trim().isEmpty ?? true ? '请输入模型名称' : null,
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
                      setState(() {
                        _selectedModel = v ?? '';
                        _modelController.text = _selectedModel;
                        _reseedCapabilityFields();
                      });
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
            AppSectionHeader(title: '模型能力', icon: Icons.tune_rounded, cs: cs),
            const SizedBox(height: 12),
            AppCard(
              cs: cs,
              children: [
                ModelCapabilityFields(
                  cs: cs,
                  controller: _capabilityController,
                  builtin: _capabilityBuiltin,
                  onRestoreBuiltin: _hasStoredDeclaration && !_restoreBuiltin
                      ? _restoreCapabilityBuiltin
                      : null,
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
    final model = _configuredModelName;
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
        apiProtocol: _selectedProtocol,
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

  /// 保存模型能力声明。写不写、写什么，全部由 [modelCapabilityPersistAction]
  /// 判定——表单里的字段与线上生效值之间隔着内置快照的合并规则，就地重写一遍
  /// 判据迟早会与治理页那份分叉。
  Future<void> _persistCapabilityDeclaration(
    ApiProvider provider,
    String modelName,
  ) async {
    // 字段回填的仍是上一个模型的值：自定义提供商的模型名是手输的，而移动端
    // 点击按钮不会让输入框失焦，"_onModelFocusChanged" 于是不触发——用户改完
    // 模型名直接点保存时就会走到这里。这份草稿描述的是另一个模型，写下去等于
    // 给它凭空固化一份自己从未有过的声明（例如沿用旧模型的"工具/流式"开关，
    // 让工作模式对着一个未必支持工具的模型启动）。保存模型名本身仍然进行。
    //
    // "恢复内置默认"不受这道守卫约束：它是清除、没有草稿可污染，而它自己的按钮
    // 本就按保存时的模型名决定是否出现；挡住它只会让按钮保持隐藏、用户无从重试。
    if (!_restoreBuiltin &&
        _capabilitySeededFor != '${provider.name}/$modelName') {
      return;
    }
    final declared = _capabilityController.declared;
    final action = modelCapabilityPersistAction(
      restoreBuiltin: _restoreBuiltin,
      declared: declared,
      registry: _registry,
      provider: provider,
      modelId: modelName,
      effective: _registry.resolve(
        provider: provider,
        modelId: modelName,
        custom: _governanceStore.customCapability(provider.name, modelName),
      ),
    );
    switch (action) {
      case ModelCapabilityPersistAction.clear:
        await _governanceStore.clearCustomCapability(provider.name, modelName);
      case ModelCapabilityPersistAction.save:
        await _governanceStore.saveCustomCapability(
          provider.name,
          modelName,
          declared!,
        );
      case ModelCapabilityPersistAction.keep:
        break;
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate() || _isSaving) return;
    _isSaving = true;
    setState(() {});

    try {
      final provider = _selectedProvider;
      final modelName = _configuredModelName;
      final config = ApiConfig(
        id: widget.config?.id,
        name: _nameController.text.trim(),
        provider: provider.name,
        apiProtocol: _selectedProtocol.name,
        modelName: modelName,
        apiKey: _apiKeyController.text.trim(),
        customBaseUrl: _baseUrlController.text.trim(),
        createdAt: widget.config?.createdAt,
      );

      if (widget.config == null) {
        await ref.read(apiConfigsProvider.notifier).addConfig(config);
      } else {
        await ref.read(apiConfigsProvider.notifier).updateConfig(config);
      }

      await _persistCapabilityDeclaration(provider, modelName);

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

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
import 'package:chat_group/services/chat_api_service.dart';
import './model_catalog_picker.dart';
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
  bool _obscureApiKey = true;
  bool _enableWorkPromptCaching = false;
  bool _isSaving = false;
  bool _isTesting = false;

  /// 本次会话拉到的真实模型清单；为空表示还没拉过或已失效（改用内置候选）。
  List<ProviderModelInfo>? _fetchedModels;
  bool _isFetchingModels = false;

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
    _enableWorkPromptCaching = c?.enableWorkPromptCaching ?? false;
    _nameController = TextEditingController(text: c?.name ?? '');
    // 密钥不会从持久化模型回填到编辑框；留空代表保留现有安全凭据。
    _apiKeyController = TextEditingController();
    _selectedProvider = _parseProvider(c?.provider);
    // 新建时按提供商的默认协议起手（Oray 这类只支持一种协议的提供商不能靠
    // 全站默认值），编辑已有配置时以存下来的为准。
    _selectedProtocol = c == null
        ? _selectedProvider.defaultProtocol
        : ApiProtocol.fromName(c.apiProtocol);
    // 模型不再预填内置默认值：那份清单会过时（deepseek-chat 已不存在），预填等于
    // 让用户保存一个跑不通的模型。留空，由「获取模型」给出真实候选。
    _modelController = TextEditingController(text: c?.modelName ?? '');
    // 内置提供商也显示地址，所以起手值必须在"还没填过"时等于请求实际会用的地址。
    _baseUrlController = TextEditingController(
      text: initialBaseUrl(config: c, provider: _selectedProvider),
    );
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

  /// 模型名就是输入框里的文字，没有第二处来源。
  ///
  /// 过去内置提供商走下拉、自定义走手输，两套来源让「已填的模型」要按提供商分叉
  /// 判断；下拉去掉后只剩一个口，编辑已有配置时也不会再拿旧模型 ID 冒充新值。
  String get _configuredModelName => _modelController.text.trim();

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

  /// 该模型的内置快照值；未登记模型会落到兜底默认值。
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

  /// 模型名是手输的，只在失焦时重新回填，避免每个按键都清空编辑。
  void _onModelFocusChanged() {
    if (_modelFocusNode.hasFocus) return;
    if (_capabilityModelKey == _capabilitySeededFor) return;
    setState(_reseedCapabilityFields);
  }

  /// 换服务商：地址回到新提供商的预设，模型清空——上一个服务商的模型名
  /// 在新服务商上没有任何意义。
  void _onProviderChanged(ApiProvider? value) {
    if (value == null) return;
    setState(() {
      _selectedProvider = value;
      _selectedProtocol = value.defaultProtocol;
      _baseUrlController.text = initialBaseUrl(config: null, provider: value);
      _modelController.text = '';
      _fetchedModels = null;
      _reseedCapabilityFields();
    });
  }

  void _applyModelChoice(ProviderModelInfo info) {
    setState(() {
      _modelController.text = info.id;
      _reseedCapabilityFields();
      applyFetchedCapability(_capabilityController, info);
    });
  }

  /// 用当前 API Key 拉取模型清单。
  ///
  /// Key 的取法遵循「测试连接」的同一红线：输入框里新填的直接用；留空且是编辑已有
  /// 配置才读已保存凭据；两者都没有就明说，不去猜。
  Future<void> _fetchModels() async {
    if (_isFetchingModels) return;
    final provider = _selectedProvider;
    var apiKey = _apiKeyController.text.trim();
    if (apiKey.isEmpty) {
      final existing = widget.config;
      if (existing == null) {
        AppToast.show(context, '请先填写 API Key', icon: Icons.key_off_outlined);
        return;
      }
      apiKey = await _credentialResolver.resolve(existing) ?? '';
      if (!mounted) return;
      if (apiKey.isEmpty) {
        AppToast.show(context, '安全 API 凭据不可用', icon: Icons.key_off_outlined);
        return;
      }
    }

    setState(() => _isFetchingModels = true);
    try {
      final catalog = await _apiService.fetchModels(
        apiKey: apiKey,
        provider: provider,
        apiProtocol: _selectedProtocol,
        customBaseUrl: _baseUrlController.text.trim(),
      );
      if (!mounted) return;
      if (!catalog.ok) {
        AppToast.show(context, '获取模型失败：${catalog.message}',
            icon: Icons.error_outline_rounded);
        return;
      }
      setState(() => _fetchedModels = catalog.models);
      // 内置与自定义走同一个出口：清单让用户自己挑，挑完回填输入框。
      final picked = await showModelPicker(
        context,
        models: modelChoices(
          fetched: catalog.models,
          provider: provider,
          currentModel: _configuredModelName,
        ),
        selectedId: _configuredModelName,
      );
      if (picked != null && mounted) _applyModelChoice(picked);
    } catch (_) {
      if (mounted) {
        AppToast.show(context, '获取模型失败', icon: Icons.error_outline_rounded);
      }
    } finally {
      if (mounted) setState(() => _isFetchingModels = false);
    }
  }

  Widget _fetchModelsButton(ColorScheme cs) => IconButton(
        key: const Key('fetch-models-button'),
        tooltip: '用当前 API Key 获取可用模型',
        onPressed: _isFetchingModels ? null : _fetchModels,
        icon: _isFetchingModels
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.cloud_download_outlined, size: 20),
      );

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
                  onChanged: _onProviderChanged,
                ),
                const SizedBox(height: 14),
                DropdownButtonFormField<ApiProtocol>(
                  key: const Key('protocol-field'),
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
                    if (v != null) {
                      setState(() {
                        _selectedProtocol = v;
                        // 协议变了，拉到的清单不再保证属于这个端点。
                        _fetchedModels = null;
                      });
                    }
                  },
                ),
                if (_selectedProtocol != ApiProtocol.geminiGenerateContent)
                  SwitchListTile(
                    key: const Key('work-prompt-caching'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('工作模式缓存优化'),
                    subtitle: const Text('仅在确认此接口支持后开启。缓存写入可能单独计费；'
                        '命中量以上游返回为准。关闭后不发送额外缓存参数。'),
                    value: _enableWorkPromptCaching,
                    onChanged: (value) =>
                        setState(() => _enableWorkPromptCaching = value),
                  ),
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _selectedProtocol.description,
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '请选择与 Base URL 对应的上游协议；内置提供商的预设地址同样按此协议拼接，'
                    '本应用不会自动开启或依赖本地路由。',
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
                    onChanged: (_) {
                      // 地址改了，已拉到的清单可能属于另一个端点。
                      if (_fetchedModels != null) {
                        setState(() => _fetchedModels = null);
                      }
                    },
                    validator: (v) =>
                        v?.trim().isEmpty ?? true ? '请输入 Base URL' : null,
                  ),
                ),
                const SizedBox(height: 14),
                // 模型一律手输：下拉把「这个服务商到底有哪些模型」当成一份固定清单，
                // 而这份清单由服务商随时改（内置候选里的 deepseek-chat 已经不存在），
                // 用户真正想要的那个别名又常常不在列表里。给一个自由输入框，把
                // 「获取模型」当成可选帮助。
                TextFormField(
                  key: const Key('model-field'),
                  controller: _modelController,
                  focusNode: _modelFocusNode,
                  decoration: appInputDecoration('模型名称 *', '输入模型 ID，或点右侧按钮获取',
                          Icons.model_training_outlined, cs)
                      .copyWith(suffixIcon: _fetchModelsButton(cs)),
                  validator: (v) =>
                      v?.trim().isEmpty ?? true ? '请输入模型名称' : null,
                ),
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
  /// 判据迟早会与治理页那份分叉（未登记模型的补写规则也在那里）。
  Future<void> _persistCapabilityDeclaration(
    ApiProvider provider,
    String modelName,
  ) async {
    final declared = _capabilityController.declared;
    final stored = _governanceStore.customCapability(provider.name, modelName);
    final action = modelCapabilityPersistAction(
      restoreBuiltin: _restoreBuiltin,
      declared: declared,
      stored: stored,
      registry: _registry,
      provider: provider,
      modelId: modelName,
      effective: _registry.resolve(
        provider: provider,
        modelId: modelName,
        custom: stored,
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
    // 模型名是手输的，而移动端点击按钮不会让输入框失焦，"_onModelFocusChanged"
    // 于是不触发——不回填就保存，能力字段描述的仍是上一个模型。保存前对齐一次，
    // 而不是在写盘口把这份草稿拦下来：拦下来只会静默丢掉用户的开关设置。
    // 模型没变时 [_reseedCapabilityFields] 直接早退，用户的编辑不受影响。
    _reseedCapabilityFields();
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
        enableWorkPromptCaching: _enableWorkPromptCaching,
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

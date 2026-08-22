import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'package:hive/hive.dart';

import 'package:chat_group/core/storage/credential_repository.dart';
import 'package:chat_group/features/web_search/application/search_provider_config_service.dart';
import 'package:chat_group/features/web_search/data/search_credential_repository.dart';
import 'package:chat_group/features/web_search/data/search_settings_store.dart';
import 'package:chat_group/features/web_search/models/search_provider_config.dart';
import 'package:chat_group/features/web_search/models/search_models.dart';
import 'package:chat_group/features/web_search/providers/duckduckgo_instant_answer_provider.dart';
import 'package:chat_group/features/web_search/providers/search_provider.dart';
import 'package:chat_group/features/web_search/security/search_endpoint_validator.dart';

class SearchProviderConfigFormPage extends StatefulWidget {
  final SearchProviderConfig? config;
  final SearchProviderConfigStore? store;
  final SearchProviderFactory? providerFactory;

  const SearchProviderConfigFormPage({
    super.key,
    this.config,
    this.store,
    this.providerFactory,
  });

  @override
  State<SearchProviderConfigFormPage> createState() =>
      _SearchProviderConfigFormPageState();
}

class _SearchProviderConfigFormPageState
    extends State<SearchProviderConfigFormPage> {
  final _formKey = GlobalKey<FormState>();
  late final SearchProviderConfigStore _store;
  late final SearchProviderConfigService _service;
  late final TextEditingController _nameController;
  late final TextEditingController _baseUrlController;
  late final TextEditingController _credentialController;
  late SearchProviderKind _provider;
  late bool _enabled;
  late bool _isDefault;
  bool _isTesting = false;
  bool _isSaving = false;
  bool _obscureCredential = true;

  static const _configurableProviders = <SearchProviderKind>[
    SearchProviderKind.gateway,
    SearchProviderKind.tavily,
    SearchProviderKind.brave,
  ];

  @override
  void initState() {
    super.initState();
    _store = widget.store ??
        SearchProviderConfigStore(
          box: Hive.box<dynamic>('app_settings'),
        );
    _service = SearchProviderConfigService(
      store: _store,
      credentialResolver: SearchCredentialResolver(
        credentials: _store.credentials,
        isRelease: _store.isRelease,
      ),
      providerFactory: widget.providerFactory ?? _defaultProviderFactory,
    );
    final config = widget.config;
    _nameController = TextEditingController(text: config?.name ?? '');
    _baseUrlController = TextEditingController(
      text: config?.baseUrl ?? '',
    );
    _credentialController = TextEditingController();
    _provider = config?.provider ?? SearchProviderKind.brave;
    _enabled = config?.enabled ?? true;
    _isDefault = config?.isDefault ?? false;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _baseUrlController.dispose();
    _credentialController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.config != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(editing ? '编辑搜索 Provider' : '添加搜索 Provider'),
        actions: [
          TextButton(
            onPressed: _isSaving ? null : _save,
            child: const Text('保存配置'),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              key: const ValueKey('search-config-name'),
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Provider 名称',
                border: OutlineInputBorder(),
              ),
              validator: (value) =>
                  value?.trim().isEmpty == true ? '请输入 Provider 名称' : null,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<SearchProviderKind>(
              value: _provider,
              decoration: const InputDecoration(
                labelText: 'Provider 类型',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final provider in _providerOptions)
                  DropdownMenuItem(
                    value: provider,
                    child: Text(_providerLabel(provider)),
                  ),
              ],
              onChanged: _isSaving
                  ? null
                  : (value) {
                      if (value != null) setState(() => _provider = value);
                    },
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const ValueKey('search-config-base-url'),
              controller: _baseUrlController,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Base URL',
                hintText: 'https://search.example.com/v1',
                border: OutlineInputBorder(),
              ),
              validator: (value) => SearchEndpointValidator.errorFor(
                value ?? '',
                isRelease: _store.isRelease,
                allowLocalDevelopmentGateway:
                    _store.allowLocalDevelopmentGateway,
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const ValueKey('search-config-credential'),
              controller: _credentialController,
              obscureText: _obscureCredential,
              decoration: InputDecoration(
                labelText: editing ? 'API Key（留空保持当前值）' : 'API Key',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(_obscureCredential
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined),
                  onPressed: () => setState(
                    () => _obscureCredential = !_obscureCredential,
                  ),
                ),
              ),
              validator: (value) {
                final providerNeedsKey =
                    _provider == SearchProviderKind.tavily ||
                        _provider == SearchProviderKind.brave;
                final providerChanged =
                    editing && widget.config!.provider != _provider;
                if (!providerNeedsKey || (editing && !providerChanged)) {
                  return null;
                }
                return value?.trim().isEmpty == true ? '请输入 API Key' : null;
              },
            ),
            const SizedBox(height: 4),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('启用此 Provider'),
              value: _enabled,
              onChanged: _isSaving
                  ? null
                  : (value) => setState(() => _enabled = value),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('设为默认搜索源'),
              value: _isDefault,
              onChanged: _isSaving
                  ? null
                  : (value) => setState(() => _isDefault = value),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed:
                  _isTesting || _isSaving || !_supportsConnectionTest(_provider)
                      ? null
                      : _testConnection,
              icon: _isTesting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.bolt_outlined),
              label: Text(_isTesting ? '正在测试...' : '测试连接'),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _isSaving ? null : _save,
              icon: const Icon(Icons.save_outlined),
              label: const Text('保存配置'),
            ),
            const SizedBox(height: 24),
            Text(
              editing
                  ? 'Key 输入框不会回填；留空只会保留当前安全凭据。'
                  : '连接测试直接使用本次输入的 Key，只有点击保存配置才会持久化。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (!_supportsConnectionTest(_provider)) ...[
              const SizedBox(height: 8),
              Text(
                '该 Provider 的连接测试将在对应 Provider 接入后开放；当前仍可保存配置元数据。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }

  SearchProviderConfig _draft() {
    final preserveCredential =
        widget.config != null && widget.config!.provider == _provider;
    return SearchProviderConfig(
      id: widget.config?.id ?? const Uuid().v4(),
      name: _nameController.text.trim(),
      provider: _provider,
      baseUrl: _baseUrlController.text.trim(),
      enabled: _enabled,
      isDefault: _isDefault,
      credentialId: preserveCredential ? widget.config!.credentialId : '',
      hasCredential: preserveCredential && widget.config!.hasCredential,
    );
  }

  List<SearchProviderKind> get _providerOptions {
    final options = <SearchProviderKind>{..._configurableProviders};
    if (widget.config?.provider == SearchProviderKind.duckDuckGoInstantAnswer) {
      options.add(SearchProviderKind.duckDuckGoInstantAnswer);
    }
    return options.toList(growable: false);
  }

  Future<void> _testConnection() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _isTesting = true);
    try {
      final result = await _service.testConnection(
        config: _draft(),
        enteredCredential: _credentialController.text,
      );
      if (!mounted) return;
      _showMessage(
        result.isHealthy ? '连接测试成功' : (result.errorMessage ?? '连接测试失败'),
        isError: !result.isHealthy,
      );
    } finally {
      if (mounted) setState(() => _isTesting = false);
    }
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _isSaving = true);
    try {
      final result = await _service.save(
        _draft(),
        enteredCredential: _credentialController.text,
      );
      if (!mounted) return;
      if (!result.isSuccess) {
        _showMessage(result.errorMessage ?? _credentialFailureMessage(result),
            isError: true);
        return;
      }
      _credentialController.clear();
      Navigator.of(context).pop(result.config);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  void _showMessage(String message, {required bool isError}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Theme.of(context).colorScheme.error : null,
      ),
    );
  }

  String _credentialFailureMessage(SearchProviderConfigSaveResult result) {
    return switch (result.credentialFailure) {
      CredentialFailure.unavailable => '安全存储不可用，未保存配置',
      CredentialFailure.permissionDenied => '安全存储权限被拒绝，未保存配置',
      CredentialFailure.systemError => '安全凭据写入失败，未保存配置',
      null => '搜索配置保存失败',
    };
  }

  SearchProvider _defaultProviderFactory(SearchProviderConfig config) {
    if (config.provider == SearchProviderKind.duckDuckGoInstantAnswer) {
      return DuckDuckGoInstantAnswerProvider();
    }
    throw UnsupportedError('该 Provider 尚未接入连接测试');
  }

  bool _supportsConnectionTest(SearchProviderKind provider) =>
      widget.providerFactory != null ||
      provider == SearchProviderKind.duckDuckGoInstantAnswer;

  String _providerLabel(SearchProviderKind provider) => switch (provider) {
        SearchProviderKind.gateway => 'Backend Gateway',
        SearchProviderKind.tavily => 'Tavily',
        SearchProviderKind.brave => 'Brave',
        SearchProviderKind.duckDuckGoInstantAnswer => 'DuckDuckGo 百科即时答案',
      };
}

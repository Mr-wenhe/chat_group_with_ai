import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/ai_governance/ai_governance_store.dart';
import 'package:chat_group/features/ai_governance/model_capability_registry.dart';
import 'package:chat_group/features/ai_governance/money_micros.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:chat_group/features/web_search/application/search_cache_controller.dart';
import 'package:chat_group/features/web_search/presentation/web_search_audit_card.dart';
import 'package:chat_group/features/web_search/presentation/web_search_settings_section.dart';
import 'package:chat_group/features/web_search/presentation/web_search_runtime_settings_card.dart';
import 'package:chat_group/features/web_search/data/zhipu_native_search_credential_store.dart';
import 'package:chat_group/features/web_search/presentation/zhipu_native_search_settings_card.dart';
import 'package:chat_group/features/settings/widgets/model_capability_fields.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

part 'ai_governance_page_support.dart';

class AiGovernancePage extends ConsumerStatefulWidget {
  const AiGovernancePage({super.key});

  @override
  ConsumerState<AiGovernancePage> createState() => _AiGovernancePageState();
}

class _AiGovernancePageState extends ConsumerState<AiGovernancePage> {
  late final DatabaseService _db;
  late final AiGovernanceStore _store;
  late final SearchProviderConfigStore _searchSettings;
  late final ZhipuNativeSearchCredentialStore _zhipuSearchCredentials;
  final _registry = ModelCapabilityRegistry();
  late BudgetSettings _budget;
  late WebSearchPolicy _searchPolicy;
  late final TextEditingController _daily;
  late final TextEditingController _monthly;
  late final TextEditingController _conversation;
  late final TextEditingController _autoChat;

  @override
  void initState() {
    super.initState();
    _db = ref.read(databaseServiceProvider);
    _store = AiGovernanceStore.forDatabase(_db);
    _searchSettings = SearchProviderConfigStore(db: _db);
    _zhipuSearchCredentials = ZhipuNativeSearchCredentialStore(db: _db);
    _budget = _store.budgetSettings;
    _searchPolicy = _store.globalSearchPolicy;
    _daily = TextEditingController(
      text: MoneyMicros.editingText(_budget.dailyHardLimitMicros),
    );
    _monthly = TextEditingController(
      text: MoneyMicros.editingText(_budget.monthlyHardLimitMicros),
    );
    _conversation = TextEditingController(
      text: MoneyMicros.editingText(_budget.conversationHardLimitMicros),
    );
    _autoChat = TextEditingController(
      text: MoneyMicros.editingText(_budget.autoChatDailyHardLimitMicros),
    );
  }

  @override
  void dispose() {
    _daily.dispose();
    _monthly.dispose();
    _conversation.dispose();
    _autoChat.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('模型、成本与联网治理')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 48),
        children: [
          _searchControls(),
          _title('预算（USD，留空表示不限）'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  _moneyField(_daily, '全局每日硬上限'),
                  _moneyField(_monthly, '全局每月硬上限'),
                  _moneyField(_conversation, '单会话硬上限'),
                  _moneyField(_autoChat, '自动聊天每日硬上限'),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('允许用户主动请求越过硬上限'),
                    subtitle: const Text('仅影响明确由用户发起的回复或工作任务'),
                    value: _budget.allowUserOverride,
                    onChanged: (value) => setState(
                      () =>
                          _budget = _budget.copyWith(allowUserOverride: value),
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('允许自动聊天调用'),
                    value: _budget.autoChatEnabled,
                    onChanged: (value) => setState(
                      () => _budget = _budget.copyWith(autoChatEnabled: value),
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('允许主动消息调用'),
                    value: _budget.proactiveEnabled,
                    onChanged: (value) => setState(
                      () => _budget = _budget.copyWith(proactiveEnabled: value),
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('允许记忆摘要调用'),
                    value: _budget.summaryEnabled,
                    onChanged: (value) => setState(
                      () => _budget = _budget.copyWith(summaryEnabled: value),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.icon(
                      onPressed: _saveBudget,
                      icon: const Icon(Icons.save_outlined),
                      label: const Text('保存预算'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          _title('模型能力'),
          ..._db.apiConfigBox.values.map(_capabilityCard),
          _title('费用账本'),
          _usageCard(),
          _title('脱敏诊断'),
          _diagnosticsCard(),
          _title('联网记录'),
          WebSearchAuditCard(
            entries: _store.searchAudits,
            onClear: _clearSearchAudits,
          ),
        ],
      ),
    );
  }

  Widget _searchControls() {
    if (kIsWeb) {
      return const Card(
        child: ListTile(
          leading: Icon(Icons.info_outline),
          title: Text('Web 端不支持联网搜索'),
          subtitle: Text('请使用 Android、iOS、macOS 或 Windows 版本。'),
        ),
      );
    }
    return Column(
      children: [
        _title('联网搜索'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SegmentedButton<WebSearchPolicy>(
                  segments: [
                    for (final policy in WebSearchPolicy.values)
                      ButtonSegment(
                        value: policy,
                        label: Text(policy.label),
                      ),
                  ],
                  selected: {_searchPolicy},
                  onSelectionChanged: (values) async {
                    final policy = values.first;
                    await _store.saveGlobalSearchPolicy(policy);
                    if (mounted) setState(() => _searchPolicy = policy);
                  },
                ),
                const SizedBox(height: 12),
                const Text(
                  '默认关闭。询问模式每次都需明确同意；启用后，查询会发送给下方配置的 '
                  'Provider 或智谱原生 Web Search。DuckDuckGo 仅作为百科即时答案兜底，'
                  '不等同于完整 Web 搜索。',
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        WebSearchSettingsSection(store: _searchSettings),
        const SizedBox(height: 8),
        ZhipuNativeSearchSettingsCard(store: _zhipuSearchCredentials),
        const SizedBox(height: 8),
        WebSearchRuntimeSettingsCard(
          initialSettings: _searchSettings.runtimeSettings,
          onSave: _searchSettings.saveRuntimeSettings,
          onClearCache: () => SearchCacheController.clear(_searchSettings),
        ),
      ],
    );
  }

  Widget _title(String text) => ListTile(
        contentPadding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
        title: Text(text, style: Theme.of(context).textTheme.titleMedium),
      );

  Widget _moneyField(TextEditingController controller, String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: controller,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
        decoration: InputDecoration(
          labelText: label,
          prefixText: r'$ ',
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  Widget _capabilityCard(config) {
    final provider = ApiProvider.values.firstWhere(
      (value) => value.name == config.provider,
      orElse: () => ApiProvider.custom,
    );
    final custom = _store.customCapability(provider.name, config.modelName);
    final capability = _registry.resolve(
      provider: provider,
      modelId: config.modelName,
      custom: custom,
    );
    final price = capability.price;
    return Card(
      child: ListTile(
        title: Text('${config.name} · ${config.modelName}'),
        subtitle: Text(
          '上下文 ${capability.contextWindow} · 输出 ${capability.maxOutput} · '
          '视觉 ${_yes(capability.supportsVision)} · '
          '流式 ${_yes(capability.supportsStreaming)} · '
          '工具 ${_yes(capability.supportsTools)}\n'
          '${price == null ? '价格未知' : '价格版本 ${price.version}'} · '
          '${capability.source} · ${capability.updatedAt.toIso8601String().split('T').first}',
        ),
        isThreeLine: true,
        trailing: IconButton(
          onPressed: () => _editCustomCapability(
            provider,
            config.modelName,
            custom,
          ),
          icon: const Icon(Icons.tune_rounded),
          tooltip: '声明能力',
        ),
      ),
    );
  }

  Future<void> _saveBudget() async {
    try {
      final daily = MoneyMicros.parseUsd(_daily.text);
      final monthly = MoneyMicros.parseUsd(_monthly.text);
      final conversation = MoneyMicros.parseUsd(_conversation.text);
      final autoChat = MoneyMicros.parseUsd(_autoChat.text);
      final next = _budget.copyWith(
        dailyHardLimitMicros: daily,
        monthlyHardLimitMicros: monthly,
        conversationHardLimitMicros: conversation,
        autoChatDailyHardLimitMicros: autoChat,
        clearDaily: daily == null,
        clearMonthly: monthly == null,
        clearConversation: conversation == null,
        clearAutoChat: autoChat == null,
      );
      await _store.saveBudgetSettings(next);
      if (!mounted) return;
      setState(() => _budget = next);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('预算设置已保存')));
    } on FormatException catch (error) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  Future<void> _editCustomCapability(
    ApiProvider provider,
    String model,
    CustomModelCapability? current,
  ) async {
    final effective = _registry.resolve(
      provider: provider,
      modelId: model,
      custom: current,
    );
    final result = await showDialog<ModelCapabilityEditResult>(
      context: context,
      builder: (_) => _CustomModelCapabilityDialog(
        model: model,
        effective: effective,
        builtin: _registry.resolve(provider: provider, modelId: model),
        hasDeclaration: current != null,
      ),
    );
    if (result == null) return;
    switch (modelCapabilityPersistAction(
      restoreBuiltin: result.restoreBuiltin,
      declared: result.capability,
      registry: _registry,
      provider: provider,
      modelId: model,
      effective: effective,
    )) {
      case ModelCapabilityPersistAction.clear:
        await _store.clearCustomCapability(provider.name, model);
      case ModelCapabilityPersistAction.save:
        await _store.saveCustomCapability(
          provider.name,
          model,
          result.capability!,
        );
      case ModelCapabilityPersistAction.keep:
        break;
    }
    if (mounted) setState(() {});
  }

  Future<void> _clearUsage() async {
    await _store.clearLedger();
    if (mounted) setState(() {});
  }

  Future<void> _clearDiagnostics() async {
    await _store.clearDiagnostics();
    if (mounted) setState(() {});
  }

  Future<void> _clearSearchAudits() async {
    await _store.clearSearchAudits();
    if (mounted) setState(() {});
  }

  static String _yes(bool value) => value ? '支持' : '不支持';
}

/// Owns its capability controller so it stays alive until the dialog route has
/// fully removed the widget, including the reverse transition after a pop.
class _CustomModelCapabilityDialog extends StatefulWidget {
  final String model;

  /// 当前生效值（内置快照与已存声明的合并结果），也是字段的初始值。
  final ModelCapability effective;

  /// 该模型的内置快照值，用于提示「低于内置值不会生效」。
  final ModelCapability builtin;

  final bool hasDeclaration;

  const _CustomModelCapabilityDialog({
    required this.model,
    required this.effective,
    required this.builtin,
    required this.hasDeclaration,
  });

  @override
  State<_CustomModelCapabilityDialog> createState() =>
      _CustomModelCapabilityDialogState();
}

class _CustomModelCapabilityDialogState
    extends State<_CustomModelCapabilityDialog> {
  final _formKey = GlobalKey<FormState>();
  late final ModelCapabilityController _controller =
      ModelCapabilityController(widget.effective);
  bool _restoreBuiltin = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onCapabilityEdited);
  }

  @override
  void dispose() {
    _controller.removeListener(_onCapabilityEdited);
    _controller.dispose();
    super.dispose();
  }

  /// 用户动手改过字段，就不再是「恢复内置默认」待执行状态。
  void _onCapabilityEdited() {
    if (_restoreBuiltin) _restoreBuiltin = false;
  }

  void _restoreBuiltinTapped() {
    setState(() {
      _controller.seed(widget.builtin);
      // 必须在 seed 之后置位：seed 的 notifyListeners 会走 _onCapabilityEdited。
      _restoreBuiltin = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('声明 ${widget.model} 能力'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: ModelCapabilityFields(
            cs: Theme.of(context).colorScheme,
            controller: _controller,
            builtin: widget.builtin,
            onRestoreBuiltin:
                widget.hasDeclaration ? _restoreBuiltinTapped : null,
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _save,
          child: const Text('保存'),
        ),
      ],
    );
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    if (_restoreBuiltin) {
      Navigator.pop(context, const ModelCapabilityEditResult.restoreBuiltin());
      return;
    }
    final declared = _controller.declared;
    if (declared == null) return;
    Navigator.pop(context, ModelCapabilityEditResult.declared(declared));
  }
}

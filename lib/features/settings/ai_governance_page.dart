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
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class AiGovernancePage extends ConsumerStatefulWidget {
  const AiGovernancePage({super.key});

  @override
  ConsumerState<AiGovernancePage> createState() => _AiGovernancePageState();
}

class _AiGovernancePageState extends ConsumerState<AiGovernancePage> {
  late final DatabaseService _db;
  late final AiGovernanceStore _store;
  late final SearchProviderConfigStore _searchSettings;
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
                    'Provider。DuckDuckGo 仅作为百科即时答案兜底，不等同于完整 Web 搜索。',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          WebSearchSettingsSection(
            store: _searchSettings,
          ),
          const SizedBox(height: 8),
          WebSearchRuntimeSettingsCard(
            initialSettings: _searchSettings.runtimeSettings,
            onSave: _searchSettings.saveRuntimeSettings,
            onClearCache: () => SearchCacheController.clear(_searchSettings),
          ),
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

  Widget _usageCard() {
    final entries = _store.ledgerEntries.reversed.toList(growable: false);
    final byPurpose = aggregateUsage(entries, (entry) => entry.purpose.label);
    final totals = <String, int>{};
    for (final entry in entries) {
      final cost = entry.estimatedCostMicros;
      final currency = entry.currency;
      if (cost != null && currency != null) {
        totals[currency] = (totals[currency] ?? 0) + cost;
      }
    }
    return Card(
      child: Column(
        children: [
          ListTile(
            title: Text(entries.isEmpty
                ? '暂无调用记录'
                : totals.entries
                    .map((item) =>
                        '${item.key} ${MoneyMicros.display(item.value)}')
                    .join(' · ')),
            subtitle: Text('${entries.length} 条明细；价格未知时仅显示 Token'),
            trailing: TextButton(
              onPressed: entries.isEmpty ? null : _clearUsage,
              child: const Text('清除'),
            ),
          ),
          if (byPurpose.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final item in byPurpose.entries)
                    Chip(
                      label: Text(
                        '${item.key} ${item.value.requestCount} 次 · '
                        '${item.value.inputTokens + item.value.outputTokens} Token',
                      ),
                    ),
                ],
              ),
            ),
          for (final entry in entries.take(30))
            ListTile(
              dense: true,
              title: Text(
                '${entry.purpose.label} · ${entry.provider}/${entry.model}',
              ),
              subtitle: Text(
                '${entry.inputTokens} 入 / ${entry.cachedInputTokens} 缓存 / '
                '${entry.outputTokens} 出 · ${entry.exactUsage ? '精确' : '估算'}',
              ),
              trailing: Text(entry.estimatedCostMicros == null
                  ? '价格未知'
                  : '${entry.currency} '
                      '${MoneyMicros.display(entry.estimatedCostMicros!)}'),
            ),
        ],
      ),
    );
  }

  Widget _diagnosticsCard() {
    final items = _store.diagnostics.reversed.toList(growable: false);
    return Card(
      child: Column(
        children: [
          ListTile(
            title: Text('${items.length} 条诊断'),
            subtitle: const Text('不保存 Key、Authorization、提示词或消息正文'),
            trailing: TextButton(
              onPressed: items.isEmpty ? null : _clearDiagnostics,
              child: const Text('清除'),
            ),
          ),
          for (final item in items.take(30))
            ListTile(
              dense: true,
              title: Text('${item.purpose.label} · ${item.status}'),
              subtitle: Text(
                '${item.provider}/${item.model} · ${item.latencyMs}ms · '
                '重试 ${item.retryCount}',
              ),
              trailing: IconButton(
                icon: const Icon(Icons.copy_rounded, size: 18),
                tooltip: '复制脱敏诊断',
                onPressed: () => Clipboard.setData(
                  ClipboardData(text: item.toSafeText()),
                ),
              ),
            ),
        ],
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
    var value = current ?? const CustomModelCapability();
    final contextController =
        TextEditingController(text: value.contextWindow.toString());
    final outputController =
        TextEditingController(text: value.maxOutput.toString());
    final saved = await showDialog<CustomModelCapability>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('声明 $model 能力'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SwitchListTile(
                  title: const Text('流式'),
                  value: value.supportsStreaming,
                  onChanged: (next) =>
                      setDialogState(() => value = CustomModelCapability(
                            supportsStreaming: next,
                            supportsVision: value.supportsVision,
                            supportsTools: value.supportsTools,
                            contextWindow: value.contextWindow,
                            maxOutput: value.maxOutput,
                          )),
                ),
                SwitchListTile(
                  title: const Text('视觉'),
                  value: value.supportsVision,
                  onChanged: (next) =>
                      setDialogState(() => value = CustomModelCapability(
                            supportsStreaming: value.supportsStreaming,
                            supportsVision: next,
                            supportsTools: value.supportsTools,
                            contextWindow: value.contextWindow,
                            maxOutput: value.maxOutput,
                          )),
                ),
                SwitchListTile(
                  title: const Text('工具'),
                  value: value.supportsTools,
                  onChanged: (next) =>
                      setDialogState(() => value = CustomModelCapability(
                            supportsStreaming: value.supportsStreaming,
                            supportsVision: value.supportsVision,
                            supportsTools: next,
                            contextWindow: value.contextWindow,
                            maxOutput: value.maxOutput,
                          )),
                ),
                TextField(
                  controller: contextController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '上下文 Token'),
                ),
                TextField(
                  controller: outputController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '最大输出 Token'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final contextWindow = int.tryParse(contextController.text);
                final maxOutput = int.tryParse(outputController.text);
                if (contextWindow == null ||
                    maxOutput == null ||
                    contextWindow <= 0 ||
                    maxOutput <= 0 ||
                    maxOutput > contextWindow) {
                  return;
                }
                Navigator.pop(
                  dialogContext,
                  CustomModelCapability(
                    supportsStreaming: value.supportsStreaming,
                    supportsVision: value.supportsVision,
                    supportsTools: value.supportsTools,
                    contextWindow: contextWindow,
                    maxOutput: maxOutput,
                  ),
                );
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    contextController.dispose();
    outputController.dispose();
    if (saved == null) return;
    await _store.saveCustomCapability(provider.name, model, saved);
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

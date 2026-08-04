import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/ai_governance/ai_request_guard.dart';
import 'package:chat_group/features/ai_governance/model_capability_registry.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';

abstract class GovernancePersistence {
  BudgetSettings get budgetSettings;
  WebSearchPolicy get globalSearchPolicy;
  WebSearchPolicy? conversationSearchPolicy(String conversationId);
  CustomModelCapability? customCapability(String provider, String model);
  List<UsageLedgerEntry> get ledgerEntries;
  List<AiRequestDiagnostic> get diagnostics;
  List<SearchAuditEntry> get searchAudits;

  Future<void> saveBudgetSettings(BudgetSettings settings);
  Future<void> saveGlobalSearchPolicy(WebSearchPolicy policy);
  Future<void> saveConversationSearchPolicy(
    String conversationId,
    WebSearchPolicy? policy,
  );
  Future<void> saveCustomCapability(
    String provider,
    String model,
    CustomModelCapability capability,
  );
  Future<void> addLedgerEntry(UsageLedgerEntry entry);
  Future<void> addDiagnostic(AiRequestDiagnostic diagnostic);

  Future<void> clearLedger();

  /// 防御性打开 append-only 账本 box（幂等）。网关在 guard.check 前调用，
  /// 避免任何不走 DatabaseService.init() 的调用方因 box 未打开而抛 HiveError。
  Future<void> ensureLedgerBox();
  Future<void> clearDiagnostics();
  Future<void> addSearchAudit(SearchAuditEntry entry);
  Future<void> clearSearchAudits();

  /// 返回共享的 [AiRequestGuard]。同一数据库实例多次调用应返回
  /// 同一个 guard，确保 _reservedMicros 预算预留在整个应用中可见。
  AiRequestGuard get guard;
}

class AiGovernanceStore implements GovernancePersistence {
  static const _budgetKey = 'ai_governance_budget_v1';
  static const _ledgerKey = 'ai_usage_ledger_v1';
  static const _diagnosticsKey = 'ai_request_diagnostics_v1';
  static const _searchPolicyKey = 'web_search_policy_v1';
  static const _searchAuditKey = 'web_search_audit_v1';
  static const _conversationSearchPoliciesKey =
      'conversation_web_search_policies_v1';
  static const _customCapabilitiesKey = 'custom_model_capabilities_v1';
  static const _diagnosticLimit = 200;
  static const _searchAuditLimit = 100;
  static const _detailRetention = Duration(days: 90);

  static final Map<int, AiGovernanceStore> _instances = {};

  /// 为给定的 [DatabaseService] 返回共享的 [AiGovernanceStore] 实例。
  /// 同一数据库实例多次调用返回同一个 store，确保预算预留、账本
  /// 等并发敏感状态在整个应用中被所有消费者共享。
  static AiGovernanceStore forDatabase(DatabaseService db) {
    final identity = Object.hash(db, db.hashCode);
    return _instances.putIfAbsent(identity, () => AiGovernanceStore._(db));
  }

  final DatabaseService db;
  bool _legacyLedgerMigrated = false;
  AiRequestGuard? _guard;

  AiGovernanceStore._(this.db);

  /// 共享的预算 guard：同一 store 实例的所有消费者共享同一个 guard，
  /// 确保 _reservedMicros 预留计数跨网关实例可见。
  @override
  AiRequestGuard get guard {
    _guard ??= AiRequestGuard(
      store: this,
      registry: ModelCapabilityRegistry(),
      clock: DateTime.now,
    );
    return _guard!;
  }

  /// 创建新实例（仅供 [forDatabase] 内部使用）。
  /// 普通代码应通过 [forDatabase] 获取共享实例。
  @Deprecated('Use AiGovernanceStore.forDatabase(db) instead')
  AiGovernanceStore(this.db);

  /// 防御性打开账本 box：若尚未打开（例如调用方未经过 [DatabaseService.init]，
  /// 如单测或某些非标准初始化路径），主动打开，避免 [Hive.box] 抛 HiveError。
  ///
  /// 幂等：box 已打开则直接返回。可在请求入口（网关）或写入路径安全调用。
  @override
  Future<void> ensureLedgerBox() async {
    if (!Hive.isBoxOpen(DatabaseService.aiGovernanceLedgerBoxName)) {
      await Hive.openBox<dynamic>(DatabaseService.aiGovernanceLedgerBoxName);
    }
  }

  /// 打开并返回账本 box（必要时先 [ensureLedgerBox]）。
  Future<Box<dynamic>> _openLedgerBox() async {
    await ensureLedgerBox();
    return Hive.box<dynamic>(DatabaseService.aiGovernanceLedgerBoxName);
  }

  /// 把旧的单值账本（ai_usage_ledger_v1）一次性迁移到 append-only box，
  /// 避免升级后历史明细丢失；之后旧 key 被清理，不再读写。
  void _ensureLegacyLedgerMigration(Box<dynamic> box) {
    if (_legacyLedgerMigrated) return;
    _legacyLedgerMigrated = true;
    final legacy = db.appSettingsBox.get(_ledgerKey);
    if (legacy is List && legacy.isNotEmpty && box.isEmpty) {
      for (final item in legacy.whereType<Map>()) {
        final entry = UsageLedgerEntry.fromMap(item);
        final key =
            '${entry.conversationId}:${entry.timestamp.microsecondsSinceEpoch}:${const Uuid().v4()}';
        box.put(key, entry.toMap());
      }
    }
    if (legacy != null) db.appSettingsBox.delete(_ledgerKey);
  }

  @override
  BudgetSettings get budgetSettings {
    final raw = db.appSettingsBox.get(_budgetKey);
    return raw is Map ? BudgetSettings.fromMap(raw) : const BudgetSettings();
  }

  @override
  WebSearchPolicy get globalSearchPolicy {
    final value = db.appSettingsBox.get(_searchPolicyKey)?.toString();
    return WebSearchPolicy.values.firstWhere(
      (policy) => policy.name == value,
      orElse: () => WebSearchPolicy.off,
    );
  }

  @override
  WebSearchPolicy? conversationSearchPolicy(String conversationId) {
    final raw = db.appSettingsBox.get(_conversationSearchPoliciesKey);
    if (raw is! Map) return null;
    final value = raw[conversationId]?.toString();
    if (value == null) return null;
    for (final policy in WebSearchPolicy.values) {
      if (policy.name == value) return policy;
    }
    return null;
  }

  @override
  CustomModelCapability? customCapability(String provider, String model) {
    final raw = db.appSettingsBox.get(_customCapabilitiesKey);
    if (raw is! Map) return null;
    final value = raw[_modelKey(provider, model)];
    return value is Map ? CustomModelCapability.fromMap(value) : null;
  }

  @override
  List<UsageLedgerEntry> get ledgerEntries {
    // 防御性：若 box 尚未打开（如未走 init 的路径），不抛错，直接返回空列表。
    // 真实环境由 [DatabaseService.init] 预开；写入路径会通过 _openLedgerBox 打开。
    if (!Hive.isBoxOpen(DatabaseService.aiGovernanceLedgerBoxName)) {
      return const [];
    }
    final box = Hive.box<dynamic>(DatabaseService.aiGovernanceLedgerBoxName);
    _ensureLegacyLedgerMigration(box);
    return box.values
        .whereType<Map>()
        .map(UsageLedgerEntry.fromMap)
        .toList(growable: false);
  }

  @override
  List<AiRequestDiagnostic> get diagnostics {
    final raw = db.appSettingsBox.get(_diagnosticsKey);
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map(AiRequestDiagnostic.fromMap)
        .toList(growable: false);
  }

  @override
  List<SearchAuditEntry> get searchAudits {
    final raw = db.appSettingsBox.get(_searchAuditKey);
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map(SearchAuditEntry.fromMap)
        .toList(growable: false);
  }

  @override
  Future<void> saveBudgetSettings(BudgetSettings settings) =>
      db.appSettingsBox.put(_budgetKey, settings.toMap());

  @override
  Future<void> saveGlobalSearchPolicy(WebSearchPolicy policy) =>
      db.appSettingsBox.put(_searchPolicyKey, policy.name);

  @override
  Future<void> saveConversationSearchPolicy(
    String conversationId,
    WebSearchPolicy? policy,
  ) async {
    final raw = db.appSettingsBox.get(_conversationSearchPoliciesKey);
    final values =
        raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
    if (policy == null) {
      values.remove(conversationId);
    } else {
      values[conversationId] = policy.name;
    }
    await db.appSettingsBox.put(_conversationSearchPoliciesKey, values);
  }

  @override
  Future<void> saveCustomCapability(
    String provider,
    String model,
    CustomModelCapability capability,
  ) async {
    final raw = db.appSettingsBox.get(_customCapabilitiesKey);
    final values =
        raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
    values[_modelKey(provider, model)] = capability.toMap();
    await db.appSettingsBox.put(_customCapabilitiesKey, values);
  }

  @override
  Future<void> addLedgerEntry(UsageLedgerEntry entry) async {
    // 防御性打开账本 box（幂等），避免未预开时抛 HiveError。
    final box = await _openLedgerBox();
    _ensureLegacyLedgerMigration(box);
    // append-only：以唯一 key 直接 put，O(1) 写入，不再全量读写整张账本。
    final key =
        '${entry.conversationId}:${entry.timestamp.microsecondsSinceEpoch}:${const Uuid().v4()}';
    await box.put(key, entry.toMap());
    if (entry.characterId.isNotEmpty) {
      await db.recordTokenUsage(
        characterId: entry.characterId,
        groupId: entry.conversationId,
        inputTokens: entry.inputTokens,
        outputTokens: entry.outputTokens,
        cachedTokens: entry.cachedInputTokens,
      );
    }
  }

  @override
  Future<void> addDiagnostic(AiRequestDiagnostic diagnostic) async {
    final values = diagnostics.toList()..add(diagnostic);
    final retained = values.length <= _diagnosticLimit
        ? values
        : values.sublist(values.length - _diagnosticLimit);
    await db.appSettingsBox.put(
      _diagnosticsKey,
      retained.map((item) => item.toMap()).toList(growable: false),
    );
  }

  @override
  Future<void> clearLedger() async {
    // 防御性打开账本 box（幂等），避免未预开时抛 HiveError。
    final box = await _openLedgerBox();
    await box.clear();
    await db.appSettingsBox.delete(_ledgerKey);
    await db.clearTokenUsage();
  }

  @override
  Future<void> clearDiagnostics() =>
      db.appSettingsBox.put(_diagnosticsKey, <dynamic>[]);

  @override
  Future<void> addSearchAudit(SearchAuditEntry entry) async {
    final cutoff = DateTime.now().toUtc().subtract(_detailRetention);
    final values = searchAudits
        .where((item) => item.searchedAt.toUtc().isAfter(cutoff))
        .toList()
      ..add(entry);
    final retained = values.length <= _searchAuditLimit
        ? values
        : values.sublist(values.length - _searchAuditLimit);
    await db.appSettingsBox.put(
      _searchAuditKey,
      retained.map((item) => item.toMap()).toList(growable: false),
    );
  }

  @override
  Future<void> clearSearchAudits() =>
      db.appSettingsBox.put(_searchAuditKey, <dynamic>[]);

  String _modelKey(String provider, String model) =>
      '${provider.trim().toLowerCase()}/${model.trim().toLowerCase()}';
}

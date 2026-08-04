import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/ai_governance/ai_governance_store.dart';
import 'package:chat_group/features/ai_governance/ai_request_guard.dart';
import 'package:chat_group/features/ai_governance/model_capability_registry.dart';

class MemoryGovernanceStore implements GovernancePersistence {
  @override
  BudgetSettings budgetSettings;
  @override
  WebSearchPolicy globalSearchPolicy;
  final Map<String, WebSearchPolicy> conversationPolicies = {};
  final Map<String, CustomModelCapability> customCapabilities = {};
  @override
  final List<UsageLedgerEntry> ledgerEntries = [];
  @override
  final List<AiRequestDiagnostic> diagnostics = [];
  @override
  final List<SearchAuditEntry> searchAudits = [];
  AiRequestGuard? _guard;

  MemoryGovernanceStore({
    this.budgetSettings = const BudgetSettings(),
    this.globalSearchPolicy = WebSearchPolicy.off,
  });

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

  @override
  WebSearchPolicy? conversationSearchPolicy(String conversationId) =>
      conversationPolicies[conversationId];

  @override
  CustomModelCapability? customCapability(String provider, String model) =>
      customCapabilities['$provider/$model'];

  @override
  Future<void> addDiagnostic(AiRequestDiagnostic diagnostic) async {
    diagnostics.add(diagnostic);
  }

  @override
  Future<void> addLedgerEntry(UsageLedgerEntry entry) async {
    ledgerEntries.add(entry);
  }

  @override
  Future<void> ensureLedgerBox() async {}

  @override
  Future<void> addSearchAudit(SearchAuditEntry entry) async {
    searchAudits.add(entry);
  }

  @override
  Future<void> clearDiagnostics() async => diagnostics.clear();

  @override
  Future<void> clearLedger() async => ledgerEntries.clear();

  @override
  Future<void> clearSearchAudits() async => searchAudits.clear();

  @override
  Future<void> saveBudgetSettings(BudgetSettings settings) async {
    budgetSettings = settings;
  }

  @override
  Future<void> saveConversationSearchPolicy(
    String conversationId,
    WebSearchPolicy? policy,
  ) async {
    if (policy == null) {
      conversationPolicies.remove(conversationId);
    } else {
      conversationPolicies[conversationId] = policy;
    }
  }

  @override
  Future<void> saveCustomCapability(
    String provider,
    String model,
    CustomModelCapability capability,
  ) async {
    customCapabilities['$provider/$model'] = capability;
  }

  @override
  Future<void> saveGlobalSearchPolicy(WebSearchPolicy policy) async {
    globalSearchPolicy = policy;
  }
}

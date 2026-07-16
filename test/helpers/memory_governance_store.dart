import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/ai_governance/ai_governance_store.dart';

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

  MemoryGovernanceStore({
    this.budgetSettings = const BudgetSettings(),
    this.globalSearchPolicy = WebSearchPolicy.off,
  });

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

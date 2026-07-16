import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/ai_governance/search_coordinator.dart';
import 'package:chat_group/services/web_search_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/memory_governance_store.dart';

class FakeWebSearchService extends WebSearchService {
  int searchCount = 0;

  @override
  Future<WebSearchSnapshot> search(String query) async {
    searchCount++;
    return WebSearchSnapshot(
      query: query,
      searchedAt: DateTime(2026, 7, 16, 12),
      results: const [
        WebSearchResult(
          title: 'source',
          snippet: 'result',
          url: 'https://example.com/source',
        ),
      ],
    );
  }
}

void main() {
  test('关闭策略即使命中触发词也产生零搜索请求', () async {
    final store = MemoryGovernanceStore();
    final service = FakeWebSearchService();
    final states = <SearchRunStatus>[];
    final coordinator = SearchCoordinator(store: store, service: service);

    final result = await coordinator.searchIfAllowed(
      text: '帮我查今天的最新价格',
      conversationId: 'group-1',
      requestConsent: (_) async => true,
      onStatus: (state) => states.add(state.status),
    );

    expect(result, isNull);
    expect(service.searchCount, 0);
    expect(states, [SearchRunStatus.disabled]);
    expect(store.searchAudits.single.status, 'disabled');
  });

  test('询问策略未获本次同意时产生零搜索请求', () async {
    final store = MemoryGovernanceStore(
      globalSearchPolicy: WebSearchPolicy.ask,
    );
    final service = FakeWebSearchService();
    final coordinator = SearchCoordinator(store: store, service: service);

    final result = await coordinator.searchIfAllowed(
      text: '今天上海天气',
      conversationId: 'group-1',
      requestConsent: (_) async => false,
    );

    expect(result, isNull);
    expect(service.searchCount, 0);
    expect(store.searchAudits.single.status, 'denied');
  });

  test('会话自动策略覆盖全局关闭并记录来源', () async {
    final store = MemoryGovernanceStore();
    store.conversationPolicies['group-1'] = WebSearchPolicy.auto;
    final service = FakeWebSearchService();
    final coordinator = SearchCoordinator(store: store, service: service);

    final result = await coordinator.searchIfAllowed(
      text: '今天上海天气',
      conversationId: 'group-1',
      requestConsent: (_) async => false,
    );

    expect(result?.hasResults, isTrue);
    expect(service.searchCount, 1);
    expect(store.searchAudits.single.sources, ['https://example.com/source']);
  });
}

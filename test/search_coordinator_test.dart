import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/ai_governance/search_coordinator.dart';
import 'package:chat_group/features/web_search/models/search_failure.dart';
import 'package:chat_group/features/web_search/models/search_models.dart';
import 'package:chat_group/features/web_search/providers/search_provider.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/memory_governance_store.dart';

class FakeWebSearchProvider implements SearchProvider {
  int searchCount = 0;

  @override
  SearchProviderKind get kind => SearchProviderKind.brave;

  @override
  Future<SearchProviderResponse> search(
    SearchRequest request, {
    required String? credential,
    CancelToken? cancelToken,
  }) async {
    searchCount++;
    return SearchProviderResponse(
      items: [
        SearchProviderItem(
          title: 'source',
          snippet: 'result',
          url: Uri.parse('https://example.com/source'),
        ),
      ],
    );
  }

  @override
  Future<SearchHealthResult> testConnection({
    required String? credential,
    required String probeQuery,
  }) async =>
      const SearchHealthResult(isHealthy: true);
}

class DiagnosticFakeWebSearchProvider implements SearchProvider {
  @override
  SearchProviderKind get kind => SearchProviderKind.brave;

  @override
  Future<SearchProviderResponse> search(
    SearchRequest request, {
    required String? credential,
    CancelToken? cancelToken,
  }) async =>
      SearchProviderResponse(
        items: [],
        statusCode: 429,
        failure: const SearchFailure(
          type: SearchFailureType.rateLimited,
          safeMessage: 'safe',
          statusCode: 429,
          retryable: true,
        ),
      );

  @override
  Future<SearchHealthResult> testConnection({
    required String? credential,
    required String probeQuery,
  }) async =>
      const SearchHealthResult(isHealthy: true);
}

void main() {
  test('empty routes produce an explicit configuration failure', () async {
    final store = MemoryGovernanceStore(
      globalSearchPolicy: WebSearchPolicy.auto,
    );
    final states = <SearchRunStatus>[];
    final coordinator = SearchCoordinator(store: store, routes: const []);

    final result = await coordinator.searchIfAllowed(
      text: '今天上海天气',
      conversationId: 'group-1',
      requestConsent: (_) async => true,
      onStatus: (state) => states.add(state.status),
    );

    expect(result, isNotNull);
    expect(result!.failure?.type, SearchFailureType.invalidConfiguration);
    expect(states, contains(SearchRunStatus.failed));
    expect(store.searchAudits.single.status, 'failed');
    expect(store.searchAudits.single.provider, 'none');
  });

  test('empty routes in ask mode fail configuration without fake consent',
      () async {
    final store = MemoryGovernanceStore(
      globalSearchPolicy: WebSearchPolicy.ask,
    );
    final coordinator = SearchCoordinator(store: store, routes: const []);

    final result = await coordinator.searchIfAllowed(
      text: '查找 Flutter 最新版本',
      conversationId: 'group-1',
      requestConsent: (_) async => fail('no Provider can receive this query'),
    );

    expect(result?.failure?.type, SearchFailureType.invalidConfiguration);
    expect(store.searchAudits.single.status, 'failed');
  });

  test('关闭策略即使命中触发词也产生零搜索请求', () async {
    final store = MemoryGovernanceStore();
    final service = FakeWebSearchProvider();
    final states = <SearchRunStatus>[];
    final coordinator = SearchCoordinator(
      store: store,
      routes: [SearchProviderRoute(provider: service)],
    );

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
    final service = FakeWebSearchProvider();
    final coordinator = SearchCoordinator(
      store: store,
      routes: [SearchProviderRoute(provider: service)],
    );

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
    final service = FakeWebSearchProvider();
    final coordinator = SearchCoordinator(
      store: store,
      routes: [SearchProviderRoute(provider: service)],
    );

    final result = await coordinator.searchIfAllowed(
      text: '今天上海天气',
      conversationId: 'group-1',
      requestConsent: (_) async => false,
    );

    expect(result?.hasResults, isTrue);
    expect(service.searchCount, 1);
    expect(store.searchAudits.single.sources, ['https://example.com/source']);
  });

  test('把失败快照诊断字段写入搜索审计', () async {
    final store =
        MemoryGovernanceStore(globalSearchPolicy: WebSearchPolicy.auto);
    final coordinator = SearchCoordinator(
      store: store,
      routes: [
        SearchProviderRoute(provider: DiagnosticFakeWebSearchProvider()),
      ],
      sleep: (_) async {},
    );

    final result = await coordinator.searchIfAllowed(
      text: '今天上海天气',
      conversationId: 'group-1',
      requestConsent: (_) async => true,
    );

    expect(result, isNotNull);
    final audit = store.searchAudits.single;
    expect(audit.requestId, isNotEmpty);
    expect(audit.provider, 'brave');
    expect(audit.failureType, 'rateLimited');
    expect(audit.statusCode, 429);
    expect(audit.latencyMs, greaterThanOrEqualTo(0));
    expect(audit.retryCount, 2);
    expect(audit.fromCache, isFalse);
    expect(audit.sourceCount, 0);
  });
}

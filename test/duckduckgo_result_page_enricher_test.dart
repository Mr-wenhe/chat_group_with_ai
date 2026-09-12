import 'package:chat_group/features/web_search/application/search_provider_chain.dart';
import 'package:chat_group/features/web_search/application/search_provider_route.dart';
import 'package:chat_group/features/web_search/application/search_retry_policy.dart';
import 'package:chat_group/features/web_search/models/search_models.dart';
import 'package:chat_group/features/web_search/providers/duckduckgo_result_page_enricher.dart';
import 'package:chat_group/features/web_search/providers/search_provider.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('enriches exactly the first two public result pages', () async {
    final visited = <Uri>[];
    final enricher = DuckDuckGoResultPageEnricher(
      isRelease: true,
      pageLoader: (url, {cancelToken}) async {
        visited.add(url);
        return '<html><head><script>ignore()</script></head><body>'
            '正文 ${url.host} 的页面内容</body></html>';
      },
    );
    final items = [
      _item('one.example'),
      _item('two.example'),
      _item('three.example'),
    ];

    final result = await enricher.enrich(items);

    expect(visited, [items[0].url, items[1].url]);
    expect(result[0].snippet, contains('网页正文：正文 one.example'));
    expect(result[1].snippet, contains('网页正文：正文 two.example'));
    expect(result[2].snippet, items[2].snippet);
  });

  test('the provider chain feeds enriched DuckDuckGo evidence into snapshots',
      () async {
    final enricher = DuckDuckGoResultPageEnricher(
      pageLoader: (url, {cancelToken}) async =>
          '<html><body>页面事实：${url.host}</body></html>',
    );
    final chain = SearchProviderChain(
      routes: [SearchProviderRoute(provider: _DuckDuckGoStub())],
      retryPolicy: const SearchRetryPolicy(maxRetries: 0),
      duckDuckGoPageEnricher: enricher,
    );

    final snapshot = await chain.execute(
      request: SearchRequest(query: '测试'),
      cancelToken: null,
      onStatus: null,
    );

    expect(snapshot.results, isNotEmpty);
    expect(snapshot.results.first.snippet, contains('页面事实：one.example'));
  });
}

SearchProviderItem _item(String host) => SearchProviderItem(
      title: host,
      snippet: '搜索摘要',
      url: Uri.parse('https://$host/article'),
    );

class _DuckDuckGoStub implements SearchProvider {
  @override
  SearchProviderKind get kind => SearchProviderKind.duckDuckGoInstantAnswer;

  @override
  Future<SearchProviderResponse> search(
    SearchRequest request, {
    required String? credential,
    CancelToken? cancelToken,
  }) async {
    return SearchProviderResponse(
      items: [_item('one.example'), _item('two.example')],
    );
  }

  @override
  Future<SearchHealthResult> testConnection({
    required String? credential,
    required String probeQuery,
  }) async =>
      const SearchHealthResult(isHealthy: true);
}

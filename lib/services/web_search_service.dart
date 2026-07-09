import 'package:dio/dio.dart';

class WebSearchResult {
  final String title;
  final String snippet;
  final String url;

  const WebSearchResult({
    required this.title,
    required this.snippet,
    required this.url,
  });
}

class WebSearchSnapshot {
  final String query;
  final DateTime searchedAt;
  final List<WebSearchResult> results;
  final String? error;

  const WebSearchSnapshot({
    required this.query,
    required this.searchedAt,
    required this.results,
    this.error,
  });

  bool get hasResults => results.isNotEmpty;

  String toPromptContext() {
    final time = searchedAt.toLocal().toIso8601String();
    if (error != null && results.isEmpty) {
      return '【联网搜索】查询 "$query" 失败：$error。'
          '你必须明确说明没有可靠联网结果，不要编造。搜索时间：$time。';
    }
    if (results.isEmpty) {
      return '【联网搜索】查询 "$query" 没有找到可用结果。'
          '你必须说明不确定，不要编造。搜索时间：$time。';
    }
    final lines = results.take(5).map((result) {
      final snippet = result.snippet.trim();
      final source = result.url.trim().isEmpty ? '无链接' : result.url.trim();
      return '- ${result.title}: $snippet 来源：$source';
    }).join('\n');
    return '【联网搜索】以下资料来自实时搜索，搜索时间：$time，查询：$query。\n'
        '$lines\n'
        '回答必须基于这些资料；如果资料不足，明确说“不确定/资料不足”，不要补编细节。';
  }
}

class WebSearchService {
  WebSearchService({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 12),
            ));

  final Dio _dio;

  static const _currentInfoTriggers = [
    '联网',
    '搜索',
    '查一下',
    '查查',
    '搜一下',
    '最新',
    '最近',
    '今天',
    '现在',
    '当前',
    '新闻',
    '价格',
    '汇率',
    '天气',
    '政策',
    '法规',
    '版本',
    '发布',
    'CEO',
    'ceo',
    '总统',
    '主席',
    '市长',
    '几点',
    '日期',
    '时间',
  ];

  bool shouldSearch(String? text) {
    final value = text?.trim();
    if (value == null || value.isEmpty) return false;
    if (_currentInfoTriggers.any(value.contains)) return true;
    final lower = value.toLowerCase();
    return lower.contains('latest') ||
        lower.contains('current') ||
        lower.contains('today') ||
        lower.contains('now') ||
        lower.contains('search') ||
        lower.contains('web');
  }

  Future<WebSearchSnapshot?> searchIfNeeded(String? text) async {
    final query = text?.trim();
    if (query == null || query.isEmpty || !shouldSearch(query)) return null;
    return search(query);
  }

  Future<WebSearchSnapshot> search(String query) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        'https://api.duckduckgo.com/',
        queryParameters: {
          'q': query,
          'format': 'json',
          'no_html': '1',
          'skip_disambig': '1',
          'no_redirect': '1',
        },
      );
      final data = response.data ?? const <String, dynamic>{};
      return WebSearchSnapshot(
        query: query,
        searchedAt: DateTime.now(),
        results: _parseResults(data),
      );
    } on DioException catch (e) {
      return WebSearchSnapshot(
        query: query,
        searchedAt: DateTime.now(),
        results: const [],
        error: e.message ?? e.type.name,
      );
    } catch (e) {
      return WebSearchSnapshot(
        query: query,
        searchedAt: DateTime.now(),
        results: const [],
        error: e.toString(),
      );
    }
  }

  List<WebSearchResult> _parseResults(Map<String, dynamic> data) {
    final results = <WebSearchResult>[];
    void add(String? title, String? snippet, String? url) {
      final cleanTitle = (title ?? '').trim();
      final cleanSnippet = (snippet ?? '').trim();
      if (cleanTitle.isEmpty && cleanSnippet.isEmpty) return;
      final result = WebSearchResult(
        title: cleanTitle.isEmpty ? '搜索结果' : cleanTitle,
        snippet: cleanSnippet,
        url: (url ?? '').trim(),
      );
      if (results.any((existing) =>
          existing.title == result.title && existing.url == result.url)) {
        return;
      }
      results.add(result);
    }

    add(
      data['Heading'] as String?,
      data['AbstractText'] as String?,
      data['AbstractURL'] as String?,
    );

    void parseTopic(dynamic topic) {
      if (topic is! Map) return;
      if (topic['Topics'] is List) {
        for (final nested in topic['Topics'] as List) {
          parseTopic(nested);
        }
        return;
      }
      final text = topic['Text'] as String?;
      final firstDash = text?.indexOf(' - ') ?? -1;
      final title = firstDash > 0 ? text!.substring(0, firstDash) : text;
      final snippet = firstDash > 0 ? text!.substring(firstDash + 3) : text;
      add(title, snippet, topic['FirstURL'] as String?);
    }

    final topics = data['RelatedTopics'];
    if (topics is List) {
      for (final topic in topics) {
        parseTopic(topic);
        if (results.length >= 5) break;
      }
    }
    return results;
  }
}

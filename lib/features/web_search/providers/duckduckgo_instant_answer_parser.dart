import '../models/search_models.dart';
import 'search_provider.dart';

/// Parses the structured branches returned by DuckDuckGo Instant Answer.
class DuckDuckGoInstantAnswerParsed {
  final List<SearchProviderItem> items;
  final bool moreResultsAvailable;

  const DuckDuckGoInstantAnswerParsed({
    required this.items,
    required this.moreResultsAvailable,
  });
}

class DuckDuckGoInstantAnswerParser {
  DuckDuckGoInstantAnswerParser({
    required this.maxResults,
  });

  final int maxResults;
  final List<SearchProviderItem> _items = [];
  final Set<String> _seenUrls = {};
  bool _moreResultsAvailable = false;

  DuckDuckGoInstantAnswerParsed parse(Map<String, dynamic> data) {
    _parseAbstract(data);
    _parseAnswer(data);
    _parseDefinition(data);
    _parseResults(data['Results']);
    _parseRelatedTopics(data['RelatedTopics']);
    return DuckDuckGoInstantAnswerParsed(
      items: List.unmodifiable(_items),
      moreResultsAvailable: _moreResultsAvailable,
    );
  }

  void _parseAbstract(Map<String, dynamic> data) {
    _addItem(
      title: _stringValue(data['Heading']) ?? '',
      snippet: _stringValue(data['AbstractText']) ?? '',
      rawUrl: _stringValue(data['AbstractURL']),
      sourceKey: 'abstract',
      useFallbackWhenUrlMissing: true,
    );
  }

  void _parseAnswer(Map<String, dynamic> data) {
    final answer = _stringValue(data['Answer']);
    if (answer == null || answer.trim().isEmpty) return;
    _addItem(
      title: _stringValue(data['AnswerType']) ?? '直接答案',
      snippet: answer,
      rawUrl: null,
      sourceKey: 'answer',
      useFallbackWhenUrlMissing: true,
    );
  }

  void _parseDefinition(Map<String, dynamic> data) {
    final definition = _stringValue(data['Definition']);
    if (definition == null || definition.trim().isEmpty) return;
    _addItem(
      title: _stringValue(data['DefinitionSource']) ?? '定义',
      snippet: definition,
      rawUrl: _stringValue(data['DefinitionURL']),
      sourceKey: 'definition',
      useFallbackWhenUrlMissing: true,
    );
  }

  void _parseResults(dynamic rawResults) {
    if (rawResults is! List) return;
    for (var index = 0; index < rawResults.length; index++) {
      final result = rawResults[index];
      if (result is! Map) continue;
      final text =
          _stringValue(result['Text']) ?? _stringValue(result['Result']) ?? '';
      final parts = _splitTopicText(text);
      _addItem(
        title: parts.$1,
        snippet: parts.$2,
        rawUrl: _stringValue(result['FirstURL']),
        sourceKey: 'result-$index',
      );
    }
  }

  void _parseRelatedTopics(dynamic rawTopics) {
    if (rawTopics is! List) return;
    for (var index = 0; index < rawTopics.length; index++) {
      _parseTopic(rawTopics[index], path: 'related-$index');
    }
  }

  void _parseTopic(dynamic rawTopic, {required String path}) {
    if (rawTopic is! Map) return;
    final nested = rawTopic['Topics'];
    if (nested is List) {
      for (var index = 0; index < nested.length; index++) {
        _parseTopic(nested[index], path: '$path-$index');
      }
    }

    final text = _stringValue(rawTopic['Text']) ??
        _stringValue(rawTopic['Result']) ??
        '';
    final parts = _splitTopicText(text);
    _addItem(
      title: parts.$1,
      snippet: parts.$2,
      rawUrl: _stringValue(rawTopic['FirstURL']),
      sourceKey: path,
    );
  }

  void _addItem({
    required String title,
    required String snippet,
    required String? rawUrl,
    required String sourceKey,
    bool useFallbackWhenUrlMissing = false,
  }) {
    final cleanTitle = _plainText(title);
    final cleanSnippet = _plainText(snippet);
    if (cleanTitle.isEmpty && cleanSnippet.isEmpty) return;
    if (_items.length >= maxResults) {
      _moreResultsAvailable = true;
      return;
    }

    final url = _resolveUrl(
      rawUrl,
      sourceKey: sourceKey,
      useFallbackWhenMissing: useFallbackWhenUrlMissing,
    );
    if (url == null) return;
    if (!_seenUrls.add(_canonicalUrl(url))) return;
    if (_items.length >= maxResults) {
      _moreResultsAvailable = true;
      return;
    }

    _items.add(
      SearchProviderItem(
        title: cleanTitle,
        snippet: cleanSnippet,
        url: url,
      ),
    );
  }

  Uri? _resolveUrl(
    String? rawUrl, {
    required String sourceKey,
    required bool useFallbackWhenMissing,
  }) {
    final normalized = rawUrl?.trim() ?? '';
    if (normalized.isEmpty) {
      return useFallbackWhenMissing ? _fallbackUrl(sourceKey) : null;
    }
    final parsed = Uri.tryParse(normalized);
    if (parsed == null) return null;
    try {
      return validateSearchUrl(parsed);
    } on ArgumentError {
      return null;
    }
  }

  Uri _fallbackUrl(String sourceKey) => Uri.https(
        'duckduckgo.com',
        '/',
        {'ia': sourceKey},
      );

  String? _stringValue(dynamic value) => value is String ? value : null;

  String _plainText(String value) => value
      .replaceAll(RegExp(r'<[^>]*>'), ' ')
      .replaceAll(RegExp(r'[\u0000-\u001F\u007F]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  (String, String) _splitTopicText(String value) {
    final text = _plainText(value);
    final dash = text.indexOf(' - ');
    if (dash <= 0) return (text, text);
    return (text.substring(0, dash).trim(), text.substring(dash + 3).trim());
  }

  String _canonicalUrl(Uri url) => url
      .replace(
        scheme: url.scheme.toLowerCase(),
        host: url.host.toLowerCase(),
        path: url.path == '/' ? '' : url.path,
        fragment: '',
      )
      .toString();
}

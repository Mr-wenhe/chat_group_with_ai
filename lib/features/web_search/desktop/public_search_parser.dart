import 'dart:convert';
import 'package:html/parser.dart' as html;
import '../security/search_endpoint_validator.dart';
import '../models/search_models.dart'
    show validateSearchUrl, tryValidateSearchUrl, sanitizeSearchText;

List<Map<String, String>> parsePublicSearchResults(String body,
    {bool bing = false}) {
  if (body.contains('anomaly.js') || body.contains('challenge-form')) {
    throw StateError('搜索来源要求验证码。');
  }
  final doc = html.parse(body);
  final nodes = bing
      ? doc.querySelectorAll('li.b_algo')
      : doc.querySelectorAll('.result');
  final result = <Map<String, String>>[];
  final seen = <String>{};
  for (final node in nodes) {
    final anchor = node.querySelector(bing ? 'h2 a' : 'a.result__a');
    var link = anchor?.attributes['href'];
    if (anchor == null || link == null) continue;
    if (link.startsWith('//')) link = 'https:$link';
    var uri = Uri.tryParse(link);
    if (uri == null) continue;
    if (uri.queryParameters['uddg'] != null) {
      uri = Uri.tryParse(uri.queryParameters['uddg']!);
    }
    if ((uri?.host == 'bing.com' || uri?.host == 'www.bing.com') &&
        uri?.path == '/ck/a') {
      var encoded = uri?.queryParameters['u'] ?? '';
      if (encoded.startsWith('a1')) {
        try {
          uri = Uri.tryParse(utf8.decode(
              base64Url.decode(base64Url.normalize(encoded.substring(2)))));
        } catch (_) {
          continue;
        }
      }
    }
    if (uri == null) continue;
    try {
      uri =
          SearchEndpointValidator.requireValid(uri.toString(), isRelease: true);
      // Evidence has a stricter secret check; reject an item before it can abort the whole search.
      uri = validateSearchUrl(uri);
      if (uri.hasPort && uri.port != 443) continue;
    } catch (_) {
      continue;
    }
    if (!seen.add(uri.toString())) continue;
    final snippet =
        node.querySelector(bing ? '.b_caption p' : '.result__snippet')?.text ??
            '';
    result.add({
      'source_id': 's${result.length + 1}',
      'title': anchor.text.trim(),
      'url': uri.toString(),
      'snippet': snippet.trim()
    });
    if (result.length == 5) break;
  }
  return result;
}

/// Parse the official board's ranked data, excluding its separate pinned story.
List<Map<String, dynamic>> parseBaiduRealtimeTopTen(String body) {
  final ranked = <int, Map<String, dynamic>>{};
  for (final block in RegExp(r'<!--s-data:([\s\S]*?)-->').allMatches(body)) {
    try {
      final root = jsonDecode(block.group(1)!);
      final data = root is Map ? root['data'] : null;
      final cards = data is Map ? data['cards'] : null;
      if (cards is! List) continue;
      for (final card in cards.whereType<Map>()) {
        final content = card['content'];
        if (card['component'] != 'hotList' || content is! List) continue;
        for (final item in content.whereType<Map>()) {
          final index = item['index'];
          if (item['isTop'] == true ||
              index is! int ||
              index < 0 ||
              index >= 10) {
            continue;
          }
          final url = tryValidateSearchUrl(
              Uri.tryParse((item['rawUrl'] ?? item['url'] ?? '').toString()));
          final title = sanitizeSearchText(
              (item['word'] ?? item['query'] ?? '').toString(),
              maxLength: 300,
              redactSecrets: true,
              redactOpaqueTokens: true);
          if (url == null || url.hasPort && url.port != 443 || title.isEmpty) {
            continue;
          }
          ranked.putIfAbsent(
              index + 1,
              () => {
                    'rank': index + 1,
                    'title': title,
                    'url': url.toString(),
                    if (RegExp(r'^\d{1,16}$').hasMatch('${item['hotScore']}'))
                      'hotScore': '${item['hotScore']}',
                  });
        }
      }
    } on FormatException {
      continue;
    }
  }
  final positions = ranked.keys.toList()..sort();
  return [for (final position in positions) ranked[position]!];
}

import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:chat_group/features/web_search/desktop/public_search_parser.dart';

void main() {
  test('ranking rejects invalid sources and preserves actual gaps', () {
    final page = '<!--s-data:not-json--><!--s-data:${jsonEncode({
          'data': {
            'cards': [
              {
                'component': 'hotList',
                'content': [
                  {
                    'index': 0,
                    'word': 'Private',
                    'rawUrl': 'https://127.0.0.1/'
                  },
                  {
                    'index': 1,
                    'word': 'Port',
                    'rawUrl': 'https://example.com:8443/'
                  },
                  {
                    'index': 2,
                    'word': 'Safe',
                    'rawUrl': 'https://example.com/topic'
                  },
                  {
                    'index': 2,
                    'word': 'Duplicate',
                    'rawUrl': 'https://example.com/other'
                  },
                  {
                    'index': 10,
                    'word': 'Outside top ten',
                    'rawUrl': 'https://example.com/eleven'
                  },
                ]
              }
            ]
          }
        })}-->';
    final items = parseBaiduRealtimeTopTen(page);
    expect(items, hasLength(1));
    expect(items.single['rank'], 3);
    expect(items.single['title'], 'Safe');
    expect(items.single['url'], 'https://example.com/topic');
  });
  for (final bing in [false, true]) {
    test('search skips URLs rejected by evidence validation bing=$bing', () {
      const rejected =
          'https://travel.state.gov/content/travel/en/us-visas/visa-information-resources/visa-denials.html';
      final results = parsePublicSearchResults(
          bing
              ? '<li class="b_algo"><h2><a href="$rejected">Rejected</a></h2></li>'
                  '<li class="b_algo"><h2><a href="https://www.stepfun.com/step-5-preview">Official</a></h2></li>'
              : '<div class="result"><a class="result__a" href="$rejected">Rejected</a></div>'
                  '<div class="result"><a class="result__a" href="https://www.stepfun.com/step-5-preview">Official</a></div>',
          bing: bing);
      expect(results.map((item) => item['url']),
          ['https://www.stepfun.com/step-5-preview']);
    });
  }
  test('DDG keeps real public links and removes duplicate and unsafe links',
      () {
    final results = parsePublicSearchResults('''
<div class="result"><a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Farticle">Article</a><span class="result__snippet">Evidence</span></div>
<div class="result"><a class="result__a" href="https://example.com/article">Duplicate</a></div>
<div class="result"><a class="result__a" href="https://127.0.0.1/">Local</a></div>
<div class="result"><a class="result__a" href="https://example.com:8443/">Port</a></div>
''');
    expect(results, hasLength(1));
    expect(results.single['url'], 'https://example.com/article');
    expect(results.single['snippet'], 'Evidence');
  });
  test('Bing redirect is decoded to its actual public source', () {
    final encoded = base64Url.encode(utf8.encode('https://example.com/source'));
    final results = parsePublicSearchResults(
        '<li class="b_algo"><h2><a href="https://www.bing.com/ck/a?u=a1$encoded">Source</a></h2><div class="b_caption"><p>Text</p></div></li>',
        bing: true);
    expect(results.single['url'], 'https://example.com/source');
  });
  test('challenge is an explicit failure, not an empty successful search', () {
    expect(() => parsePublicSearchResults('<form id="challenge-form"></form>'),
        throwsStateError);
  });
}

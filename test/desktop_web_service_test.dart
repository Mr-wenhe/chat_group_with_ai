import 'dart:convert';
import 'dart:ui';
import 'package:crypto/crypto.dart';
import 'package:archive/archive.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chat_group/features/web_search/desktop/desktop_web_service.dart';
import 'package:chat_group/features/web_search/desktop/web_worker_client.dart';

class TextWorker extends WebWorkerClient {
  TextWorker(String text, {this.contentType = 'text/plain'})
      : bytes = utf8.encode(text),
        super(executable: '/unused', entryPoint: '/unused');
  TextWorker.bytes(this.bytes, {required this.contentType})
      : super(executable: '/unused', entryPoint: '/unused');
  final List<int> bytes;
  final String contentType;
  @override
  Stream<Map<String, dynamic>> request(Map<String, dynamic> arguments) async* {
    yield {
      'status': 'headers',
      'url': arguments['url'],
      'contentType': contentType
    };
    yield {'status': 'chunk', 'data': base64Encode(bytes)};
    yield {'status': 'done', 'byteLength': bytes.length};
  }
}

class HostPageWorker extends WebWorkerClient {
  HostPageWorker(this.pages)
      : super(executable: '/unused', entryPoint: '/unused');

  final Map<String, String> pages;
  final requestedHosts = <String>[];

  @override
  Stream<Map<String, dynamic>> request(Map<String, dynamic> arguments) async* {
    final url = Uri.parse(arguments['url'] as String);
    requestedHosts.add(url.host);
    final bytes = utf8.encode(pages[url.host]!);
    yield {
      'status': 'headers',
      'url': url.toString(),
      'contentType': 'text/html',
    };
    yield {'status': 'chunk', 'data': base64Encode(bytes)};
    yield {'status': 'done', 'byteLength': bytes.length};
  }
}

void main() {
  test('Baidu discovery identifies an entry, not fetched ranking data',
      () async {
    final service = DesktopWebService(TextWorker('not a search response'));
    final result = await service.search('site:top.baidu.com 实时热搜');
    expect(result.single['url'], 'https://top.baidu.com/board?tab=realtime');
    expect(result.single['discovery'], 'known_official_entry');
    expect(result.single['snippet'], contains('web.read'));
    expect(service.snapshot().results.single.provider, '官方公开入口');
  });
  test('official live ranking retains ten positions and their real links',
      () async {
    final payload = jsonEncode({
      'data': {
        'cards': [
          {
            'component': 'hotList',
            'content': [
              {
                'isTop': true,
                'index': 0,
                'word': 'Pinned',
                'rawUrl': 'https://www.baidu.com/s?wd=pinned'
              },
              for (var i = 0; i < 10; i++)
                {
                  'index': i,
                  'word': 'Topic ${i + 1}',
                  'hotScore': '${1000 - i}',
                  'rawUrl': 'https://www.baidu.com/s?wd=topic${i + 1}'
                },
            ]
          }
        ]
      }
    });
    final page =
        '<html><body>${List.filled(30, '<a href="https://example.com/nav">Navigation</a>').join()}<!--s-data:$payload--></body></html>';
    final service =
        DesktopWebService(TextWorker(page, contentType: 'text/html'));
    final result = await service.read(
        service.registerSource('https://top.baidu.com/board?tab=realtime'));
    final ranking = result['ranking'] as Map?;
    expect(ranking, isNotNull);
    final items = ranking!['items'] as List;
    expect(items, hasLength(10));
    expect(items.map((item) => item['rank']), List.generate(10, (i) => i + 1));
    expect(items.last['url'], 'https://www.baidu.com/s?wd=topic10');
    expect(service.source(items.last['source_id'] as String).toString(),
        items.last['url']);
    expect(items.any((item) => item['title'] == 'Pinned'), isFalse);
    expect(DateTime.tryParse(ranking['observedAt'] as String), isNotNull);
    final defaultBoard = await service
        .read(service.registerSource('https://top.baidu.com/board'));
    expect((defaultBoard['ranking'] as Map)['items'], hasLength(10));
    final other = DesktopWebService(TextWorker(page, contentType: 'text/html'));
    final unrelated = await other
        .read(other.registerSource('https://example.com/board?tab=realtime'));
    expect(unrelated['ranking'], isNull);
  });
  test('one rejected search URL does not discard valid evidence', () async {
    final service = DesktopWebService(TextWorker('''
<div class="result"><a class="result__a" href="https://travel.state.gov/content/travel/en/us-visas/visa-information-resources/visa-denials.html">Rejected</a></div>
<div class="result"><a class="result__a" href="https://www.stepfun.com/step-5-preview">Official</a></div>
''', contentType: 'text/html'));
    final results = await service.search('Step 5 Preview official page');
    expect(results.single['url'], 'https://www.stepfun.com/step-5-preview');
    expect(service.snapshot().results.single.url.toString(),
        results.single['url']);
    expect(service.exportSources(),
        {'s1': 'https://www.stepfun.com/step-5-preview'});
  });
  test('site-restricted search rejects mismatches and tries the next source',
      () async {
    final worker = HostPageWorker({
      'html.duckduckgo.com': '''
<div class="result"><a class="result__a" href="https://raw.githubusercontent.com/flutter/other/master/README.md">Wrong repository</a></div>
''',
      'www.bing.com': '''
<li class="b_algo"><h2><a href="https://raw.githubusercontent.com/flutter/flutter/master/README.md">Flutter README</a></h2><div class="b_caption"><p>Official raw README</p></div></li>
''',
    });
    final service = DesktopWebService(worker);

    final results = await service
        .search('site:raw.githubusercontent.com/flutter/flutter README.md');

    expect(worker.requestedHosts, ['html.duckduckgo.com', 'www.bing.com']);
    expect(results.single['url'],
        'https://raw.githubusercontent.com/flutter/flutter/master/README.md');
    expect(results.single['provider'], 'Bing HTML');
  });
  test('site-restricted search fails closed when both sources ignore the site',
      () async {
    const unrelated =
        '<div class="result"><a class="result__a" href="https://example.com/readme">Unrelated</a></div>';
    final worker = HostPageWorker({
      'html.duckduckgo.com': unrelated,
      'www.bing.com': unrelated,
    });
    final service = DesktopWebService(worker);

    await expectLater(
        service
            .search('site:raw.githubusercontent.com/flutter/flutter README.md'),
        throwsStateError);

    expect(worker.requestedHosts, ['html.duckduckgo.com', 'www.bing.com']);
    expect(service.snapshot().results, isEmpty);
  });
  test('autonomous snapshots retain the executed query and correlation id',
      () async {
    const query = 'site:github.com/flutter/flutter Flutter README';
    final service = DesktopWebService(TextWorker('''
<div class="result">
  <a class="result__a" href="https://github.com/flutter/flutter">Flutter</a>
  <div class="result__snippet">Official Flutter repository.</div>
</div>
''', contentType: 'text/html'));

    final before = DateTime.now().toUtc();
    await service.search(query);
    final snapshot = service.snapshot();

    expect(snapshot.executedQueries, [query]);
    expect(snapshot.requestId, isNotEmpty);
    expect(snapshot.rootRequestId, snapshot.requestId);
    expect(snapshot.searchedAt.toUtc().isAfter(before), isTrue);
    expect(snapshot.results.single.url.toString(),
        'https://github.com/flutter/flutter');
  });
  test('evidence snapshots retain safe read and download tool receipts',
      () async {
    final service = DesktopWebService(TextWorker('unused'));
    final readSource = service.registerSource('https://docs.flutter.dev/macos');
    final downloadSource =
        service.registerSource('https://github.com/flutter/flutter/README.md');
    service.recordToolReceipt(
      tool: 'web.read',
      arguments: {'sourceId': readSource, 'startSection': 0},
      result: {
        'source_id': readSource,
        'byteLength': 321,
        'sha256': 'a' * 64,
        'nextSection': 1,
        'text': 'page body must not be retained in the receipt',
      },
    );
    service.recordToolReceipt(
      tool: 'web.download',
      arguments: {'sourceId': downloadSource},
      result: {
        'source_id': downloadSource,
        'fileName': 'README.md',
        'byteLength': 654,
        'sha256': 'b' * 64,
        'path': '/private/test/path/README.md',
      },
    );

    final evidence = service.evidenceSnapshot();
    final receipts = evidence['toolReceipts'] as List;
    expect(receipts, hasLength(2));
    expect(receipts[0], containsPair('tool', 'web.read'));
    expect(receipts[0], containsPair('sourceId', readSource));
    expect(receipts[0], containsPair('byteLength', 321));
    expect(receipts[0], containsPair('nextSection', 1));
    expect(receipts[0], containsPair('sha256', 'a' * 64));
    expect(receipts[0], isNot(contains('text')));
    expect(receipts[1], containsPair('tool', 'web.download'));
    expect(receipts[1], containsPair('fileName', 'README.md'));
    expect(receipts[1], containsPair('byteLength', 654));
    expect(receipts[1], isNot(contains('path')));
  });
  for (final html in [false, true]) {
    test('read preserves full original-byte evidence before parsing html=$html',
        () async {
      final text = html
          ? '<html><body>正文<script>hidden</script></body></html>'
          : '原文\r\n  keep whitespace  \n';
      final service = DesktopWebService(
          TextWorker(text, contentType: html ? 'text/html' : 'text/plain'));
      final result = await service
          .read(service.registerSource('https://example.com/read'));
      final bytes = utf8.encode(text);
      expect(result['byteLength'], bytes.length);
      expect(result['sha256'], sha256.convert(bytes).toString());
      if (html) expect(result['text'], isNot(contains('hidden')));
    });
  }
  test(
      'snapshot retains the most recently read sources with their original IDs',
      () async {
    final service = DesktopWebService(TextWorker('public evidence'));
    for (var index = 1; index <= 25; index++) {
      final id = service.registerSource('https://example.com/$index');
      await service.read(id);
    }
    expect(service.snapshot().results, hasLength(20));
    expect(service.snapshot().results.first.sourceId, 's25');
    await service.read('s1');
    expect(service.snapshot().results.first.sourceId, 's1');
    expect(service.snapshot().results.map((result) => result.sourceId),
        isNot(contains('s2')));
  });
  test('extensionless PDF, DOCX and XLSX use MIME and retain source locations',
      () async {
    List<int> zip(Map<String, String> files) {
      final archive = Archive();
      for (final entry in files.entries) {
        final bytes = utf8.encode(entry.value);
        archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
      }
      return ZipEncoder().encode(archive);
    }

    final pdf = PdfDocument();
    pdf.pages.add().graphics.drawString('Public document evidence',
        PdfStandardFont(PdfFontFamily.helvetica, 12),
        bounds: const Rect.fromLTWH(20, 20, 300, 40));
    final fixtures = [
      (
        mime: 'APPLICATION/PDF; charset=binary',
        bytes: await pdf.save(),
        location: 'page'
      ),
      (
        mime:
            'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        bytes: zip({
          'word/document.xml':
              '<w:document xmlns:w="word"><w:body><w:p><w:r><w:t>Public document evidence</w:t></w:r></w:p></w:body></w:document>'
        }),
        location: 'paragraph'
      ),
      (
        mime:
            'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        bytes: zip({
          'xl/workbook.xml':
              '<workbook xmlns:r="rel"><sheets><sheet name="Evidence" r:id="rId1"/></sheets></workbook>',
          'xl/_rels/workbook.xml.rels':
              '<Relationships><Relationship Id="rId1" Target="worksheets/sheet1.xml"/></Relationships>',
          'xl/worksheets/sheet1.xml':
              '<worksheet><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>Public document evidence</t></is></c></row></sheetData></worksheet>',
        }),
        location: 'sheet'
      ),
    ];
    pdf.dispose();
    for (final fixture in fixtures) {
      final service = DesktopWebService(
          TextWorker.bytes(fixture.bytes, contentType: fixture.mime));
      final id = service.registerSource('https://example.com/download?id=1');
      final result = await service.read(id);
      expect(result['byteLength'], fixture.bytes.length);
      expect(result['sha256'], sha256.convert(fixture.bytes).toString());
      final sections = result['sections'] as List;
      expect(sections.first['text'], contains('Public document evidence'));
      expect(sections.first[fixture.location], isNotNull);
      expect(service.snapshot().hasResults, isTrue);
    }
  });

  test('larger binary allowance does not relax the text byte limit', () async {
    final service = DesktopWebService(TextWorker('a' * (2 * 1024 * 1024 + 1)));
    final id = service.registerSource('https://example.com/text');
    await expectLater(service.read(id), throwsStateError);
    expect(service.snapshot().hasResults, isFalse);
  });
  test('user links retain IDs across follow-ups and checkpoint restoration',
      () {
    final worker = TextWorker('');
    final service = DesktopWebService(worker)
      ..registerUserSources('读取 https://example.com/a 然后 https://127.0.0.1/');
    expect(service.exportSources(), {'s1': 'https://example.com/a'});
    final restored = DesktopWebService(worker)
      ..restoreSources(service.exportSources())
      ..registerUserSources(
          '仍读取 https://example.com/a 下载 https://example.com/b');
    expect(restored.exportSources(), {
      's1': 'https://example.com/a',
      's2': 'https://example.com/b',
    });
  });

  test('user links exclude sentence punctuation from registered source URLs',
      () {
    final service = DesktopWebService(TextWorker(''))
      ..registerUserSources(
        'Read https://github.com/flutter/flutter. '
        'Then https://example.com/read?id=1, plus https://example.com/docs。',
      );

    expect(service.exportSources(), {
      's1': 'https://github.com/flutter/flutter',
      's2': 'https://example.com/read?id=1',
      's3': 'https://example.com/docs',
    });
  });

  test('text pagination reads every character without splitting an emoji',
      () async {
    final text = '${'a' * 11999}😀${'b' * 13000}';
    final service = DesktopWebService(TextWorker(text));
    final id = service.registerSource('https://example.com/article.txt');
    final pages = <String>[];
    int? next = 0;
    while (next != null) {
      final page = await service.read(id, startSection: next);
      final value = page['text'] as String;
      expect(utf8.decode(utf8.encode(value)), value);
      pages.add(value);
      next = page['nextSection'] as int?;
      expect(pages.length, lessThan(5));
    }
    expect(pages.join(), text);
    await expectLater(service.read(id, startSection: 3), throwsStateError);
    await expectLater(service.read(id, startSection: -1), throwsStateError);
  });

  test(
      'HTML pages expose later body text; unsupported files do not become evidence',
      () async {
    final service = DesktopWebService(TextWorker(
        '<html><body>${'a' * 12000}<p>later paragraph</p></body></html>',
        contentType: 'text/html'));
    final id = service.registerSource('https://example.com/article');
    expect((await service.read(id))['nextSection'], 1);
    expect((await service.read(id, startSection: 1))['text'],
        contains('later paragraph'));
    final unsupported = DesktopWebService(
        TextWorker('binary', contentType: 'application/octet-stream'));
    final source =
        unsupported.registerSource('https://example.com/archive.zip');
    await expectLater(unsupported.read(source), throwsStateError);
    expect(unsupported.snapshot().hasResults, isFalse);
  });
  test('source identifiers are isolated, validated and deduplicated', () {
    final worker =
        WebWorkerClient(executable: '/unused', entryPoint: '/unused');
    addTearDown(worker.close);
    final first = DesktopWebService(worker);
    final second = DesktopWebService(worker);
    final id = first.registerSource('https://example.com/article');
    expect(first.registerSource('https://example.com/article'), id);
    expect(first.source(id).host, 'example.com');
    expect(() => second.source(id), throwsStateError);
    expect(
        () => first.registerSource('https://127.0.0.1/'), throwsArgumentError);
    expect(() => first.registerSource('https://example.com:8443/'),
        throwsStateError);
  });
  test('sensitive and empty searches fail before starting worker', () async {
    final worker =
        WebWorkerClient(executable: '/unused', entryPoint: '/unused');
    addTearDown(worker.close);
    final service = DesktopWebService(worker);
    await expectLater(service.search(''), throwsStateError);
    await expectLater(service.search('x' * 401), throwsStateError);
  });
  test('source checkpoint restores stable IDs and rejects private replacements',
      () {
    final worker =
        WebWorkerClient(executable: '/unused', entryPoint: '/unused');
    addTearDown(worker.close);
    final original = DesktopWebService(worker);
    final id = original.registerSource('https://example.com/source');
    final restored = DesktopWebService(worker)
      ..restoreSources(original.exportSources());
    expect(restored.source(id).toString(), 'https://example.com/source');
    expect(restored.registerSource('https://example.com/next'), 's2');
    expect(
        () => DesktopWebService(worker)
            .restoreSources({'s1': 'https://127.0.0.1/'}),
        throwsArgumentError);
    expect(
        () => DesktopWebService(worker)
            .restoreSources({'s2': 'https://example.com/'}),
        throwsStateError);
  });
  test('invalid checkpoint shape cannot silently reset source IDs', () {
    final worker =
        WebWorkerClient(executable: '/unused', entryPoint: '/unused');
    addTearDown(worker.close);
    for (final raw in <Object>[
      'corrupt',
      <String>['https://example.com/'],
      {for (var i = 1; i <= 101; i++) 's$i': 'https://example.com/$i'},
    ]) {
      final service = DesktopWebService(worker);
      expect(() => service.restoreSources(raw), throwsStateError);
      expect(service.exportSources(), isEmpty);
    }
  });
}

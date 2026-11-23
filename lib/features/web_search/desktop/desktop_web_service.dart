import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import '../../document/binary_document_parser.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'dart:typed_data';
import 'package:uuid/uuid.dart';
import 'package:html/parser.dart' as html;
import '../security/search_endpoint_validator.dart';
import '../models/search_models.dart';
import '../security/search_secret_scanner.dart';
import 'public_search_parser.dart';
import 'public_web_sources.dart';
import 'web_worker_client.dart';

part 'desktop_web_content_parser.dart';
part 'desktop_web_evidence.dart';
part 'desktop_web_tool_failure.dart';

/// One instance belongs to one reply/task; source IDs cannot cross that boundary.
///
/// 这个类只做三件事：发联网请求（[search] / [read] / [download]）、把结果
/// 变成安全的数据结构、把证据交给 [_DesktopWebEvidence]。内容解析
/// （HTML 正文、分页、下载类型校验）在 `desktop_web_content_parser.dart`，
/// 证据与回执在 `desktop_web_evidence.dart`，失败类型在
/// `desktop_web_tool_failure.dart`。
class DesktopWebService {
  DesktopWebService(this.worker);
  static const _baiduRealtimeBoard = 'https://top.baidu.com/board?tab=realtime';
  final WebWorkerClient worker;
  final String _requestId = const Uuid().v4();
  final _sources = PublicWebSources();

  late final _DesktopWebEvidence _evidence = _DesktopWebEvidence(
    requestId: _requestId,
    resolveSource: (id) => _sources.source(id),
  );

  Map<String, String> exportSources() => _sources.toMap();
  void restoreSources(Object? raw) => _sources.restore(raw);
  String registerSource(String value) => _sources.register(value);
  void registerUserSources(String text) => _sources.registerUserText(text);
  Uri source(String id) => _sources.source(id);

  WebSearchSnapshot snapshot() => _evidence.snapshot();

  bool get hasEvidence => _evidence.hasEvidence;

  Map<String, dynamic> evidenceSnapshot() => _evidence.evidenceSnapshot();

  Map<String, dynamic> recordToolReceipt({
    required String tool,
    required Map<String, dynamic> arguments,
    required Object result,
  }) =>
      _evidence.recordToolReceipt(
        tool: tool,
        arguments: arguments,
        result: result,
      );

  void recordDuplicateToolRequest(String tool) =>
      _evidence.recordDuplicateToolRequest(tool);

  List<Map<String, dynamic>> exportToolReceipts() => _evidence.exportReceipts();

  Future<List<Map<String, String>>> search(String query,
      {Future<void>? cancellation}) async {
    if (query.trim().isEmpty ||
        query.length > 400 ||
        const SearchSecretScanner().containsSensitiveData(query)) {
      throw StateError('搜索词无效或包含敏感信息。');
    }
    if (_evidence.executedQueries.length < searchMaxExecutedQueries) {
      _evidence.executedQueries.add(query.trim());
    }
    _evidence.searchedAt ??= DateTime.now().toUtc();
    // This is a known public entry, never a receipt for fetched ranking data.
    if (RegExp(r'(?:^|\s)site:top\.baidu\.com(?:\s|$)|百度\s*热搜')
        .hasMatch(query)) {
      final id = registerSource(_baiduRealtimeBoard);
      const title = '百度热搜（官方实时榜单入口，需读取获取排名）';
      const snippet = '已知官方公开入口；排名与内容仅以 web.read 的真实返回为准。';
      const provider = '官方公开入口';
      _evidence.remember(id, title: title, snippet: snippet, provider: provider);
      _evidence.searchedAt = DateTime.now().toUtc();
      return [
        {
          'source_id': id,
          'title': title,
          'url': _baiduRealtimeBoard,
          'snippet': snippet,
          'provider': provider,
          'discovery': 'known_official_entry'
        }
      ];
    }
    var cancelled = false;
    if (cancellation != null) {
      unawaited(cancellation.then((_) {
        cancelled = true;
      }));
    }
    for (final bing in [false, true]) {
      if (cancelled) throw StateError('联网搜索已取消。');
      final url = bing
          ? Uri.https('www.bing.com', '/search', {'q': query})
          : Uri.https('html.duckduckgo.com', '/html/', {'q': query});
      try {
        final response =
            await _fetch(url, 512 * 1024, cancellation: cancellation);
        final parsedItems = parsePublicSearchResults(
            utf8.decode(response.bytes, allowMalformed: true),
            bing: bing);
        final items = parsedItems
            .where((item) =>
                _matchesSiteSearchRestriction(query, item['url'] ?? ''))
            .toList(growable: false);
        if (items.isEmpty) continue;
        for (final item in items) {
          final id = registerSource(item['url']!);
          _evidence.remember(id,
              title: item['title'],
              snippet: item['snippet'] ?? '',
              provider: bing ? 'Bing HTML' : 'DuckDuckGo HTML');
        }
        _evidence.searchedAt = DateTime.now().toUtc();
        return [
          for (final item in items)
            {
              ...item,
              'source_id': registerSource(item['url']!),
              'provider': bing ? 'Bing HTML' : 'DuckDuckGo HTML',
            }
        ];
      } on Object {
        if (bing) rethrow;
      }
    }
    throw StateError('免 Key 搜索未返回可用来源。');
  }

  /// The caller supplies an app-managed directory, never a model-provided path.
  Future<Map<String, dynamic>> download(String sourceId, Directory root,
      {String? fileName, Future<void>? cancellation}) async {
    var cancelled = false;
    if (cancellation != null) {
      unawaited(cancellation.then((_) {
        cancelled = true;
      }));
    }
    void checkCancellation() {
      if (cancelled) throw StateError('下载已停止。');
    }

    final url = source(sourceId);
    final proposed = fileName ??
        (url.pathSegments.isEmpty ? 'download' : url.pathSegments.last);
    final name =
        proposed.replaceAll(RegExp(r'[^a-zA-Z0-9._\u4e00-\u9fff-]'), '_');
    if (name.isEmpty ||
        name == '.' ||
        name == '..' ||
        name.length > 120 ||
        name.endsWith('.') ||
        RegExp(r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)',
                caseSensitive: false)
            .hasMatch(name)) {
      throw StateError('下载文件名无效。');
    }
    await root.create(recursive: true);
    final resolvedRoot = Directory(await root.resolveSymbolicLinks());
    checkCancellation();
    final folder = await resolvedRoot.createTemp('download_');
    final temporary = File(p.join(folder.path, '.partial'));
    var committed = false;
    try {
      checkCancellation();
      final output = await temporary.open(mode: FileMode.writeOnly);
      var size = 0;
      var completed = false;
      var contentType = '';
      try {
        await for (final frame in _frames({
          'operation': 'fetch',
          'url': url.toString(),
          'maxBytes': 64 * 1024 * 1024,
        }, cancellation: cancellation)) {
          switch (frame['status']) {
            case 'headers':
              SearchEndpointValidator.requireValid(frame['url'] as String,
                  isRelease: true);
              contentType = (frame['contentType'] as String).trim();
            case 'chunk':
              final chunk = base64Decode(frame['data'] as String);
              size += chunk.length;
              if (size > 64 * 1024 * 1024) throw StateError('下载文件超过上限。');
              await output.writeFrom(chunk);
            case 'done':
              if (frame['byteLength'] != size) throw StateError('下载文件不完整。');
              completed = true;
            case 'error':
              throw DesktopWebToolFailure.fromFrame(frame);
          }
        }
        if (!completed) throw StateError('下载提前结束。');
        _validateDownloadContentType(name, contentType);
        checkCancellation();
        await output.flush();
      } finally {
        await output.close();
      }
      final digest = await sha256.bind(temporary.openRead()).first;
      checkCancellation();
      final target = await temporary.rename(p.join(folder.path, name));
      checkCancellation();
      committed = true;
      _evidence.remember(sourceId);
      return {
        'source_id': sourceId,
        'path': target.path,
        'fileName': name,
        'byteLength': size,
        'sha256': digest.toString(),
        'url': url.toString()
      };
    } finally {
      if (!committed && await folder.exists()) {
        await folder.delete(recursive: true);
      }
    }
  }

  Future<Map<String, dynamic>> read(String sourceId,
      {int startSection = 0, Future<void>? cancellation}) async {
    if (startSection < 0) throw StateError('正文段落编号无效。');
    final url = source(sourceId);
    final response = await _fetch(url, 10 * 1024 * 1024,
        reading: true, cancellation: cancellation);
    final original = {
      'byteLength': response.bytes.length,
      'sha256': sha256.convert(response.bytes).toString(),
    };
    final format = _documentFormatFor(response.url, response.contentType);
    if (format != null) {
      final sections = await Isolate.run(
          () => BinaryDocumentParser.parse(format, response.bytes));
      if (startSection < 0 || startSection >= sections.length) {
        throw StateError('文档没有可读取的该段正文。');
      }
      final end = (startSection + 8).clamp(0, sections.length);
      _evidence.remember(sourceId);
      return {
        'source_id': sourceId,
        ...original,
        'sections': [
          for (final section in sections.sublist(startSection, end))
            {
              'text': section.text,
              'page': section.page,
              'paragraph': section.paragraph,
              'sheet': section.sheet,
              'rowStart': section.rowStart,
              'rowEnd': section.rowEnd,
            }
        ],
        'nextSection': end < sections.length ? end : null
      };
    }
    final text = utf8.decode(response.bytes, allowMalformed: true);
    if (response.contentType.contains('html')) {
      final page = _parseHtmlPage(text, response.url);
      final links = <Map<String, String>>[];
      for (final item in page.rankingItems) {
        final id = registerSource(item['url'] as String);
        item['source_id'] = id;
        _evidence.remember(id,
            title: item['title'] as String,
            snippet: '百度热搜第 ${item['rank']} 名',
            provider: '百度官方实时榜单');
        links.add({
          'source_id': id,
          'title': item['title'] as String,
          'url': item['url'] as String
        });
      }
      final linked = links.map((link) => link['source_id']).toSet();
      for (final link in page.links) {
        if (links.length >= 20) break;
        final id = registerSource(link.url.toString());
        if (!linked.add(id)) continue;
        links.add({
          'source_id': id,
          'title': link.title,
          'url': link.url.toString()
        });
      }
      final pageText = _textPageOf(
          page.officialRanking
              ? '百度热搜实时榜单，前十名以 ranking.items 为准，独立置顶条目未计入排名。'
              : page.body,
          startSection);
      _evidence.remember(sourceId);
      return {
        'source_id': sourceId,
        ...original,
        ...pageText,
        'links': links,
        if (page.officialRanking)
          'ranking': {
            'platform': '百度热搜',
            'boardUrl': response.url.toString(),
            'observedAt': DateTime.now().toUtc().toIso8601String(),
            'items': page.rankingItems,
          }
      };
    }
    if (!response.contentType.startsWith('text/') &&
        !const ['.md', '.txt', '.csv', '.json']
            .any(response.url.path.toLowerCase().endsWith)) {
      throw StateError('此文件需要文档解析器处理。');
    }
    final page = _textPageOf(text, startSection);
    _evidence.remember(sourceId);
    return {
      'source_id': sourceId,
      ...original,
      ...page,
    };
  }

  Stream<Map<String, dynamic>> _frames(Map<String, dynamic> arguments,
      {Future<void>? cancellation}) {
    if (cancellation == null) return worker.request(arguments);
    late StreamController<Map<String, dynamic>> controller;
    StreamSubscription<Map<String, dynamic>>? subscription;
    var finished = false;
    controller = StreamController(onListen: () {
      subscription = worker
          .request(arguments)
          .listen(controller.add, onError: controller.addError, onDone: () {
        finished = true;
        unawaited(controller.close());
      });
      unawaited(cancellation.then((_) async {
        if (finished) return;
        finished = true;
        await subscription?.cancel();
        controller.addError(StateError('联网操作已取消。'));
        await controller.close();
      }));
    }, onCancel: () async {
      finished = true;
      await subscription?.cancel();
    });
    return controller.stream;
  }

  Future<({Uri url, String contentType, Uint8List bytes})> _fetch(
      Uri url, int maxBytes,
      {Future<void>? cancellation, bool reading = false}) async {
    final bytes = BytesBuilder(copy: false);
    Uri? finalUrl;
    var contentType = '';
    await for (final frame in _frames(
        {'operation': 'fetch', 'url': url.toString(), 'maxBytes': maxBytes},
        cancellation: cancellation)) {
      switch (frame['status']) {
        case 'headers':
          finalUrl = SearchEndpointValidator.requireValid(
              frame['url'] as String,
              isRelease: true);
          contentType = (frame['contentType'] as String).trim().toLowerCase();
        case 'chunk':
          bytes.add(base64Decode(frame['data'] as String));
          final limit =
              reading && _documentFormatFor(finalUrl ?? url, contentType) == null
                  ? 2 * 1024 * 1024
                  : maxBytes;
          if (bytes.length > limit) throw StateError('来源内容超过上限。');
        case 'done':
          if (finalUrl == null || frame['byteLength'] != bytes.length) {
            throw StateError('来源内容不完整。');
          }
          return (
            url: finalUrl,
            contentType: contentType,
            bytes: bytes.takeBytes()
          );
        case 'error':
          throw DesktopWebToolFailure.fromFrame(frame);
      }
    }
    throw StateError('联网请求提前结束。');
  }
}

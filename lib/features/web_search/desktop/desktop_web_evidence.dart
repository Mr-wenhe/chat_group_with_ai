part of 'desktop_web_service.dart';

/// 一次回复/任务内的证据与工具回执。
///
/// 这些内容原先和检索、下载、阅读三段流程挤在同一个类里：收据组装要靠
/// `_requestId`、来源 URL 解析和已执行查询，而读页面时又要顺手写证据。
/// 拆出来之后 service 只负责"发请求"，证据怎么留痕、留多少只在这里演进。
class _DesktopWebEvidence {
  _DesktopWebEvidence({
    required this.requestId,
    required Uri Function(String sourceId) resolveSource,
  }) : _resolveSource = resolveSource;

  final String requestId;
  final Uri Function(String sourceId) _resolveSource;

  /// 本轮已取得正文的来源（按 sourceId 去重）。
  final Map<String, WebSearchResult> results = {};

  /// 工具回执，最多保留最近 [maxReceipts] 条。
  final List<Map<String, dynamic>> receipts = [];

  /// 本轮实际执行过的查询（去重后用于快照与重复请求判定）。
  final List<String> executedQueries = [];

  DateTime? searchedAt;

  static const int maxReceipts = 12;

  bool get hasEvidence =>
      results.isNotEmpty || executedQueries.isNotEmpty || receipts.isNotEmpty;

  WebSearchSnapshot snapshot() => WebSearchSnapshot(
        requestId: requestId,
        rootRequestId: requestId,
        executedQueries: executedQueries,
        searchedAt: searchedAt ?? DateTime.now().toUtc(),
        provider: 'autonomous-web',
        results: results.values.toList().reversed,
      );

  Map<String, dynamic> evidenceSnapshot() => {
        ...snapshot().toMap(),
        if (receipts.isNotEmpty)
          'toolReceipts': receipts
              .map((receipt) => Map<String, dynamic>.from(receipt))
              .toList(growable: false),
      };

  /// 记录一段已读到的来源正文。
  ///
  /// [title] 为空时保留上一次的标题：`web.read` 只知道正文，不该把搜索结果里
  /// 已经拿到的标题冲掉。
  void remember(
    String id, {
    String? title,
    String snippet = '',
    String provider = 'public-web',
  }) {
    final previous = results.remove(id);
    if (title == null && previous != null) {
      results[id] = previous;
      return;
    }
    results[id] = WebSearchResult(
      sourceId: id,
      title: title ?? _resolveSource(id).host,
      snippet: snippet,
      url: _resolveSource(id),
      provider: provider,
    );
  }

  Map<String, dynamic> recordToolReceipt({
    required String tool,
    required Map<String, dynamic> arguments,
    required Object result,
  }) {
    if (!_knownNetworkTool(tool)) return const <String, dynamic>{};
    final resultMap = result is Map ? result : null;
    final failed = resultMap?.containsKey('error') == true;
    final receipt = <String, dynamic>{
      'receiptId': const Uuid().v4(),
      'requestId': requestId,
      'tool': tool,
      'status': failed ? 'failed' : 'success',
      'completedAt': DateTime.now().toUtc().toIso8601String(),
    };

    if (tool == 'web.search') {
      final query = arguments['query'];
      final normalizedQuery = query is String ? query.trim() : '';
      if (normalizedQuery.isNotEmpty &&
          executedQueries.contains(normalizedQuery)) {
        receipt['query'] = normalizedQuery;
      }
      final sources = <Map<String, String>>[];
      if (result is List) {
        for (final item in result.whereType<Map>()) {
          final sourceId = item['source_id']?.toString();
          final url = _receiptUrl(sourceId);
          if (sourceId == null || url == null) continue;
          sources.add({'sourceId': sourceId, 'url': url.toString()});
        }
      }
      receipt['sourceCount'] = sources.length;
      receipt['sources'] = sources;
    } else {
      final sourceId = arguments['sourceId']?.toString();
      final url = _receiptUrl(sourceId);
      if (sourceId != null) receipt['sourceId'] = sourceId;
      if (url != null) receipt['url'] = url.toString();

      if (tool == 'web.read') {
        final startSection = arguments['startSection'];
        if (startSection is int && startSection >= 0) {
          receipt['startSection'] = startSection;
        }
        final nextSection = resultMap?['nextSection'];
        if (nextSection is int && nextSection >= 0) {
          receipt['nextSection'] = nextSection;
        }
        _copyByteEvidence(receipt, resultMap);
      } else {
        final fileName = resultMap?['fileName'];
        if (fileName is String &&
            fileName.isNotEmpty &&
            p.basename(fileName) == fileName) {
          receipt['fileName'] = fileName;
        }
        _copyByteEvidence(receipt, resultMap);
      }
    }

    if (failed && resultMap != null) {
      final code = resultMap['code'];
      if (code is String && RegExp(r'^[A-Z_]{1,64}$').hasMatch(code)) {
        receipt['failureCode'] = code;
      }
      final sourceStatus = resultMap['sourceStatus'];
      if (sourceStatus is int && sourceStatus >= 100 && sourceStatus <= 599) {
        receipt['sourceStatus'] = sourceStatus;
      }
      if (resultMap['retryable'] is bool) {
        receipt['retryable'] = resultMap['retryable'];
      }
    }

    return _append(receipt);
  }

  void recordDuplicateToolRequest(String tool) {
    if (!_knownNetworkTool(tool)) return;
    _append({
      'receiptId': const Uuid().v4(),
      'requestId': requestId,
      'tool': tool,
      'status': 'duplicate_skipped',
      'completedAt': DateTime.now().toUtc().toIso8601String(),
    });
  }

  List<Map<String, dynamic>> exportReceipts() => receipts
      .map((receipt) => Map<String, dynamic>.from(receipt))
      .toList(growable: false);

  Map<String, dynamic> _append(Map<String, dynamic> receipt) {
    final immutable = Map<String, dynamic>.unmodifiable(receipt);
    receipts.add(immutable);
    if (receipts.length > maxReceipts) receipts.removeAt(0);
    return Map<String, dynamic>.from(immutable);
  }

  Uri? _receiptUrl(String? sourceId) {
    if (sourceId == null || sourceId.isEmpty) return null;
    try {
      return _resolveSource(sourceId);
    } on Object {
      return null;
    }
  }

  static bool _knownNetworkTool(String tool) =>
      tool == 'web.search' || tool == 'web.read' || tool == 'web.download';

  static void _copyByteEvidence(Map<String, dynamic> receipt, Map? result) {
    final byteLength = result?['byteLength'];
    if (byteLength is int && byteLength >= 0) {
      receipt['byteLength'] = byteLength;
    }
    final digest = result?['sha256'];
    if (digest is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)) {
      receipt['sha256'] = digest;
    }
  }
}

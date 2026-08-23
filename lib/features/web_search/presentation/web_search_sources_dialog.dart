import 'package:flutter/material.dart';

import 'package:chat_group/services/web_search_service.dart' as legacy;

import '../application/search_context_formatter.dart';

/// Presents only sources that survived the same formatter used by the AI
/// prompt, so [Sx] labels cannot point at a hidden or unknown result.
class SourcesDialog extends StatelessWidget {
  final legacy.WebSearchSnapshot snapshot;
  final SearchContextFormatter formatter;
  final ValueChanged<Uri>? onOpenSource;

  const SourcesDialog({
    super.key,
    required this.snapshot,
    this.formatter = const SearchContextFormatter(),
    this.onOpenSource,
  });

  static Future<void> show(
    BuildContext context,
    legacy.WebSearchSnapshot snapshot, {
    ValueChanged<Uri>? onOpenSource,
  }) {
    return showDialog<void>(
      context: context,
      builder: (_) => SourcesDialog(
        snapshot: snapshot,
        onOpenSource: onOpenSource,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bundle = formatter.formatLegacy(snapshot);
    final visibleResults = snapshot.results.take(bundle.sourceIds.length);
    return AlertDialog(
      title: const Text('联网搜索来源'),
      content: SizedBox(
        width: 560,
        child: ListView(
          shrinkWrap: true,
          children: [
            Text('查询：${_queryPreview()}'),
            Text('Provider：${snapshot.provider}'),
            Text('时间：${snapshot.searchedAt.toLocal()}'),
            if (snapshot.failureType != null || snapshot.safeMessage != null)
              _failureCard(context),
            if (visibleResults.isEmpty && snapshot.failureType == null)
              const Padding(
                padding: EdgeInsets.only(top: 16),
                child: Text('没有可展示的来源。'),
              ),
            for (var index = 0; index < visibleResults.length; index++)
              _sourceTile(
                context,
                sourceId: bundle.sourceIds.elementAt(index),
                result: visibleResults.elementAt(index),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  Widget _failureCard(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(top: 12, bottom: 8),
      color: colorScheme.errorContainer.withValues(alpha: 0.45),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '失败类型：${snapshot.failureType?.name ?? 'unknown'}',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(snapshot.safeMessage ?? '联网搜索失败，请稍后重试'),
            if (snapshot.statusCode != null)
              Text('HTTP 状态码：${snapshot.statusCode}'),
            Text('请求耗时：${snapshot.latencyMs}ms · 重试 ${snapshot.retryCount} 次'),
          ],
        ),
      ),
    );
  }

  Widget _sourceTile(
    BuildContext context, {
    required String sourceId,
    required legacy.WebSearchResult result,
  }) {
    final uri = _safeUri(result.url);
    final published = result.publishedAt == null
        ? '未提供发布日期'
        : result.publishedAt!.toLocal().toIso8601String().split('T').first;
    final provider = result.provider.trim().isEmpty
        ? snapshot.provider
        : result.provider.trim();
    return ListTile(
      key: ValueKey('web-search-source-$sourceId'),
      contentPadding: EdgeInsets.zero,
      title: Text('[$sourceId] ${result.title}'),
      subtitle: Text(
        '${uri?.host ?? '无有效链接'} · $published · Provider：$provider\n'
        '${result.snippet}',
      ),
      trailing: uri == null || onOpenSource == null
          ? null
          : IconButton(
              tooltip: '在外部浏览器打开',
              icon: const Icon(Icons.open_in_new_rounded),
              onPressed: () => onOpenSource!(uri),
            ),
    );
  }

  String _queryPreview() {
    final queries = snapshot.executedQueries.isEmpty
        ? [snapshot.query]
        : snapshot.executedQueries;
    return queries.firstWhere(
      (query) => query.trim().isNotEmpty,
      orElse: () => '未提供查询',
    );
  }

  Uri? _safeUri(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null || uri.host.isEmpty) return null;
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return null;
    return uri;
  }
}

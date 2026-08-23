import 'package:flutter/material.dart';

import 'package:chat_group/features/ai_governance/search_audit_entry.dart';

/// Displays persisted search records and keeps the safe failure detail view
/// outside the broader AI governance settings page.
class WebSearchAuditCard extends StatelessWidget {
  final List<SearchAuditEntry> entries;
  final VoidCallback? onClear;

  const WebSearchAuditCard({
    super.key,
    required this.entries,
    this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final visible = entries.reversed.take(20).toList(growable: false);
    return Card(
      child: Column(
        children: [
          ListTile(
            title: Text('${entries.length} 条联网记录'),
            subtitle: const Text('含查询、时间、状态和来源；最多保留 100 条'),
            trailing: TextButton(
              onPressed: entries.isEmpty ? null : onClear,
              child: const Text('清除'),
            ),
          ),
          for (final entry in visible)
            ListTile(
              dense: true,
              title: Text(entry.query),
              subtitle: Text(
                '${entry.status} · ${entry.searchedAt.toLocal()}',
              ),
              trailing: Text('${entry.sources.length} 来源'),
              onTap: () => _showDetails(context, entry),
            ),
        ],
      ),
    );
  }

  void _showDetails(BuildContext context, SearchAuditEntry entry) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('联网搜索详情'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _detailLine('查询', entry.query),
              _detailLine('Provider', entry.provider),
              _detailLine('状态', entry.status),
              _detailLine('时间', entry.searchedAt.toLocal().toString()),
              if (entry.failureType != null)
                _detailLine('失败类型', entry.failureType!),
              if (entry.statusCode != null)
                _detailLine('HTTP 状态码', '${entry.statusCode}'),
              _detailLine('耗时', '${entry.latencyMs}ms'),
              _detailLine('重试', '${entry.retryCount} 次'),
              _detailLine('缓存', entry.fromCache ? '命中' : '未命中'),
              _detailLine('来源数', '${entry.sourceCount}'),
              if (entry.sources.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text(
                  '来源 URL（已脱敏）',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                for (final source in entry.sources) SelectableText(source),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Widget _detailLine(String label, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text('$label：$value'),
      );
}

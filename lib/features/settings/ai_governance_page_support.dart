part of 'ai_governance_page.dart';

extension _AiGovernancePageSupport on _AiGovernancePageState {
  Widget _usageCard() {
    final entries = _store.ledgerEntries.reversed.toList(growable: false);
    final byPurpose = aggregateUsage(entries, (entry) => entry.purpose.label);
    final totals = <String, int>{};
    for (final entry in entries) {
      final cost = entry.estimatedCostMicros;
      final currency = entry.currency;
      if (cost != null && currency != null) {
        totals[currency] = (totals[currency] ?? 0) + cost;
      }
    }
    return Card(
      child: Column(
        children: [
          ListTile(
            title: Text(entries.isEmpty
                ? '暂无调用记录'
                : totals.entries
                    .map((item) =>
                        '${item.key} ${MoneyMicros.display(item.value)}')
                    .join(' · ')),
            subtitle: Text('${entries.length} 条明细；价格未知时仅显示 Token'),
            trailing: TextButton(
              onPressed: entries.isEmpty ? null : _clearUsage,
              child: const Text('清除'),
            ),
          ),
          if (byPurpose.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final item in byPurpose.entries)
                    Chip(
                      label: Text(
                        '${item.key} ${item.value.requestCount} 次 · '
                        '${item.value.inputTokens + item.value.outputTokens} Token',
                      ),
                    ),
                ],
              ),
            ),
          for (final entry in entries.take(30))
            ListTile(
              dense: true,
              title: Text(
                '${entry.purpose.label} · ${entry.provider}/${entry.model}',
              ),
              subtitle: Text(
                '${entry.inputTokens} 入 / ${entry.cachedInputTokens} 缓存 / '
                '${entry.outputTokens} 出 · ${entry.exactUsage ? '精确' : '估算'}',
              ),
              trailing: Text(entry.estimatedCostMicros == null
                  ? '价格未知'
                  : '${entry.currency} '
                      '${MoneyMicros.display(entry.estimatedCostMicros!)}'),
            ),
        ],
      ),
    );
  }

  Widget _diagnosticsCard() {
    final items = _store.diagnostics.reversed.toList(growable: false);
    return Card(
      child: Column(
        children: [
          ListTile(
            title: Text('${items.length} 条诊断'),
            subtitle: const Text('不保存 Key、Authorization、提示词或消息正文'),
            trailing: TextButton(
              onPressed: items.isEmpty ? null : _clearDiagnostics,
              child: const Text('清除'),
            ),
          ),
          for (final item in items.take(30))
            ListTile(
              dense: true,
              title: Text('${item.purpose.label} · ${item.status}'),
              subtitle: Text(
                '${item.provider}/${item.model} · ${item.latencyMs}ms · '
                '重试 ${item.retryCount}',
              ),
              trailing: IconButton(
                icon: const Icon(Icons.copy_rounded, size: 18),
                tooltip: '复制脱敏诊断',
                onPressed: () => Clipboard.setData(
                  ClipboardData(text: item.toSafeText()),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

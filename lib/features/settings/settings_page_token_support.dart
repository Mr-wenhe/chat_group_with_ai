part of 'settings_page.dart';

extension _SettingsPageTokenSupport on _SettingsPageState {
  Widget _buildTokenSection(ColorScheme cs) {
    final totalInput = _tokenUsage['totalInput'] ?? 0;
    final totalOutput = _tokenUsage['totalOutput'] ?? 0;
    final totalCachedInput = _tokenUsage['totalCachedInput'] ?? 0;
    final requestCount = _tokenUsage['requestCount'] ?? 0;
    final byChar = _tokenUsage['byCharacter'] is Map
        ? Map<String, dynamic>.from(_tokenUsage['byCharacter'] as Map)
        : <String, dynamic>{};
    final byGroup = _tokenUsage['byGroup'] is Map
        ? Map<String, dynamic>.from(_tokenUsage['byGroup'] as Map)
        : <String, dynamic>{};
    final db = ref.read(databaseServiceProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(title: 'Token 消耗', cs: cs),
        const SizedBox(height: 12),
        AppCard(
          cs: cs,
          margin: EdgeInsets.zero,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  _statIcon(Icons.input_rounded, cs.primary),
                  const SizedBox(width: 12),
                  Expanded(child: _statLabel('输入 Token', totalInput)),
                  _statValue(totalInput.toString(), cs),
                ],
              ),
            ),
            Divider(height: 1, color: cs.outlineVariant.withValues(alpha: 0.5)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  _statIcon(Icons.output_rounded, cs.secondary),
                  const SizedBox(width: 12),
                  Expanded(child: _statLabel('输出 Token', totalOutput)),
                  _statValue(totalOutput.toString(), cs),
                ],
              ),
            ),
            Divider(height: 1, color: cs.outlineVariant.withValues(alpha: 0.5)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  _statIcon(Icons.query_stats_rounded, cs.tertiary),
                  const SizedBox(width: 12),
                  Expanded(child: _statLabel('请求次数', requestCount)),
                  _statValue('$requestCount 次', cs),
                ],
              ),
            ),
            Divider(height: 1, color: cs.outlineVariant.withValues(alpha: 0.5)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  _statIcon(Icons.offline_bolt_rounded, cs.primary),
                  const SizedBox(width: 12),
                  Expanded(child: _statLabel('缓存命中 Token', totalCachedInput)),
                  _statValue(_cachePercent(totalCachedInput, totalInput), cs),
                ],
              ),
            ),
            if (byGroup.isNotEmpty) ...[
              Divider(
                  height: 1, color: cs.outlineVariant.withValues(alpha: 0.5)),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Text('各群消耗',
                    style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurfaceVariant,
                        fontWeight: FontWeight.w600)),
              ),
              ...byGroup.entries.map((entry) {
                final data = Map<String, dynamic>.from(entry.value as Map);
                final groupIn = data['input'] ?? 0;
                final groupOut = data['output'] ?? 0;
                final groupCached = data['cached'] ?? 0;
                final groupCount = data['count'] ?? 0;
                final groupName =
                    db.chatGroupBox.get(entry.key)?.name ?? entry.key;
                return Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  child: Row(
                    children: [
                      Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                              color: cs.secondary,
                              borderRadius: BorderRadius.circular(2))),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(groupName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 13, color: cs.onSurface)),
                            Text(
                                '$groupCount 次 · 缓存 ${_cachePercent(groupCached, groupIn)}',
                                style: TextStyle(
                                    fontSize: 11, color: cs.onSurfaceVariant)),
                          ],
                        ),
                      ),
                      Text('${groupIn + groupOut}',
                          style: TextStyle(
                              fontSize: 13,
                              color: cs.onSurfaceVariant,
                              fontFamily: 'monospace')),
                    ],
                  ),
                );
              }),
              const SizedBox(height: 4),
            ],
            if (byChar.isNotEmpty) ...[
              Divider(
                  height: 1, color: cs.outlineVariant.withValues(alpha: 0.5)),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Text('各角色消耗',
                    style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurfaceVariant,
                        fontWeight: FontWeight.w600)),
              ),
              ...byChar.entries.map((entry) {
                final data = entry.value is Map
                    ? Map<String, dynamic>.from(entry.value as Map)
                    : <String, dynamic>{};
                final charIn = data['input'] ?? 0;
                final charOut = data['output'] ?? 0;
                return Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Row(
                    children: [
                      Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                              color: cs.primary,
                              borderRadius: BorderRadius.circular(2))),
                      const SizedBox(width: 10),
                      Expanded(
                          child: Text(entry.key,
                              style: TextStyle(
                                  fontSize: 13, color: cs.onSurface))),
                      Text('${(charIn + charOut).toStringAsFixed(0)}',
                          style: TextStyle(
                              fontSize: 13,
                              color: cs.onSurfaceVariant,
                              fontFamily: 'monospace')),
                    ],
                  ),
                );
              }),
              const SizedBox(height: 4),
            ],
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(right: 12, bottom: 4),
              child: Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () async {
                    final db = ref.read(databaseServiceProvider);
                    await db.clearTokenUsage();
                    _safeSetState(() => _tokenUsage = db.getTokenUsage());
                    if (mounted) {
                      AppToast.show(context, 'Token 统计已清零',
                          icon: Icons.refresh_rounded);
                    }
                  },
                  icon: Icon(Icons.refresh_rounded, size: 16, color: cs.error),
                  label: Text('清零',
                      style: TextStyle(color: cs.error, fontSize: 12)),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

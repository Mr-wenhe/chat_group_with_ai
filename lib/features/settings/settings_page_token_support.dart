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
        SettingsSectionHeader(title: 'Token 消耗', cs: cs),
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
                  Expanded(
                      child:
                          _statLabel('输入 Token', formatTokenCount(totalInput))),
                  _statValue(formatTokenCount(totalInput), cs),
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
                  Expanded(
                      child: _statLabel(
                          '输出 Token', formatTokenCount(totalOutput))),
                  _statValue(formatTokenCount(totalOutput), cs),
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
                  Expanded(child: _statLabel('请求次数', '$requestCount 次')),
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
                  Expanded(
                      child: _statLabel(
                          '缓存命中 Token', formatTokenCount(totalCachedInput))),
                  _statValue(
                      formatCacheHitPercent(totalCachedInput, totalInput), cs),
                ],
              ),
            ),
            Divider(height: 1, color: cs.outlineVariant.withValues(alpha: 0.5)),
            SettingsTile(
              key: const Key('token-usage-detail-entry'),
              cs: cs,
              icon: Icons.table_chart_outlined,
              iconColor: cs.primary,
              title: '消耗明细',
              subtitle: byGroup.isEmpty && byChar.isEmpty
                  ? '暂无按群或按角色的记录'
                  : '按群（${byGroup.length}）与按角色（${byChar.length}）查看',
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => TokenUsageDetailPage(
                    byGroup: byGroup,
                    byCharacter: byChar,
                    groupNameOf: (groupId) =>
                        db.chatGroupBox.get(groupId)?.name ?? groupId,
                  ),
                ),
              ),
            ),
            Divider(height: 1, color: cs.outlineVariant.withValues(alpha: 0.5)),
            Padding(
              padding: const EdgeInsets.only(right: 12, bottom: 4, top: 4),
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

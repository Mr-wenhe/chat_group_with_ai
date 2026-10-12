import 'package:chat_group/core/widgets/app_widgets.dart';
import 'package:chat_group/features/settings/token_count_format.dart';
import 'package:chat_group/features/settings/widgets/settings_section_header.dart';
import 'package:flutter/material.dart';

/// Per-group and per-character token breakdown.
///
/// These lists grow with the number of groups and characters, so they live on
/// their own page; the settings card keeps only the four totals.
class TokenUsageDetailPage extends StatelessWidget {
  final Map<String, dynamic> byGroup;
  final Map<String, dynamic> byCharacter;
  final String Function(String groupId) groupNameOf;

  const TokenUsageDetailPage({
    super.key,
    required this.byGroup,
    required this.byCharacter,
    required this.groupNameOf,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hasAny = byGroup.isNotEmpty || byCharacter.isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('消耗明细')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 48),
        children: [
          if (!hasAny)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                '暂无消耗记录。',
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
              ),
            ),
          if (byGroup.isNotEmpty) ...[
            SettingsSectionHeader(title: '各群消耗', cs: cs),
            const SizedBox(height: 12),
            AppCard(
              key: const Key('token-usage-by-group'),
              cs: cs,
              margin: EdgeInsets.zero,
              children: [
                for (final entry in byGroup.entries)
                  _groupRow(entry.key, entry.value, cs),
              ],
            ),
          ],
          if (byGroup.isNotEmpty && byCharacter.isNotEmpty)
            const SizedBox(height: 28),
          if (byCharacter.isNotEmpty) ...[
            SettingsSectionHeader(title: '各角色消耗', cs: cs),
            const SizedBox(height: 12),
            AppCard(
              key: const Key('token-usage-by-character'),
              cs: cs,
              margin: EdgeInsets.zero,
              children: [
                for (final entry in byCharacter.entries)
                  _characterRow(entry.key, entry.value, cs),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _groupRow(String groupId, Object? raw, ColorScheme cs) {
    final data =
        raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
    final input = _asInt(data['input']);
    final output = _asInt(data['output']);
    final cached = _asInt(data['cached']);
    final count = _asInt(data['count']);
    return _detailRow(
      cs: cs,
      swatchColor: cs.secondary,
      title: groupNameOf(groupId),
      subtitle: '$count 次 · 缓存 ${formatCacheHitPercent(cached, input)}',
      total: input + output,
    );
  }

  Widget _characterRow(String characterId, Object? raw, ColorScheme cs) {
    final data =
        raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
    final input = _asInt(data['input']);
    final output = _asInt(data['output']);
    return _detailRow(
      cs: cs,
      swatchColor: cs.primary,
      title: characterId,
      total: input + output,
    );
  }

  Widget _detailRow({
    required ColorScheme cs,
    required Color swatchColor,
    required String title,
    required int total,
    String? subtitle,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                  color: swatchColor, borderRadius: BorderRadius.circular(2))),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: cs.onSurface)),
                if (subtitle != null)
                  Text(subtitle,
                      style:
                          TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(formatTokenCount(total),
              style: TextStyle(
                  fontSize: 13,
                  color: cs.onSurfaceVariant,
                  fontFamily: 'monospace')),
        ],
      ),
    );
  }

  /// The usage map is persisted JSON, so its numbers arrive as `num` and may be
  /// absent on older entries.
  int _asInt(Object? value) => value is num ? value.toInt() : 0;
}

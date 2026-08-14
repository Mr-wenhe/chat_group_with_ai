import 'package:chat_group/core/models/permanent_memory.dart';
import 'package:chat_group/features/memory/memory_audit_presenter.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// One compact record row in the memory browser.
///
/// Details and mutation controls deliberately live behind later routes; the
/// main browser only exposes the information needed for scanning.
class MemoryAuditCard extends StatelessWidget {
  final MemoryAuditRow displayRow;
  final bool showObserver;
  final ValueChanged<String> onOpenDetails;

  const MemoryAuditCard({
    super.key,
    required this.displayRow,
    required this.showObserver,
    required this.onOpenDetails,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final statusColor = switch (displayRow.statusValue) {
      MemoryStatus.active => Colors.green,
      MemoryStatus.superseded => Colors.orange,
      MemoryStatus.invalidated => cs.error,
    };
    final subject = displayRow.subjectNames.isEmpty
        ? (displayRow.kind.label == '自身成长' ? '自身成长' : '未指定对象')
        : displayRow.subjectNames.join('、');

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  displayRow.content,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 10,
                  runSpacing: 4,
                  children: [
                    if (showObserver)
                      _ObserverMetadataItem(
                        label: '观察 AI',
                        value: displayRow.observerName,
                        avatar: displayRow.observerAvatar,
                      ),
                    _MetadataItem(label: '对象', value: subject),
                    _MetadataItem(
                      label: '类型',
                      value: displayRow.kind.label,
                      badge: true,
                    ),
                    _MetadataItem(
                      label: '状态',
                      value: displayRow.status.label,
                      valueColor: statusColor,
                      badge: true,
                    ),
                    _MetadataItem(
                      label: '来源',
                      value:
                          '${displayRow.originType.label} · ${displayRow.originName}',
                    ),
                    _MetadataItem(
                      label: '日期',
                      value: _date(displayRow.occurredAt),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Semantics(
            button: true,
            label: '查看记忆详情',
            child: IconButton(
              key: ValueKey('memory-details-${displayRow.memoryId}'),
              tooltip: '查看详情',
              onPressed: () => onOpenDetails(displayRow.memoryId),
              icon: const Icon(Icons.chevron_right_rounded),
            ),
          ),
        ],
      ),
    );
  }

  String _date(DateTime value) =>
      DateFormat('yyyy-MM-dd').format(value.toLocal());
}

class _MetadataItem extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;
  final bool badge;

  const _MetadataItem({
    required this.label,
    required this.value,
    this.valueColor,
    this.badge = false,
  });

  @override
  Widget build(BuildContext context) {
    final secondary = Theme.of(context).colorScheme.onSurfaceVariant;
    final content = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 220),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$label · ',
              style: TextStyle(color: secondary, fontSize: 12),
            ),
            TextSpan(
              text: value,
              style: TextStyle(
                color: valueColor ?? secondary,
                fontSize: 12,
                fontWeight: badge ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
    if (!badge) return content;
    final background = valueColor?.withValues(alpha: .12) ??
        Theme.of(context).colorScheme.surfaceContainerHighest;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: content,
      ),
    );
  }
}

class _ObserverMetadataItem extends StatelessWidget {
  final String label;
  final String value;
  final String avatar;

  const _ObserverMetadataItem({
    required this.label,
    required this.value,
    required this.avatar,
  });

  @override
  Widget build(BuildContext context) {
    final fallback = value.trim().isEmpty ? 'AI' : value.characters.first;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 180),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            key: const ValueKey('memory-row-observer-avatar'),
            radius: 10,
            child: Text(
              avatar.trim().isEmpty ? fallback : avatar.trim(),
              maxLines: 1,
              overflow: TextOverflow.clip,
              style: const TextStyle(fontSize: 10),
            ),
          ),
          const SizedBox(width: 4),
          Flexible(child: _MetadataItem(label: label, value: value)),
        ],
      ),
    );
  }
}

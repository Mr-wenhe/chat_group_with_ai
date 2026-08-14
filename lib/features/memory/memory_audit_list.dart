import 'package:chat_group/features/memory/memory_audit_card.dart';
import 'package:chat_group/features/memory/memory_audit_presenter.dart';
import 'package:flutter/material.dart';

class MemorySectionHeading extends StatelessWidget {
  final String title;
  final int count;

  const MemorySectionHeading({
    super.key,
    required this.title,
    required this.count,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
      child: Row(
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(width: 8),
          Text(
            '$count',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class MemoryAuditSliverList extends StatelessWidget {
  final String surfaceKey;
  final List<MemoryAuditRow> rows;
  final bool showObserver;
  final ValueChanged<String> onOpenDetails;

  const MemoryAuditSliverList({
    super.key,
    required this.surfaceKey,
    required this.rows,
    required this.showObserver,
    required this.onOpenDetails,
  });

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      key: ValueKey('memory-$surfaceKey-surface'),
      padding: const EdgeInsets.symmetric(horizontal: 20),
      sliver: SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) => _MemoryAuditRowSurface(
            row: rows[index],
            index: index,
            rowCount: rows.length,
            showObserver: showObserver,
            onOpenDetails: onOpenDetails,
          ),
          childCount: rows.length,
        ),
      ),
    );
  }
}

class MemoryHistorySurface extends StatelessWidget {
  final List<MemoryAuditRow> rows;
  final bool expanded;
  final VoidCallback onToggle;

  const MemoryHistorySurface({
    super.key,
    required this.rows,
    required this.expanded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('memory-history-surface'),
      margin: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        border: Border.all(color: cs.outlineVariant),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ListTile(
          key: const ValueKey('memory-history-section'),
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          title: Text('历史记录（${rows.length}）'),
          subtitle: const Text('已取代或失效的记忆，仅供浏览'),
          trailing: Icon(
            expanded
                ? Icons.keyboard_arrow_up_rounded
                : Icons.keyboard_arrow_down_rounded,
          ),
          onTap: onToggle,
        ),
      ),
    );
  }
}

class _MemoryAuditRowSurface extends StatelessWidget {
  final MemoryAuditRow row;
  final int index;
  final int rowCount;
  final bool showObserver;
  final ValueChanged<String> onOpenDetails;

  const _MemoryAuditRowSurface({
    required this.row,
    required this.index,
    required this.rowCount,
    required this.showObserver,
    required this.onOpenDetails,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final edge = BorderSide(color: cs.outlineVariant);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        border: Border(
          left: edge,
          right: edge,
          top: index == 0 ? edge : BorderSide.none,
          bottom: index == rowCount - 1 ? edge : BorderSide.none,
        ),
      ),
      child: Column(
        children: [
          MemoryAuditCard(
            key: ValueKey('memory-row-${row.memoryId}'),
            displayRow: row,
            showObserver: showObserver,
            onOpenDetails: onOpenDetails,
          ),
          if (index < rowCount - 1)
            Divider(
              height: 1,
              indent: 20,
              endIndent: 20,
              color: cs.outlineVariant,
            ),
        ],
      ),
    );
  }
}

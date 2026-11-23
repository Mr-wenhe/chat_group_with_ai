part of 'doudizhu_table_view.dart';

class _Settlement extends StatelessWidget {
  const _Settlement({required this.snapshot});

  final DoudizhuTableSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final landlordWon =
        snapshot.scores.isNotEmpty && snapshot.scores[snapshot.landlord] > 0;
    return Card(
      color: colors.primaryContainer.withValues(alpha: 0.5),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          children: [
            Icon(
              landlordWon ? Icons.emoji_events_rounded : Icons.groups_rounded,
              size: 28,
              color: colors.primary,
            ),
            const SizedBox(height: 6),
            Text(
              '${landlordWon ? '地主' : '农民'}获胜 · 倍数 ×${snapshot.multiplier}',
              style: TextStyle(
                color: colors.onSurface,
                fontWeight: FontWeight.w800,
                fontSize: 15,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '结算：${snapshot.scores.join(' / ')}（按席位顺序）',
              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

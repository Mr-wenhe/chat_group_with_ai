part of 'doudizhu_table_view.dart';

/// 操作按钮组：叫分阶段的"不叫/1/2/3 分"，或出牌阶段的
/// "提示/重置选牌/不出/出牌"。抽出为独立组件，便于宽屏时嵌入牌桌手牌上方。
/// 所有对外 key 与回调保持不变。
class _ActionControls extends StatelessWidget {
  const _ActionControls({
    required this.snapshot,
    required this.ownHand,
    required this.selectedCardIds,
    required this.humanTurn,
    required this.playEnabled,
    required this.canPass,
    required this.onBid,
    required this.onPlay,
    required this.onPass,
    required this.onHint,
    required this.onClearSelection,
  });

  final DoudizhuTableSnapshot snapshot;
  final List<int> ownHand;
  final Set<int> selectedCardIds;
  final bool humanTurn;
  final bool playEnabled;
  final bool canPass;
  final ValueChanged<int> onBid;
  final ValueChanged<List<int>> onPlay;
  final VoidCallback onPass;
  final VoidCallback onHint;
  final VoidCallback onClearSelection;

  @override
  Widget build(BuildContext context) {
    if (snapshot.phase == DoudizhuPhase.bidding) {
      return _BidControls(
        enabled: humanTurn,
        highestBid: snapshot.highestBid,
        onBid: onBid,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                key: const ValueKey<String>('doudizhu-hint'),
                onPressed: humanTurn ? onHint : null,
                icon: const Icon(Icons.lightbulb_outline_rounded),
                label: const Text('提示'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextButton.icon(
                key: const ValueKey<String>('doudizhu-clear'),
                onPressed: humanTurn && selectedCardIds.isNotEmpty
                    ? onClearSelection
                    : null,
                icon: const Icon(Icons.restart_alt_rounded),
                label: const Text('重置选牌'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                key: const ValueKey<String>('doudizhu-pass'),
                onPressed: canPass ? onPass : null,
                icon: const Icon(Icons.skip_next_rounded),
                label: const Text('不出'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.icon(
                key: const ValueKey<String>('doudizhu-play'),
                onPressed: playEnabled
                    ? () => onPlay(
                          ownHand.where(selectedCardIds.contains).toList(),
                        )
                    : null,
                icon: const Icon(Icons.play_arrow_rounded),
                label: Text(
                  selectedCardIds.isEmpty
                      ? '出牌'
                      : '出牌 (${selectedCardIds.length})',
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _BidControls extends StatelessWidget {
  const _BidControls({
    required this.enabled,
    required this.highestBid,
    required this.onBid,
  });

  final bool enabled;
  final int highestBid;
  final ValueChanged<int> onBid;

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: 8,
        children: [
          OutlinedButton(
              onPressed: enabled ? () => onBid(0) : null,
              child: const Text('不叫')),
          for (var score = 1; score <= 3; score++)
            FilledButton.tonal(
              onPressed:
                  enabled && score > highestBid ? () => onBid(score) : null,
              child: Text('$score 分'),
            ),
        ],
      );
}

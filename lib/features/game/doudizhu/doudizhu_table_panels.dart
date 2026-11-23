part of 'doudizhu_table_view.dart';

/// 记牌器：参考主流斗地主（欢乐斗地主 / 通用记牌器）的"点数墙"样式。
///
/// 关键修复：不再用 [Card]——全局 CardTheme 是浅色 surface，套深绿主题时
/// Card 仍取浅底，而文字取浅色 onSurface，导致浅底浅字看不清。这里用显式
/// 深绿渐变容器 + 金边，配色完全自持，宽屏牌桌 slot 与窄屏面板都通用。
class _CardCounter extends StatelessWidget {
  const _CardCounter({required this.playedCounts, required this.ownHand});

  // 记牌器专用配色（深绿毡布主题，显式指定，不依赖外部 CardTheme）。
  static const _surface = Color(0xff0d3c29);
  static const _surfaceLow = Color(0xff08291d);
  static const _surfaceHigh = Color(0xff1a5b40);
  static const _gold = Color(0xffffd877);
  static const _ink = Color(0xfff2f7f2);
  static const _inkSoft = Color(0xa8ffffff);

  final List<int> playedCounts;
  final List<int> ownHand;

  @override
  Widget build(BuildContext context) {
    final ownCounts = List<int>.filled(doudizhuRankCount, 0);
    for (final card in ownHand) {
      ownCounts[DoudizhuRules.rankOf(card)]++;
    }
    final outsideCounts = List<int>.generate(doudizhuRankCount, (rank) {
      final played = rank < playedCounts.length ? playedCounts[rank] : 0;
      return (doudizhuTotalOfRank[rank] - played - ownCounts[rank])
          .clamp(0, doudizhuTotalOfRank[rank]);
    });
    // 常驻的一行横条：15 个点数从左到右单排横列，没有标题/摘要行，
    // 也不需要点开；只有真的放不下时才横向滚动（窄屏信息面板内）。
    return Container(
      key: const ValueKey<String>('doudizhu-card-counter'),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [_surface, _surfaceLow],
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _gold.withValues(alpha: 0.35), width: 1),
        boxShadow: const [
          BoxShadow(
              color: Color(0x44000000), blurRadius: 6, offset: Offset(0, 2)),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(builder: (context, box) {
        const gap = 4.0;
        // 空间够就把 15 个格子均摊铺满整行（牌桌里就是这个分支），
        // 不够才退化成横向滚动，保证"一行横条"在任何宽度下都成立。
        const neededWidth =
            doudizhuRankCount * _cellWidth + (doudizhuRankCount - 1) * gap;
        final spread = box.maxWidth >= neededWidth;
        return SingleChildScrollView(
          key: const PageStorageKey<String>('doudizhu-counter-grid-scroll'),
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: box.maxWidth),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: spread
                  ? MainAxisAlignment.spaceBetween
                  : MainAxisAlignment.start,
              children: [
                for (var rank = 0; rank < doudizhuRankCount; rank++) ...[
                  if (rank > 0) const SizedBox(width: gap),
                  _counterCell(rank, outsideCounts[rank]),
                ],
              ],
            ),
          ),
        );
      }),
    );
  }

  /// 单个点数格的宽度，够放两字点数（"小王"/"大王"）与两位数张数。
  static const double _cellWidth = 30;

  /// 一行横条里的单个点数格：上方点数名、下方大号剩余张数。
  /// 大牌金色高亮、大小王红蓝区分、断张置灰+删除线、满 4 张橙框预警炸弹。
  Widget _counterCell(int rank, int remaining) {
    final bigRank = rank >= 11; // A / 2 / 小王 / 大王
    final joker = rank >= 13;
    final dead = remaining == 0;
    final bombRisk = remaining == 4;
    final Color rankColor = dead
        ? _inkSoft.withValues(alpha: 0.45)
        : joker
            ? (rank == 14 ? const Color(0xffff8a7a) : const Color(0xff7fb3ff))
            : bigRank
                ? _gold
                : _inkSoft.withValues(alpha: 0.82);
    final Color countColor = dead
        ? _inkSoft.withValues(alpha: 0.35)
        : bombRisk
            ? const Color(0xffffa726)
            : bigRank
                ? _gold
                : _ink;
    return Container(
      key: ValueKey<String>('doudizhu-counter-rank-$rank'),
      width: _cellWidth,
      padding: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        gradient: dead
            ? null
            : LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors:
                    bigRank ? [_surfaceHigh, _surface] : [_surface, _surfaceLow],
              ),
        color: dead ? const Color(0xff052018) : null,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(
          color: dead
              ? const Color(0x1affffff)
              : bombRisk
                  ? const Color(0xd9ffa726)
                  : bigRank
                      ? _gold.withValues(alpha: 0.5)
                      : const Color(0x24ffffff),
          width: bombRisk || bigRank ? 1.2 : 0.8,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            doudizhuRankNames[rank],
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: rankColor,
              fontSize: 9,
              height: 1.1,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 1),
          Text(
            '$remaining',
            style: TextStyle(
              color: countColor,
              fontSize: 15,
              height: 1.05,
              fontWeight: FontWeight.w900,
              decoration: dead ? TextDecoration.lineThrough : null,
              decorationColor: countColor,
              decorationThickness: 1.6,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.snapshot});

  final DoudizhuTableSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final phase = switch (snapshot.phase) {
      DoudizhuPhase.bidding => '叫分阶段',
      DoudizhuPhase.playing => '出牌阶段',
      DoudizhuPhase.over => '本局结算',
    };
    final turn = snapshot.phase == DoudizhuPhase.bidding
        ? snapshot.bidTurn
        : snapshot.seats.indexWhere((seat) => seat.isCurrent);
    final currentName = turn >= 0 ? snapshot.seats[turn].name : '—';
    final landlordName =
        snapshot.landlord < 0 ? '待定' : snapshot.seats[snapshot.landlord].name;
    final target = snapshot.trick == null
        ? (snapshot.phase == DoudizhuPhase.playing ? '当前无待压牌 · 领出权' : '等待叫分结果')
        : '待压：${snapshot.trick!.move.type.label} '
            '${DoudizhuRules.cardsLabel(snapshot.trick!.move.cardIds)} · '
            '${snapshot.passCount} 家已过';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            colors.primaryContainer.withValues(alpha: 0.6),
            colors.surfaceContainerLow,
          ],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.primary.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: colors.primary,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  phase,
                  style: TextStyle(
                    color: colors.onPrimary,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '轮到：$currentName',
                  style: TextStyle(
                    color: colors.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: colors.tertiaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '×${snapshot.multiplier}',
                  style: TextStyle(
                    color: colors.onTertiaryContainer,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '地主：$landlordName  ·  ${snapshot.statusMessage}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
          ),
          const SizedBox(height: 4),
          Text(target, style: TextStyle(color: colors.onSurface, fontSize: 13)),
        ],
      ),
    );
  }
}

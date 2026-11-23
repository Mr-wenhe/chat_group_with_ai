/// 斗地主牌桌表面：毡布、三家座位牌堆、底牌、出牌区与中央提示。
///
/// 只消费 [DoudizhuTableSnapshot] 的只读投影，不触碰对局状态；
/// [DoudizhuViewMode.participant] 与 [DoudizhuViewMode.god] 两种视角都在此渲染。
library;

import 'package:flutter/material.dart';

import 'doudizhu_bomb_animation.dart';
import 'doudizhu_card_widgets.dart';
import 'doudizhu_game_director.dart';
import 'doudizhu_game_state.dart';

const Color _feltLight = Color(0xff1f8a5b);
const Color _feltMid = Color(0xff126040);
const Color _feltDark = Color(0xff083c29);
const Color _woodLight = Color(0xffb5814b);
const Color _woodDark = Color(0xff6b4524);
const Color _gold = Color(0xffffd877);

class DoudizhuFeltTable extends StatelessWidget {
  const DoudizhuFeltTable({
    super.key,
    required this.snapshot,
    this.humanHandSlot,
    this.actionControlsSlot,
    this.cardCounterSlot,
  });

  final DoudizhuTableSnapshot snapshot;

  /// 宽屏第一视角下嵌入牌桌内部的三个 slot（由 [DoudizhuTableView] 注入）：
  /// 手牌放在原真人座位卡位置、按钮置于手牌上方、记牌器置于底牌右侧。
  /// 三者同时非空才启用嵌入式布局；上帝视角 / 窄屏不传，走原有布局。
  final Widget? humanHandSlot;
  final Widget? actionControlsSlot;
  final Widget? cardCounterSlot;

  @override
  Widget build(BuildContext context) {
    final bottom = snapshot.mode == DoudizhuViewMode.participant
        ? snapshot.seats.firstWhere((seat) => seat.isHuman)
        : snapshot.seats.first;
    final left = snapshot.seats[(bottom.index + 1) % 3];
    final right = snapshot.seats[(bottom.index + 2) % 3];
    final revealHands = snapshot.mode == DoudizhuViewMode.god;
    final trickActions = doudizhuCurrentTrickActions(snapshot);

    DoudizhuPublicEvent? actionForSeat(int seat) {
      for (final event in trickActions.reversed) {
        if (event.seat == seat) return event;
      }
      return null;
    }

    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [_woodLight, _woodDark, _woodLight],
        ),
        borderRadius: BorderRadius.circular(26),
        boxShadow: const [
          BoxShadow(
            color: Color(0x6b000000),
            blurRadius: 24,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Container(
          decoration: BoxDecoration(
            gradient: const RadialGradient(
              center: Alignment(0, -0.1),
              radius: 1.05,
              colors: [_feltLight, _feltMid, _feltDark],
            ),
            borderRadius: BorderRadius.circular(21),
            border: Border.all(color: const Color(0x66ffffff), width: 1),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            children: [
              // 毡布纹路作为最底层装饰，布局层是纯 Column，不再各自画背景。
              const Positioned.fill(
                  child: CustomPaint(painter: _FeltMarkings())),
              Positioned.fill(
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: LayoutBuilder(builder: (context, constraints) {
                    // 第一视角内嵌布局自带响应式（左右座位宽度随可用宽度收缩），
                    // 不再与 700 的品字形门槛耦合：否则 760 左右的窗口内宽约
                    // 696，会掉进 narrow 分支把手牌 / 按钮 / 记牌器三个 slot 全丢掉。
                    if (humanHandSlot != null) {
                      return _buildWide(
                        constraints: constraints,
                        bottom: bottom,
                        left: left,
                        right: right,
                        revealHands: revealHands,
                        actionForSeat: actionForSeat,
                      );
                    }
                    final narrow = constraints.maxWidth < 700;
                    if (narrow) {
                      return _buildNarrow(
                        bottom: bottom,
                        left: left,
                        right: right,
                        revealHands: revealHands,
                        actionForSeat: actionForSeat,
                      );
                    }
                    return _buildWide(
                      constraints: constraints,
                      bottom: bottom,
                      left: left,
                      right: right,
                      revealHands: revealHands,
                      actionForSeat: actionForSeat,
                    );
                  }),
                ),
              ),
              // 炸弹/火箭一次性动画覆盖在毡布之上，IgnorePointer 不挡选牌手势。
              DoudizhuBombAnimation(
                trick: snapshot.trick,
                events: snapshot.events,
                dealNumber: snapshot.dealNumber,
                multiplier: snapshot.multiplier,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _seat(int index, DoudizhuSeatSnapshot seat, bool reveal) =>
      DoudizhuSeatCard(seat: seat, revealHand: reveal, seatOrder: index);

  Widget _action(int seat, DoudizhuPublicEvent? event) =>
      DoudizhuPlayedAction(event: event, isSelf: seat == bottomSeatIndex);

  int get bottomSeatIndex => snapshot.seats
      .firstWhere(
        (seat) => seat.isHuman || snapshot.mode == DoudizhuViewMode.god,
        orElse: () => snapshot.seats.first,
      )
      .index;

  /// 一家座位 + 紧跟其下的出牌区，作为一个视觉单元，牌不会找不到主人。
  Widget _seatWithAction(
    int index,
    DoudizhuSeatSnapshot seat,
    bool reveal,
    DoudizhuPublicEvent? action,
  ) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _seat(index, seat, reveal),
        if (action != null) ...[
          const SizedBox(height: 6),
          _action(seat.index, action),
        ],
      ],
    );
  }

  Widget _buildNarrow({
    required DoudizhuSeatSnapshot bottom,
    required DoudizhuSeatSnapshot left,
    required DoudizhuSeatSnapshot right,
    required bool revealHands,
    required DoudizhuPublicEvent? Function(int) actionForSeat,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 顶排：左右对手各占一半，出牌紧跟各自座位。
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _seatWithAction(
                  0, left, revealHands, actionForSeat(left.index)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _seatWithAction(
                  1, right, revealHands, actionForSeat(right.index)),
            ),
          ],
        ),
        const SizedBox(height: 10),
        // 底牌 + 中央提示同一行，居中。
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (snapshot.bottomCards != null)
                    DoudizhuBottomCards(cards: snapshot.bottomCards!),
                  DoudizhuTableCenter(snapshot: snapshot),
                ],
              ),
            ),
          ],
        ),
        const Spacer(),
        // 真人座位 + 出牌，居中收底。
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: _seatWithAction(
                2, bottom, revealHands, actionForSeat(bottom.index)),
          ),
        ),
      ],
    );
  }

  Widget _buildWide({
    required BoxConstraints constraints,
    required DoudizhuSeatSnapshot bottom,
    required DoudizhuSeatSnapshot left,
    required DoudizhuSeatSnapshot right,
    required bool revealHands,
    required DoudizhuPublicEvent? Function(int) actionForSeat,
  }) {
    // 用确定性的 Row/Column 分层，替代百分比硬定位：
    // 顶排 = 左座位 + 底牌 + 右座位；中部 = 中央提示；底排 = 真人座位。
    // 每家座位卡内容自适应宽度，出牌紧跟座位，不再出现空心横条与飘移出牌。
    // 左右座位随窗口收缩：窄一些也要给底牌 / 记牌器留出横向空间。
    final sideWidth = constraints.maxWidth >= 900 ? 250.0 : 200.0;

    // ── 第一视角（注入 slot）：底牌左移、记牌器在其右侧，中部为中央提示
    // 与真人出牌，底部依次是按钮与手牌；真人座位卡移除（手牌即代表自己）。
    if (humanHandSlot != null) {
      final humanAction = actionForSeat(bottom.index);
      // 极宽时把记牌器并到顶排（底牌右侧）；一般桌面宽度下记牌器独占
      // 一行铺满整桌——15 个点数只有铺开才不会退化成横向滚动条。
      final inlineCounter = constraints.maxWidth >= 1000;
      final counter = cardCounterSlot;

      final content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: sideWidth,
                child: _seatWithAction(
                    0, left, revealHands, actionForSeat(left.index)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (snapshot.bottomCards != null)
                      DoudizhuBottomCards(cards: snapshot.bottomCards!),
                    if (inlineCounter && counter != null) ...[
                      const SizedBox(width: 10),
                      Expanded(child: counter),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: sideWidth,
                child: _seatWithAction(
                    1, right, revealHands, actionForSeat(right.index)),
              ),
            ],
          ),
          if (!inlineCounter && counter != null) ...[
            const SizedBox(height: 8),
            counter,
          ],
          // 中部：中央提示 + 真人本墩出牌。放在 Flex 里而不是两侧 Spacer——
          // 出牌/叫分时上下都会长高，硬 Spacer 会把内容顶出牌桌变成黄黑溢出条；
          // 这里空间不够时中段自己内部滚动，按钮和手牌始终留在可见区。
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 460),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      DoudizhuTableCenter(snapshot: snapshot),
                      if (humanAction != null) ...[
                        const SizedBox(height: 6),
                        _action(bottom.index, humanAction),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
          // 底部：按钮在手牌正上方，手牌占据原真人座位卡的位置。
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (actionControlsSlot != null) actionControlsSlot!,
                  const SizedBox(height: 8),
                  humanHandSlot!,
                ],
              ),
            ),
          ),
        ],
      );

      // 窗口被压得很矮时内容必然溢出，退化成可滚动，不给用户看黄黑报警条。
      return LayoutBuilder(builder: (context, box) {
        if (box.maxHeight >= 470) return content;
        return SingleChildScrollView(
          child: SizedBox(height: 470, child: content),
        );
      });
    }

    // ── 上帝视角 / 未注入 slot：保持原品字形布局。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: sideWidth,
              child: _seatWithAction(
                  0, left, revealHands, actionForSeat(left.index)),
            ),
            const Spacer(),
            if (snapshot.bottomCards != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: DoudizhuBottomCards(cards: snapshot.bottomCards!),
              ),
            const Spacer(),
            SizedBox(
              width: sideWidth,
              child: _seatWithAction(
                  1, right, revealHands, actionForSeat(right.index)),
            ),
          ],
        ),
        // 中央提示居中，与上下座位围成品字形，符合真实牌桌围坐感。
        const Spacer(),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 340),
            child: DoudizhuTableCenter(snapshot: snapshot),
          ),
        ),
        const Spacer(),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: _seatWithAction(
                2, bottom, revealHands, actionForSeat(bottom.index)),
          ),
        ),
      ],
    );
  }
}

class _FeltMarkings extends CustomPainter {
  const _FeltMarkings();

  @override
  void paint(Canvas canvas, Size size) {
    // 椭圆装饰居中，作为中央出牌区的衬垫。
    final center = Offset(size.width / 2, size.height * 0.52);
    final soft = Paint()
      ..color = Colors.white.withValues(alpha: 0.07)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    canvas.drawOval(
      Rect.fromCenter(
        center: center,
        width: size.width * 0.46,
        height: size.height * 0.3,
      ),
      soft,
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: center,
        width: size.width * 0.38,
        height: size.height * 0.22,
      ),
      soft,
    );
    final glow = Paint()
      ..color = _gold.withValues(alpha: 0.045)
      ..style = PaintingStyle.fill;
    canvas.drawOval(
      Rect.fromCenter(
        center: center,
        width: size.width * 0.32,
        height: size.height * 0.18,
      ),
      glow,
    );
    // 缝线：沿内圈画短虚线，模拟包边针脚。
    final stitch = Paint()
      ..color = Colors.white.withValues(alpha: 0.18)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final rect = Rect.fromLTWH(9, 9, size.width - 18, size.height - 18);
    const dash = 6.0;
    const gap = 5.0;
    for (var x = rect.left; x < rect.right; x += dash + gap) {
      canvas.drawLine(
        Offset(x, rect.top),
        Offset((x + dash).clamp(x, rect.right), rect.top),
        stitch,
      );
      canvas.drawLine(
        Offset(x, rect.bottom),
        Offset((x + dash).clamp(x, rect.right), rect.bottom),
        stitch,
      );
    }
    for (var y = rect.top; y < rect.bottom; y += dash + gap) {
      canvas.drawLine(
        Offset(rect.left, y),
        Offset(rect.left, (y + dash).clamp(y, rect.bottom)),
        stitch,
      );
      canvas.drawLine(
        Offset(rect.right, y),
        Offset(rect.right, (y + dash).clamp(y, rect.bottom)),
        stitch,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _FeltMarkings oldDelegate) => false;
}

/// 单个座位：头像、身份、叫分、牌背堆；上帝视角下展开手牌。
class DoudizhuSeatCard extends StatelessWidget {
  const DoudizhuSeatCard({
    super.key,
    required this.seat,
    required this.revealHand,
    required this.seatOrder,
  });

  final DoudizhuSeatSnapshot seat;
  final bool revealHand;
  final int seatOrder;

  @override
  Widget build(BuildContext context) {
    final isLandlord = seat.roleLabel.contains('地主');
    final bidLabel = seat.bid == null
        ? ''
        : seat.bid == 0
            ? ' · 不叫'
            : ' · ${seat.bid}分';
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      padding: const EdgeInsets.fromLTRB(9, 7, 9, 8),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: seat.isCurrent
              ? [const Color(0xff2c6b4e), const Color(0xff123f2e)]
              : [const Color(0xe610251c), const Color(0xe60a1d16)],
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: seat.isCurrent ? _gold : Colors.white.withValues(alpha: 0.22),
          width: seat.isCurrent ? 2 : 0.8,
        ),
        boxShadow: seat.isCurrent
            ? const [BoxShadow(color: Color(0x66ffd877), blurRadius: 14)]
            : const [BoxShadow(color: Color(0x33000000), blurRadius: 4)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Stack(
                alignment: Alignment.bottomRight,
                children: [
                  CircleAvatar(
                    radius: 14,
                    backgroundColor: seat.isCurrent
                        ? _gold
                        : Theme.of(context).colorScheme.secondaryContainer,
                    child: Text(
                      seat.avatar,
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: 12,
                        color: seat.isCurrent ? const Color(0xff263222) : null,
                      ),
                    ),
                  ),
                  if (isLandlord)
                    const Icon(Icons.workspace_premium_rounded,
                        size: 12, color: _gold),
                ],
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      seat.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      '${seat.roleLabel}$bidLabel',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isLandlord ? _gold : Colors.white70,
                        fontSize: 10,
                        fontWeight: isLandlord ? FontWeight.w700 : null,
                      ),
                    ),
                  ],
                ),
              ),
              if (seat.isCurrent)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: _gold.withValues(alpha: 0.22),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    '思考中',
                    style: TextStyle(
                      color: _gold,
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          if (revealHand && seat.visibleHand != null)
            _RevealedHand(cards: seat.visibleHand!)
          else if (!seat.isHuman)
            DoudizhuCardBacks(count: seat.handSize)
          else
            Padding(
              padding: const EdgeInsets.only(left: 2),
              child: Text(
                '${seat.handSize} 张手牌',
                style: const TextStyle(color: Colors.white70, fontSize: 10),
              ),
            ),
        ],
      ),
    );
  }
}

/// 上帝视角明牌：按 rank 分行展示，避免超宽。
class _RevealedHand extends StatelessWidget {
  const _RevealedHand({required this.cards});

  final List<int> cards;

  @override
  Widget build(BuildContext context) {
    if (cards.isEmpty) {
      return const Text('已出完',
          style: TextStyle(color: Colors.white70, fontSize: 10));
    }
    // 明牌随座位卡宽度自动换行，窄屏也不会溢出。
    return Wrap(
      spacing: 1,
      runSpacing: 2,
      children: [
        for (final card in cards)
          DoudizhuPlayingCard(cardId: card, compact: true),
      ],
    );
  }
}

/// 中央信息区：待压牌型 / 领出权 / 倍数 / 已过家数。
class DoudizhuTableCenter extends StatelessWidget {
  const DoudizhuTableCenter({super.key, required this.snapshot});

  final DoudizhuTableSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final trick = snapshot.trick;
    return Container(
      key: const ValueKey<String>('doudizhu-table-center'),
      constraints: const BoxConstraints(minHeight: 52),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xc2082a1d),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _gold.withValues(alpha: 0.35)),
        boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 6)],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.stars_rounded, size: 14, color: _gold),
              const SizedBox(width: 4),
              Text(
                '倍数 ×${snapshot.multiplier}',
                style: const TextStyle(
                  color: _gold,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            trick == null
                ? '当前桌面 · 等待领出'
                : '待压 ${trick.move.type.label} · ${snapshot.passCount} 家已过',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// 取本墩最近一次出牌之后的所有公开出牌 / 不出事件。
List<DoudizhuPublicEvent> doudizhuCurrentTrickActions(
  DoudizhuTableSnapshot snapshot,
) {
  if (snapshot.trick == null) return const [];
  var latestPlayIndex = -1;
  for (var index = snapshot.events.length - 1; index >= 0; index--) {
    final event = snapshot.events[index];
    if (event.dealNumber == snapshot.dealNumber &&
        event.actionKind == DoudizhuLogKind.play) {
      latestPlayIndex = index;
      break;
    }
  }
  if (latestPlayIndex < 0) return const [];
  return List.unmodifiable([
    for (final event in snapshot.events.skip(latestPlayIndex))
      if (event.dealNumber == snapshot.dealNumber &&
          (event.actionKind == DoudizhuLogKind.play ||
              event.actionKind == DoudizhuLogKind.pass))
        event,
  ]);
}

/// 某一家在当前墩打出的牌（或"不出"）。
class DoudizhuPlayedAction extends StatelessWidget {
  const DoudizhuPlayedAction({
    super.key,
    required this.event,
    required this.isSelf,
  });

  final DoudizhuPublicEvent? event;
  final bool isSelf;

  @override
  Widget build(BuildContext context) {
    final current = event;
    if (current == null || current.seat == null) return const SizedBox.shrink();
    final isPass = current.actionKind == DoudizhuLogKind.pass;
    return Padding(
      key: ValueKey<String>('doudizhu-played-action-${current.seat}'),
      padding: const EdgeInsets.only(top: 5),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xd9082a1d),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelf
                ? _gold.withValues(alpha: 0.55)
                : Colors.white.withValues(alpha: 0.22),
          ),
        ),
        child: isPass
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.block_rounded,
                      size: 12, color: Colors.white70),
                  const SizedBox(width: 4),
                  Text(
                    current.message,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${current.message.split(' 出 ').first} · ${current.typeLabel ?? '出牌'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final card in current.cardIds)
                          Padding(
                            padding: const EdgeInsets.only(right: 2),
                            child: DoudizhuPlayingCard(
                              cardId: card,
                              compact: true,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// 顶部底牌展示。
class DoudizhuBottomCards extends StatelessWidget {
  const DoudizhuBottomCards({super.key, required this.cards});

  final List<int> cards;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xa6002117),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _gold.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            '底牌',
            style: TextStyle(
              color: _gold,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 6),
          for (final card in cards) ...[
            DoudizhuPlayingCard(cardId: card, compact: true),
            const SizedBox(width: 3),
          ],
        ],
      ),
    );
  }
}

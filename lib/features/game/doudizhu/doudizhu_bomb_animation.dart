import 'package:flutter/material.dart';

import 'doudizhu_game_director.dart';
import 'doudizhu_game_state.dart';
import 'doudizhu_rules.dart';

/// 炸弹 / 火箭出牌时的一次性庆祝动画。
///
/// 设计要点：
/// - **与出牌节奏解耦**：动画时长自持（约 1.1s），不依赖 moveSpacing，
///   即使节奏调快也能完整播放，不会被下一手立刻冲掉。
/// - **只触发一次**：用最后一个炸弹类事件的[对象引用]做唯一标识；同一事件
///   引起的多次 rebuild 不会重复播放。首帧 initialized 时不补播历史炸弹。
/// - **不挡手势**：整个 overlay 包在 [IgnorePointer] 内，选牌 / 拖拽不受影响。
/// - **换副牌重置**：[dealNumber] 变化时清空标识，允许新一局的炸弹再次触发。
class DoudizhuBombAnimation extends StatefulWidget {
  const DoudizhuBombAnimation({
    super.key,
    required this.trick,
    required this.events,
    required this.dealNumber,
    required this.multiplier,
  });

  final DoudizhuTrick? trick;
  final List<DoudizhuPublicEvent> events;
  final int dealNumber;
  final int multiplier;

  @override
  State<DoudizhuBombAnimation> createState() => _DoudizhuBombAnimationState();
}

class _DoudizhuBombAnimationState extends State<DoudizhuBombAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late Animation<double> _scale;
  late Animation<double> _opacity;
  late Animation<double> _rotation;

  /// 上一次已经播放过的炸弹事件引用；null 表示当前无炸弹在展示。
  DoudizhuPublicEvent? _playedEvent;
  int? _seenDealNumber;
  String? _seatName;
  bool _isRocket = false;

  /// 从事件序列里找最后一个"炸弹 / 火箭"出牌事件。
  ///
  /// 优先用事件的 typeLabel 识别（叫分/出牌事件都会带），再以 cardIds 兜底：
  /// 4 张同点 = 炸弹，双王 = 火箭。这样即使 marker 文案被改也能识别。
  DoudizhuPublicEvent? _latestBombEvent() {
    for (var index = widget.events.length - 1; index >= 0; index--) {
      final event = widget.events[index];
      if (event.dealNumber != widget.dealNumber) continue;
      if (event.actionKind != DoudizhuLogKind.play) continue;
      final label = event.typeLabel ?? '';
      if (label == '炸弹' || label == '火箭') return event;
      final cards = event.cardIds;
      if (cards.length == 4) return event;
      if (cards.length == 2 &&
          cards.every((card) => DoudizhuRules.rankOf(card) >= 13)) {
        return event;
      }
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _seenDealNumber = widget.dealNumber;
    _playedEvent = _latestBombEvent();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );
    _setupAnimations();
  }

  void _setupAnimations() {
    // 前 18% 弹出放大，随后缓慢回落淡出，末段完全透明。
    _scale = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(begin: 0.3, end: 1.18)
            .chain(CurveTween(curve: Curves.easeOutBack)),
        weight: 18,
      ),
      TweenSequenceItem(
        tween: Tween(begin: 1.18, end: 1.0)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 20,
      ),
      TweenSequenceItem(tween: ConstantTween(1.0), weight: 42),
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.92), weight: 20),
    ]).animate(_controller);
    _opacity = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0.0, end: 1.0), weight: 12),
      TweenSequenceItem(tween: ConstantTween(1.0), weight: 62),
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.0), weight: 26),
    ]).animate(_controller);
    _rotation = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(begin: -0.16, end: 0.0)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 30,
      ),
      TweenSequenceItem(tween: ConstantTween(0.0), weight: 70),
    ]).animate(_controller);
  }

  @override
  void didUpdateWidget(covariant DoudizhuBombAnimation oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换副牌：重置标识，避免沿用上一局的事件引用。
    if (widget.dealNumber != _seenDealNumber) {
      _seenDealNumber = widget.dealNumber;
      _playedEvent = null;
      _controller.reset();
    }
    final latest = _latestBombEvent();
    if (latest != null && !identical(latest, _playedEvent)) {
      _playedEvent = latest;
      final label = latest.typeLabel ?? '';
      final cards = latest.cardIds;
      _isRocket = label == '火箭' ||
          (cards.length == 2 &&
              cards.every((card) => DoudizhuRules.rankOf(card) >= 13));
      _seatName = _seatNameFromMessage(latest);
      _controller
        ..reset()
        ..forward();
    }
  }

  /// 从消息里取"XX 出 炸弹"的前缀作为出牌者名字。
  String _seatNameFromMessage(DoudizhuPublicEvent event) {
    final message = event.message;
    final marker = message.indexOf(' 出 ');
    return marker > 0 ? message.substring(0, marker) : message;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            if (!_controller.isAnimating && _controller.isDismissed) {
              return const SizedBox.shrink();
            }
            return Center(
              child: Opacity(
                opacity: _opacity.value,
                child: Transform.scale(
                  scale: _scale.value,
                  child: Transform.rotate(
                    angle: _rotation.value,
                    child: _BombBadge(
                      isRocket: _isRocket,
                      seatName: _seatName,
                      multiplier: widget.multiplier,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 炸弹 / 火箭的视觉主体：发光圆盘 + 大图标 + 出牌者与倍数。
class _BombBadge extends StatelessWidget {
  const _BombBadge({
    required this.isRocket,
    required this.seatName,
    required this.multiplier,
  });

  final bool isRocket;
  final String? seatName;
  final int multiplier;

  @override
  Widget build(BuildContext context) {
    final accent = isRocket ? const Color(0xff64b5f6) : const Color(0xffff8a65);
    final deep = isRocket ? const Color(0xff0d47a1) : const Color(0xff8e1600);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 16),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [accent.withValues(alpha: 0.95), deep.withValues(alpha: 0.9)],
        ),
        boxShadow: [
          BoxShadow(
              color: accent.withValues(alpha: 0.7),
              blurRadius: 40,
              spreadRadius: 6),
          const BoxShadow(
              color: Color(0x99000000), blurRadius: 18, offset: Offset(0, 8)),
        ],
        border:
            Border.all(color: Colors.white.withValues(alpha: 0.8), width: 2),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isRocket
                ? Icons.rocket_launch_rounded
                : Icons.local_fire_department_rounded,
            size: 54,
            color: Colors.white,
          ),
          const SizedBox(height: 2),
          Text(
            isRocket ? '火 箭' : '炸 弹',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 26,
              fontWeight: FontWeight.w900,
              letterSpacing: 4,
              shadows: [Shadow(color: Colors.black54, blurRadius: 6)],
            ),
          ),
          if (seatName != null && seatName!.isNotEmpty)
            Text(
              seatName!,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
            decoration: BoxDecoration(
              color: const Color(0xffffffff).withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              '倍数 ×$multiplier',
              style: TextStyle(
                color: deep,
                fontSize: 14,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

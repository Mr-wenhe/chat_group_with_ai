/// 斗地主扑克牌视觉组件。
///
/// 只负责"把一张牌画好看"和"手牌怎样排布 / 怎样多选"，不含任何规则判断。
/// 牌面配色沿用真实扑克：红桃方块为红、黑桃梅花为墨黑，大小王单独排版。
library;

import 'package:flutter/gestures.dart'
    show kPrimaryMouseButton, PointerDeviceKind, PointerEnterEvent;
import 'package:flutter/material.dart';

import 'doudizhu_rules.dart';

const Color _suitRed = Color(0xffc0392b);
const Color _suitBlack = Color(0xff1f2733);
const Color _jokerRed = Color(0xffc62828);
const Color _jokerBlue = Color(0xff1565c0);
const Color _cardFace = Color(0xfffdfcf8);
const Color _cardEdge = Color(0xffd8d3c7);

/// 单张扑克牌。
///
/// [compact] 用于座位手牌 / 出牌区的缩小版；[selected] 只影响视觉高亮，
/// 选中状态本身由调用方持有（保持无状态，避免与选牌手势的状态打架）。
class DoudizhuPlayingCard extends StatelessWidget {
  const DoudizhuPlayingCard({
    super.key,
    required this.cardId,
    this.compact = false,
    this.selected = false,
  });

  final int cardId;
  final bool compact;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final rank = DoudizhuRules.rankOf(cardId);
    final suit = DoudizhuRules.suitOf(cardId);
    final isJoker = suit < 0;
    final isRed = isJoker ? rank == 14 : suit == 1 || suit == 3;
    final ink = isJoker
        ? (rank == 14 ? _jokerRed : _jokerBlue)
        : (isRed ? _suitRed : _suitBlack);
    final label = DoudizhuRules.cardLabel(cardId);
    final suitSymbol = isJoker ? '★' : doudizhuSuitSymbols[suit];
    final width = compact ? 26.0 : 46.0;
    final height = compact ? 36.0 : 64.0;

    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: _cardFace,
        borderRadius: BorderRadius.circular(compact ? 4 : 7),
        border: Border.all(
          color: selected ? const Color(0xffffc94d) : _cardEdge,
          width: selected ? 2 : 0.8,
        ),
        boxShadow: [
          BoxShadow(
            color: selected ? const Color(0x66ffc94d) : const Color(0x2e000000),
            blurRadius: selected ? 9 : 3,
            offset: Offset(0, selected ? 2 : 1),
          ),
        ],
      ),
      child: Stack(
        children: [
          // 左上角标：点数在上、花色在下，紧凑版只留点数和花色字形。
          Positioned(
            left: compact ? 2 : 4,
            top: compact ? 1.5 : 3,
            child: _CardCorner(
              label: label,
              symbol: suitSymbol,
              color: ink,
              compact: compact,
            ),
          ),
          // 牌面中央的大花色 / 王冠，弱化处理让角标保持第一视觉。
          Positioned.fill(
            child: Center(
              child: isJoker
                  ? Icon(Icons.auto_awesome_rounded,
                      size: compact ? 14 : 26,
                      color: ink.withValues(alpha: 0.55))
                  : Text(
                      suitSymbol,
                      style: TextStyle(
                        color: ink.withValues(alpha: 0.42),
                        fontSize: compact ? 17 : 32,
                        height: 1,
                      ),
                    ),
            ),
          ),
          // 右下角标旋转 180°，符合真实扑克牌面。
          if (!compact)
            Positioned(
              right: 4,
              bottom: 3,
              child: Transform.rotate(
                angle: 3.14159265,
                child: _CardCorner(
                  label: label,
                  symbol: suitSymbol,
                  color: ink,
                  compact: true,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _CardCorner extends StatelessWidget {
  const _CardCorner({
    required this.label,
    required this.symbol,
    required this.color,
    required this.compact,
  });

  final String label;
  final String symbol;
  final Color color;
  final bool compact;

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: compact ? 9 : 15,
              height: 1.05,
              fontWeight: FontWeight.w900,
            ),
          ),
          Text(
            symbol,
            style:
                TextStyle(color: color, fontSize: compact ? 7 : 11, height: 1),
          ),
        ],
      );
}

/// 背面朝上的牌背，用于对手手牌堆。
class DoudizhuCardBack extends StatelessWidget {
  const DoudizhuCardBack({super.key, this.compact = true});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final width = compact ? 20.0 : 34.0;
    final height = compact ? 28.0 : 48.0;
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xff2f5f9e), Color(0xff1c3f72), Color(0xff16325c)],
        ),
        borderRadius: BorderRadius.circular(compact ? 3 : 6),
        border: Border.all(color: const Color(0xffffd98a), width: 0.9),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 2,
            offset: Offset(0, 1),
          ),
        ],
      ),
      child: Center(
        child: Container(
          width: width * 0.5,
          height: height * 0.55,
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0x88ffd98a), width: 0.8),
            borderRadius: BorderRadius.circular(2),
          ),
          child: const Icon(
            Icons.diamond_outlined,
            color: Color(0xaaffd98a),
            size: 11,
          ),
        ),
      ),
    );
  }
}

/// 对手牌背堆：用少量堆叠牌 + 张数表示一整手牌。
class DoudizhuCardBacks extends StatelessWidget {
  const DoudizhuCardBacks({super.key, required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return const SizedBox.shrink();
    final shown = count < 5 ? count : 5;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: shown * 9.0 + 14,
          height: 30,
          child: Stack(
            children: [
              for (var index = 0; index < shown; index++)
                Positioned(
                  left: index * 9.0,
                  child: const DoudizhuCardBack(compact: true),
                ),
            ],
          ),
        ),
        const SizedBox(width: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: const Color(0x66ffffff),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            '$count 张',
            style: const TextStyle(
              color: Color(0xffeaf5ed),
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

/// 真人手牌：扇形重叠排布 + 点击/鼠标拖选。
///
/// 拖拽多选的手势契约必须保持：每张牌带 [ValueKey<int>(cardId)]，
/// 鼠标按下后经过的牌通过 [onSetCardSelected] 批量设置，触屏拖拽不触发多选。
class DoudizhuHumanHand extends StatefulWidget {
  const DoudizhuHumanHand({
    super.key,
    required this.hand,
    required this.selected,
    required this.enabled,
    required this.onToggle,
    required this.onSetSelected,
    this.embedded = false,
  });

  final List<int> hand;
  final Set<int> selected;
  final bool enabled;
  final ValueChanged<int> onToggle;
  final void Function(int cardId, bool selected) onSetSelected;

  /// true 时用深绿毡布 + 木色描边，视觉上作为桌面的下沿延伸；
  /// false 时用 App 主题卡片，供窄屏独立排布。
  final bool embedded;

  @override
  State<DoudizhuHumanHand> createState() => _DoudizhuHumanHandState();
}

class _DoudizhuHumanHandState extends State<DoudizhuHumanHand> {
  static const double _cardWidth = 46;
  // 每张牌的水平步进。越小重叠越多；34 让每张露出 12px，行内对齐更清晰。
  static const double _step = 34;

  final Set<int> _visited = <int>{};
  int? _dragPointer;
  bool _dragSelection = false;
  bool _suppressNextTap = false;

  void _onPointerDown(int cardId, PointerDownEvent event) {
    _suppressNextTap = false;
    if (!widget.enabled ||
        _dragPointer != null ||
        event.kind != PointerDeviceKind.mouse ||
        (event.buttons & kPrimaryMouseButton) == 0) {
      return;
    }
    _suppressNextTap = true;
    _dragPointer = event.pointer;
    _dragSelection = !widget.selected.contains(cardId);
    _visited
      ..clear()
      ..add(cardId);
    widget.onSetSelected(cardId, _dragSelection);
  }

  void _onTap(int cardId) {
    if (!widget.enabled) return;
    if (_suppressNextTap) {
      _suppressNextTap = false;
      return;
    }
    widget.onToggle(cardId);
  }

  void _onPointerEnter(int cardId, PointerEnterEvent event) {
    if (!widget.enabled ||
        event.pointer != _dragPointer ||
        !_visited.add(cardId)) {
      return;
    }
    widget.onSetSelected(cardId, _dragSelection);
  }

  void _finishDrag(PointerEvent event) {
    if (event.pointer != _dragPointer) return;
    _dragPointer = null;
    _visited.clear();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final embedded = widget.embedded;
    final titleColor = embedded ? const Color(0xffffd877) : colors.onSurface;
    final hintColor = embedded
        ? Colors.white.withValues(alpha: 0.55)
        : colors.onSurfaceVariant;
    return Container(
      decoration: BoxDecoration(
        // 嵌入态融入绿毡桌：木色描边 + 深绿半透明底；独立态用主题卡片。
        gradient: embedded
            ? const LinearGradient(
                colors: [Color(0xff11543a), Color(0xff0a3c2a)],
              )
            : null,
        color: embedded
            ? null
            : colors.surfaceContainerLowest.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(embedded ? 16 : 18),
        border: Border.all(
          color: embedded
              ? const Color(0xffb5814b)
              : colors.outlineVariant.withValues(alpha: 0.35),
          width: embedded ? 1.5 : 1,
        ),
        boxShadow: embedded
            ? const [
                BoxShadow(
                    color: Color(0x55000000),
                    blurRadius: 10,
                    offset: Offset(0, -2))
              ]
            : null,
      ),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.front_hand_rounded,
                  size: 16,
                  color: embedded ? const Color(0xffffd877) : colors.primary),
              const SizedBox(width: 6),
              Text('你的手牌 · ${widget.hand.length} 张',
                  style: TextStyle(
                      color: titleColor, fontWeight: FontWeight.w700)),
              const Spacer(),
              Text('点选/拖选 · 右键出牌',
                  style: TextStyle(color: hintColor, fontSize: 10)),
            ],
          ),
          const SizedBox(height: 6),
          // Wrap 自动换行，不引入横向滚动；负 spacing 让牌扇形重叠，
          // 每张牌中心仍在自身命中区，点击与鼠标拖选都不受影响。
          Listener(
            onPointerUp: _finishDrag,
            onPointerCancel: _finishDrag,
            child: Wrap(
              spacing: -(_cardWidth - _step),
              runSpacing: 10,
              children: [
                for (var index = 0; index < widget.hand.length; index++)
                  _handCard(index),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _handCard(int index) {
    final card = widget.hand[index];
    final isSelected = widget.selected.contains(card);
    return GestureDetector(
      onTap: widget.enabled ? () => _onTap(card) : null,
      child: Listener(
        key: ValueKey<int>(card),
        onPointerDown: (event) => _onPointerDown(card, event),
        child: MouseRegion(
          cursor: widget.enabled ? SystemMouseCursors.click : MouseCursor.defer,
          onEnter: (event) => _onPointerEnter(card, event),
          child: Semantics(
            button: true,
            enabled: widget.enabled,
            selected: isSelected,
            label: DoudizhuRules.compactCard(card),
            onTap: widget.enabled ? () => _onTap(card) : null,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 110),
              // 选中只轻微上抬，避免行内高低参差过大；主要靠金色描边区分。
              transform: Matrix4.translationValues(0, isSelected ? -5 : 0, 0),
              child: DoudizhuPlayingCard(
                cardId: card,
                selected: isSelected,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

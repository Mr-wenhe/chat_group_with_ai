import 'package:flutter/material.dart';

import 'doudizhu_ai_player.dart';
import 'doudizhu_card_widgets.dart';
import 'doudizhu_game_director.dart';
import 'doudizhu_game_state.dart';
import 'doudizhu_rules.dart';
import 'doudizhu_table_widgets.dart';

part 'doudizhu_table_controls.dart';
part 'doudizhu_table_dock.dart';
part 'doudizhu_table_feed.dart';
part 'doudizhu_table_panels.dart';
part 'doudizhu_table_settlement.dart';

/// 斗地主对局主视图（经典牌桌 + 当前 App 主题面板）。
///
/// 布局分两块：左侧桌面对两/三种视角共用，右侧（宽屏）或下方（窄屏）是
/// 状态、操作、记牌器、牌桌动态。所有对外回调由 [DoudizhuGamePage] 注入，
/// 本文件不含任何对局状态与规则判断。
class DoudizhuTableView extends StatelessWidget {
  const DoudizhuTableView({
    super.key,
    required this.snapshot,
    required this.selectedCardIds,
    required this.onToggleCard,
    required this.onSetCardSelected,
    required this.onBid,
    required this.onPlay,
    required this.onPass,
    required this.onHint,
    required this.onClearSelection,
  });

  final DoudizhuTableSnapshot snapshot;
  final Set<int> selectedCardIds;
  final ValueChanged<int> onToggleCard;
  final void Function(int cardId, bool selected) onSetCardSelected;
  final ValueChanged<int> onBid;
  final ValueChanged<List<int>> onPlay;
  final VoidCallback onPass;
  final VoidCallback onHint;
  final VoidCallback onClearSelection;

  /// 选完牌后右键快捷出牌，走与“出牌”按钮完全相同的 [onPlay] 回调与校验。
  void _quickPlayOnSecondary() {
    if (!doudizhuCanQuickPlay(snapshot, selectedCardIds)) return;
    final humanSeat = snapshot.seats.where((seat) => seat.isHuman).firstOrNull;
    final ownHand = humanSeat?.visibleHand ?? const <int>[];
    onPlay(ownHand.where(selectedCardIds.contains).toList());
  }

  @override
  Widget build(BuildContext context) {
    final humanTurn = snapshot.isHumanTurn;
    final humanSeat = snapshot.seats.where((seat) => seat.isHuman).firstOrNull;
    final ownHand = humanSeat?.visibleHand ?? const <int>[];
    final playEnabled = humanTurn && selectedCardIds.isNotEmpty;
    final canPass = humanTurn && snapshot.trick != null;

    return GestureDetector(
      // 右键快捷出牌，互不干扰手牌的左键点选 / 拖选。
      onSecondaryTap: _quickPlayOnSecondary,
      child: LayoutBuilder(builder: (context, constraints) {
        final hasHuman =
            snapshot.mode == DoudizhuViewMode.participant && humanSeat != null;
        // 第一视角内嵌布局的宽度门槛。牌桌内部可用宽度 = 窗口宽 - 64
        // （外层 14×2 + 木框 6×2 + 毡布 12×2），而牌桌自身在 >=700 时才走
        // 横向布局，因此 760 是能让"底牌 + 左右座位 + 记牌器"排开的最小值。
        // 旧值 1050 在常见的 860 逻辑宽度窗口下永远不命中，导致手牌一直被
        // 挤在绿桌外面，等于内嵌布局没生效。
        final useFeltSlots = hasHuman && constraints.maxWidth >= 760;
        // 单列满高外壳：极宽窗口下（含上帝视角）牌桌吃满剩余高度。
        final wideShell = constraints.maxWidth >= 1050;

        // 手牌 / 操作按钮 / 记牌器：宽屏作为 slot 嵌进牌桌内部，
        // 窄屏仍走下方独立操作面板（窄屏空间有限，不塞进牌桌）。
        final humanHand = hasHuman
            ? DoudizhuHumanHand(
                hand: ownHand,
                selected: selectedCardIds,
                enabled: humanTurn && snapshot.phase == DoudizhuPhase.playing,
                onToggle: onToggleCard,
                onSetSelected: onSetCardSelected,
                embedded: true,
              )
            : null;
        Widget? actionControls;
        Widget? cardCounter;
        if (useFeltSlots) {
          final feltTheme = _darkFeltTheme(context);
          actionControls = Theme(
            data: feltTheme,
            child: _ActionControls(
              snapshot: snapshot,
              ownHand: ownHand,
              selectedCardIds: selectedCardIds,
              humanTurn: humanTurn,
              playEnabled: playEnabled,
              canPass: canPass,
              onBid: onBid,
              onPlay: onPlay,
              onPass: onPass,
              onHint: onHint,
              onClearSelection: onClearSelection,
            ),
          );
          cardCounter = Theme(
            data: feltTheme,
            child: _CardCounter(
              playedCounts: snapshot.playedCounts,
              ownHand: ownHand,
            ),
          );
        }

        final infoPanel = DoudizhuInfoPanel(
          snapshot: snapshot,
          onBid: onBid,
          onPlay: onPlay,
          onPass: onPass,
          onHint: onHint,
          onClearSelection: onClearSelection,
          ownHand: ownHand,
          selectedCardIds: selectedCardIds,
          humanTurn: humanTurn,
          playEnabled: playEnabled,
          canPass: canPass,
          // 宽屏时按钮/记牌器已嵌入牌桌，面板内不再重复渲染。
          embedControls: useFeltSlots,
        );
        // 操作区：状态 / 动态 / 结算装进绿毡木框，成为整块绿色面板的下段。
        final actionDock = _ActionDock(child: infoPanel);

        if (useFeltSlots || wideShell) {
          // 单列：手牌/按钮/记牌器全部嵌进牌桌内部，牌桌 + 信息面板两段。
          // 内嵌时面板压低（按钮已上移），把高度让给牌桌里的手牌与出牌区。
          return Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: DoudizhuFeltTable(
                    snapshot: snapshot,
                    humanHandSlot: useFeltSlots ? humanHand : null,
                    actionControlsSlot: useFeltSlots ? actionControls : null,
                    cardCounterSlot: useFeltSlots ? cardCounter : null,
                  ),
                ),
                const SizedBox(height: 5),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: useFeltSlots ? 188 : 260,
                  ),
                  child: SingleChildScrollView(child: actionDock),
                ),
              ],
            ),
          );
        }

        // 窄屏竖排滚动，同样整块绿底包裹。
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: constraints.maxWidth < 600
                    ? snapshot.mode == DoudizhuViewMode.god
                        ? 690
                        : 500
                    : snapshot.mode == DoudizhuViewMode.god
                        ? 740
                        : 520,
                child: DoudizhuFeltTable(snapshot: snapshot),
              ),
              if (humanHand != null) ...[
                const SizedBox(height: 3),
                humanHand,
              ],
              const SizedBox(height: 3),
              actionDock,
            ],
          ),
        );
      }),
    );
  }
}

class DoudizhuInfoPanel extends StatelessWidget {
  const DoudizhuInfoPanel({
    super.key,
    required this.snapshot,
    required this.onBid,
    required this.onPlay,
    required this.onPass,
    required this.onHint,
    required this.onClearSelection,
    required this.ownHand,
    required this.selectedCardIds,
    required this.humanTurn,
    required this.playEnabled,
    required this.canPass,
    this.embedControls = false,
  });

  final DoudizhuTableSnapshot snapshot;
  final ValueChanged<int> onBid;
  final ValueChanged<List<int>> onPlay;
  final VoidCallback onPass;
  final VoidCallback onHint;
  final VoidCallback onClearSelection;
  final List<int> ownHand;
  final Set<int> selectedCardIds;
  final bool humanTurn;
  final bool playEnabled;
  final bool canPass;

  /// 宽屏时按钮与记牌器已作为 slot 嵌入牌桌，面板内不再重复渲染。
  final bool embedControls;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final hasHumanSeat = snapshot.seats.any((seat) => seat.isHuman);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StatusBanner(snapshot: snapshot),
        if (snapshot.mode == DoudizhuViewMode.god) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: colors.secondaryContainer.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(Icons.visibility_rounded,
                    size: 16, color: colors.tertiary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '上帝视角 · 三家手牌全部亮明，可观察每个角色的出牌决策。',
                    style: TextStyle(color: colors.onSurface, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ],
        if (!embedControls &&
            snapshot.mode == DoudizhuViewMode.participant &&
            hasHumanSeat) ...[
          const SizedBox(height: 12),
          _ActionControls(
            snapshot: snapshot,
            ownHand: ownHand,
            selectedCardIds: selectedCardIds,
            humanTurn: humanTurn,
            playEnabled: playEnabled,
            canPass: canPass,
            onBid: onBid,
            onPlay: onPlay,
            onPass: onPass,
            onHint: onHint,
            onClearSelection: onClearSelection,
          ),
        ],
        const SizedBox(height: 12),
        _RoundFeed(events: snapshot.events, seats: snapshot.seats),
        if (!embedControls &&
            snapshot.mode == DoudizhuViewMode.participant &&
            hasHumanSeat) ...[
          const SizedBox(height: 12),
          _CardCounter(
            playedCounts: snapshot.playedCounts,
            ownHand: ownHand,
          ),
        ],
        if (snapshot.status == DoudizhuMatchStatus.finished) ...[
          const SizedBox(height: 12),
          _Settlement(snapshot: snapshot),
        ],
        if (snapshot.status == DoudizhuMatchStatus.error) ...[
          const SizedBox(height: 10),
          Text(
            '本局已停止：${snapshot.statusMessage}',
            style: TextStyle(color: colors.error, fontWeight: FontWeight.w600),
            textAlign: TextAlign.center,
          ),
        ],
      ],
    );
  }
}

/// 右键快捷出牌是否生效：真人回合 + 出牌阶段 + 已选中至少一张牌。
/// 抽成纯函数便于单测；具体牌型合法性仍由 [DoudizhuGameDirector] 提交时校验。
bool doudizhuCanQuickPlay(
  DoudizhuTableSnapshot snapshot,
  Set<int> selectedCardIds,
) {
  return snapshot.isHumanTurn &&
      snapshot.phase == DoudizhuPhase.playing &&
      selectedCardIds.isNotEmpty;
}

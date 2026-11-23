import 'dart:async';

import 'package:chat_group/core/database/database_service_provider.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/widgets/character_avatar.dart';
import 'package:chat_group/features/ai_governance/ai_governance_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'ai_othello_player.dart';
import 'character_othello_player.dart';
import 'game_director.dart';
import 'othello_board_view.dart';
import 'othello_game_providers.dart';
import 'othello_setup_view.dart';
import 'othello_types.dart';
import '../gomoku/gomoku_budget_resolver.dart';

class OthelloGamePage extends ConsumerStatefulWidget {
  const OthelloGamePage({super.key});

  @override
  ConsumerState<OthelloGamePage> createState() => _OthelloGamePageState();
}

class _OthelloGamePageState extends ConsumerState<OthelloGamePage> {
  OthelloGameDirector? _director;
  StreamSubscription<void>? _subscription;
  final ScrollController _feedController = ScrollController();

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    _director?.dispose();
    _feedController.dispose();
    super.dispose();
  }

  void _startGame(OthelloMatchSetup setup) {
    final director = OthelloGameDirector(
      seats: _buildSeats(setup, _buildBudgetResolver()),
      moveSpacing: ref.read(othelloMoveSpacingProvider),
    );
    unawaited(_subscription?.cancel());
    _director?.dispose();
    setState(() {
      _director = director;
    });
    _subscription = director.changes.listen((_) {
      if (!mounted) return;
      setState(() {});
      _scrollFeedToEnd();
    });
    director.start();
  }

  OthelloBudgetResolver _buildBudgetResolver() {
    final store =
        AiGovernanceStore.forDatabase(ref.read(databaseServiceProvider));
    final resolver = RegistryGomokuBudgetResolver(
      customCapability: (provider, model) =>
          store.customCapability(provider, model),
    );
    return (ApiProvider provider, String model) =>
        resolver.resolve(provider, model);
  }

  List<OthelloSeat> _buildSeats(
    OthelloMatchSetup setup,
    OthelloBudgetResolver budgetResolver,
  ) =>
      [
        _buildSeat(setup, OthelloSide.black, budgetResolver),
        _buildSeat(setup, OthelloSide.white, budgetResolver),
      ];

  OthelloSeat _buildSeat(
    OthelloMatchSetup setup,
    OthelloSide side,
    OthelloBudgetResolver budgetResolver,
  ) {
    if (setup.mode == OthelloMode.humanVsAi && setup.humanSide == side) {
      return OthelloSeat(name: '你', avatar: '我', side: side);
    }
    final character =
        side == OthelloSide.black ? setup.blackAi! : setup.whiteAi!;
    final config =
        side == OthelloSide.black ? setup.blackConfig : setup.whiteConfig;
    return OthelloSeat(
      name: character.name,
      avatar: character.avatar,
      side: side,
      ai: CharacterOthelloPlayer(
        primary: AiOthelloPlayer(
          character: character,
          config: config,
          budgetResolver: budgetResolver,
          api: ref.read(othelloChatApiServiceProvider),
          credentials: ref.read(othelloCredentialResolverProvider),
        ),
        fallback: ref.read(othelloHardMoveEngineProvider),
      ),
    );
  }

  void _restart() {
    _director?.restart();
  }

  void _scrollFeedToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_feedController.hasClients) {
        _feedController.animateTo(
          _feedController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final director = _director;
    return Scaffold(
      appBar: AppBar(
        title: const Text('黑白棋 · Othello'),
        actions: [
          if (director != null && director.phase == OthelloPhase.playing)
            IconButton(
              tooltip: '停止对局',
              icon: const Icon(Icons.stop_circle_outlined),
              onPressed: director.stop,
            ),
          if (director != null)
            IconButton(
              tooltip: '重新开局',
              icon: const Icon(Icons.restart_alt_rounded),
              onPressed: _restart,
            ),
        ],
      ),
      body: director == null
          ? OthelloSetupView(onStart: _startGame)
          : _OthelloMatchView(
              director: director,
              feedController: _feedController,
              onHumanMove: (move) => director.humanMove(move.row, move.col),
            ),
    );
  }
}

class _OthelloMatchView extends StatelessWidget {
  const _OthelloMatchView({
    required this.director,
    required this.feedController,
    required this.onHumanMove,
  });

  final OthelloGameDirector director;
  final ScrollController feedController;
  final ValueChanged<OthelloMove> onHumanMove;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth > 720;
        final board = Card(
          color: cs.surfaceContainerLowest,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.55)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: OthelloBoardView(
              state: director.state,
              interactive: director.isHumanTurn,
              onTap: onHumanMove,
            ),
          ),
        );
        final feed = _SpectatorFeed(
          director: director,
          controller: feedController,
        );

        return Column(
          children: [
            _StatusBanner(director: director),
            _SeatRow(director: director),
            Expanded(
              child: wide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          flex: 3,
                          child: Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 560),
                              child: board,
                            ),
                          ),
                        ),
                        Expanded(flex: 2, child: feed),
                      ],
                    )
                  : Column(
                      children: [
                        Expanded(
                          flex: 3,
                          child: Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 520),
                              child: board,
                            ),
                          ),
                        ),
                        Expanded(flex: 2, child: feed),
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.director});

  final OthelloGameDirector director;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final counts = director.discCounts;
    final current = director.currentSeat;
    final status = director.phase == OthelloPhase.playing
        ? director.statusMessage ??
            '${current.name} 执${current.side.shortLabel}子'
        : director.statusMessage ?? '对局结束';
    final background = director.phase == OthelloPhase.error
        ? cs.errorContainer
        : director.phase == OthelloPhase.finished
            ? cs.primaryContainer
            : cs.secondaryContainer;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              status,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: cs.onSurface,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '黑 ${counts.black}  ·  白 ${counts.white}',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: cs.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

class _SeatRow extends StatelessWidget {
  const _SeatRow({required this.director});

  final OthelloGameDirector director;

  @override
  Widget build(BuildContext context) {
    final black = director.seatFor(OthelloSide.black);
    final white = director.seatFor(OthelloSide.white);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        children: [
          Expanded(
              child: _SeatCard(
                  seat: black, isCurrent: black == director.currentSeat)),
          const SizedBox(width: 8),
          Expanded(
              child: _SeatCard(
                  seat: white, isCurrent: white == director.currentSeat)),
        ],
      ),
    );
  }
}

class _SeatCard extends StatelessWidget {
  const _SeatCard({required this.seat, required this.isCurrent});

  final OthelloSeat seat;
  final bool isCurrent;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isBlack = seat.side == OthelloSide.black;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: isCurrent
            ? cs.primaryContainer.withValues(alpha: 0.72)
            : cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isCurrent ? cs.primary : cs.outlineVariant,
          width: isCurrent ? 1.3 : 0.8,
        ),
      ),
      child: Row(
        children: [
          CharacterAvatar(fallbackText: seat.avatar, size: 30),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  seat.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: cs.onSurface,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  isBlack ? '黑方 · 先手' : '白方',
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 10),
                ),
              ],
            ),
          ),
          Container(
            width: 17,
            height: 17,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color:
                  isBlack ? const Color(0xFF171A19) : const Color(0xFFF9FAF8),
              border: Border.all(color: cs.outline.withValues(alpha: 0.65)),
            ),
          ),
        ],
      ),
    );
  }
}

class _SpectatorFeed extends StatelessWidget {
  const _SpectatorFeed({required this.director, required this.controller});

  final OthelloGameDirector director;
  final ScrollController controller;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (director.events.isEmpty) {
      return Center(
        child: Text(
          director.isHumanTurn ? '轮到你时点击棋盘上的合法落点' : '等待第一步…',
          style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
        ),
      );
    }
    return ListView.builder(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      itemCount: director.events.length,
      itemBuilder: (context, index) {
        final event = director.events[index];
        return Padding(
          key: ValueKey(
              'othello-event-${event.kind}-${event.moveNumber}-$index'),
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CharacterAvatar(fallbackText: event.avatar, size: 30),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            event.seatName,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: cs.onSurface,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          event.side.label,
                          style: TextStyle(
                            color: cs.onSurfaceVariant,
                            fontSize: 11,
                          ),
                        ),
                        if (event.source != null) ...[
                          const SizedBox(width: 6),
                          Text(
                            event.source == OthelloDecisionSource.hardFallback
                                ? 'Hard 兜底'
                                : '角色模型',
                            style: TextStyle(
                              color: cs.primary,
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    if (event.kind == OthelloEventKind.pass)
                      Text(
                        '无合法着法，自动跳过',
                        style: TextStyle(
                          color: cs.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      )
                    else ...[
                      Text(
                        '${event.move!.toCoordinate()} · 翻转 ${event.flipsCount} 枚',
                        style: TextStyle(
                          color: cs.primary,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (event.fallbackNote != null) ...[
                        const SizedBox(height: 3),
                        Text(
                          '模型未落子：${event.fallbackNote}',
                          style: TextStyle(
                            color: cs.error,
                            fontSize: 11,
                            height: 1.3,
                          ),
                        ),
                      ],
                      if (event.reason.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        SelectionContainer.disabled(
                          child: Text(
                            event.reason,
                            style: TextStyle(
                              color: cs.onSurfaceVariant,
                              fontSize: 12,
                              height: 1.35,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

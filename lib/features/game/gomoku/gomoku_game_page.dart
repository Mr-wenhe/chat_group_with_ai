/// 五子棋游戏页：选 App 内的 AI 角色入座（AI 对弈 / AI 对真人），观战棋局。
///
/// 台前玩家始终是 [AICharacter]——人设、头像、绑定模型全部复用。落子优先
/// 交给角色自己的模型；模型失败时由内置棋力辅助静默接手，不显示「代落」。
library;

import 'dart:async';

import 'package:chat_group/core/database/database_service_provider.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/widgets/character_avatar.dart';
import 'package:chat_group/features/ai_governance/ai_governance_store.dart';
import 'package:chat_group/features/game/gomoku/gomoku_experience_memory.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import 'ai_gomoku_player.dart';
import 'character_gomoku_player.dart';
import 'engine_gomoku_player.dart';
import 'game_director.dart';
import 'gomoku_board.dart';
import 'gomoku_board_view.dart';
import 'gomoku_budget_resolver.dart';
import 'gomoku_setup_view.dart';

class GomokuGamePage extends ConsumerStatefulWidget {
  const GomokuGamePage({super.key});

  @override
  ConsumerState<GomokuGamePage> createState() => _GomokuGamePageState();
}

class _GomokuGamePageState extends ConsumerState<GomokuGamePage> {
  GameDirector? _director;
  GomokuMatchSetup? _lastSetup;
  StreamSubscription<void>? _subscription;
  final ScrollController _feedController = ScrollController();
  final Set<String> _recordedMatchIds = <String>{};

  @override
  void dispose() {
    _subscription?.cancel();
    _director?.dispose();
    _feedController.dispose();
    super.dispose();
  }

  /// 用治理侧模型能力构造落子预算 resolver：内置快照 + 用户在设置里手写的
  /// 上下文/输出上限，与聊天回复共用同一套公式。
  GomokuBudgetResolver _buildBudgetResolver() {
    final store =
        AiGovernanceStore.forDatabase(ref.read(databaseServiceProvider));
    final resolver = RegistryGomokuBudgetResolver(
      customCapability: (provider, model) =>
          store.customCapability(provider, model),
    );
    return (ApiProvider provider, String model) =>
        resolver.resolve(provider, model);
  }

  /// 一个 AI 角色席位：模型优先，失败时棋力辅助接手。
  CharacterGomokuPlayer _aiPlayer(
    AICharacter character,
    ApiConfig? config,
    GomokuBudgetResolver budgetResolver,
    GomokuExperienceMemoryService experienceMemory,
    List<String> visibleCharacterIds,
  ) {
    return CharacterGomokuPlayer(
      primary: AiGomokuPlayer(
        character: character,
        config: config,
        budgetResolver: budgetResolver,
        gameExperienceLoader: () => experienceMemory.forGame(
          observerCharacterId: character.id,
          visibleCharacterIds: visibleCharacterIds,
        ),
      ),
      fallback: const EngineGomokuPlayer(),
    );
  }

  void _startGame(GomokuMatchSetup setup) {
    final budgetResolver = _buildBudgetResolver();
    final db = ref.read(databaseServiceProvider);
    final experienceMemory = GomokuExperienceMemoryService(db);
    final matchId = const Uuid().v4();
    final aiCharactersByStone = <GomokuStone, AICharacter>{};
    if (setup.mode == GomokuMode.aiVsAi) {
      aiCharactersByStone[GomokuStone.black] = setup.primaryAi;
      aiCharactersByStone[GomokuStone.white] = setup.secondaryAi!;
    } else {
      aiCharactersByStone[setup.humanBlack
          ? GomokuStone.white
          : GomokuStone.black] = setup.primaryAi;
    }
    final visibleCharacterIds = aiCharactersByStone.values
        .map((character) => character.id)
        .toList(growable: false);
    final director = GameDirector(
      seats: _buildSeats(
        setup: setup,
        budgetResolver: budgetResolver,
        experienceMemory: experienceMemory,
        visibleCharacterIds: visibleCharacterIds,
      ),
      onFinished: (finishedGame) {
        if (!_recordedMatchIds.add(matchId)) return;
        unawaited(
          experienceMemory
              .recordFinishedMatch(
                matchId: matchId,
                director: finishedGame,
                aiCharactersByStone: aiCharactersByStone,
              )
              .catchError((Object _) {}),
        );
      },
    );
    _subscription?.cancel();
    _director?.dispose();
    setState(() {
      _director = director;
      _lastSetup = setup;
    });
    _subscription = director.changes.listen((_) {
      if (!mounted) return;
      setState(() {});
      _scrollFeedToEnd();
    });
    director.start();
  }

  List<GomokuSeat> _buildSeats({
    required GomokuMatchSetup setup,
    required GomokuBudgetResolver budgetResolver,
    required GomokuExperienceMemoryService experienceMemory,
    required List<String> visibleCharacterIds,
  }) {
    if (setup.mode == GomokuMode.aiVsAi) {
      return [
        _createAiSeat(
          setup.primaryAi,
          setup.primaryConfig,
          GomokuStone.black,
          budgetResolver,
          experienceMemory,
          visibleCharacterIds,
        ),
        _createAiSeat(
          setup.secondaryAi!,
          setup.secondaryConfig,
          GomokuStone.white,
          budgetResolver,
          experienceMemory,
          visibleCharacterIds,
        ),
      ];
    }

    final aiStone = setup.humanBlack ? GomokuStone.white : GomokuStone.black;
    final humanSeat = GomokuSeat(
      name: '你',
      avatar: '我',
      stone: aiStone.opponent,
    );
    final aiSeat = _createAiSeat(
      setup.primaryAi,
      setup.primaryConfig,
      aiStone,
      budgetResolver,
      experienceMemory,
      visibleCharacterIds,
    );
    return setup.humanBlack ? [humanSeat, aiSeat] : [aiSeat, humanSeat];
  }

  GomokuSeat _createAiSeat(
    AICharacter character,
    ApiConfig? config,
    GomokuStone stone,
    GomokuBudgetResolver budgetResolver,
    GomokuExperienceMemoryService experienceMemory,
    List<String> visibleCharacterIds,
  ) {
    return GomokuSeat(
      name: character.name,
      avatar: character.avatar,
      stone: stone,
      ai: _aiPlayer(
        character,
        config,
        budgetResolver,
        experienceMemory,
        visibleCharacterIds,
      ),
    );
  }

  void _handleRestart() {
    final director = _director;
    final setup = _lastSetup;
    if (director?.phase == GomokuPhase.finished && setup != null) {
      _startGame(setup.swappedSides());
      return;
    }

    _subscription?.cancel();
    director?.dispose();
    setState(() {
      _director = null;
      _lastSetup = null;
    });
  }

  void _scrollFeedToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_feedController.hasClients) {
        _feedController.animateTo(
          _feedController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final director = _director;
    final isFinished = director?.phase == GomokuPhase.finished;
    return Scaffold(
      appBar: AppBar(
        title: const Text('五子棋 · AI 角色对弈'),
        actions: [
          if (director != null)
            IconButton(
              tooltip: isFinished ? '换边再来一局' : '重新开局',
              icon: Icon(isFinished
                  ? Icons.swap_horiz_rounded
                  : Icons.restart_alt_rounded),
              onPressed: _handleRestart,
            ),
        ],
      ),
      body: director == null
          ? GomokuSetupView(onStart: _startGame)
          : _GameView(
              director: director,
              feedController: _feedController,
              onHumanMove: (row, col) => director.humanMove(row, col),
            ),
    );
  }
}

/// 对局视图：棋盘 + 状态 + 观战思考流。
class _GameView extends StatelessWidget {
  final GameDirector director;
  final ScrollController feedController;
  final void Function(int row, int col) onHumanMove;

  const _GameView({
    required this.director,
    required this.feedController,
    required this.onHumanMove,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth > 720;
        final board = Card(
          color: cs.surfaceContainerLowest,
          elevation: 0,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: GomokuBoardView(
              board: director.board,
              interactive: director.isHumanTurn,
              winningLine: director.board.winningLine,
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
                          )),
                        ),
                        Expanded(flex: 2, child: feed),
                      ],
                    )
                  : Column(
                      children: [board, Expanded(child: feed)],
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _StatusBanner extends StatelessWidget {
  final GameDirector director;
  const _StatusBanner({required this.director});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = director.statusMessage ??
        (director.phase == GomokuPhase.finished ? '对局结束' : '对局进行中');
    final color = director.phase == GomokuPhase.error
        ? cs.errorContainer
        : director.phase == GomokuPhase.finished
            ? cs.primaryContainer
            : cs.secondaryContainer;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        style: TextStyle(
            fontSize: 14, fontWeight: FontWeight.w500, color: cs.onSurface),
      ),
    );
  }
}

/// 观战棋局流：逐条展示落子者的决策理由与坐标。
class _SpectatorFeed extends StatelessWidget {
  final GameDirector director;
  final ScrollController controller;
  const _SpectatorFeed({required this.director, required this.controller});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (director.events.isEmpty) {
      return Center(
        child: Text('等待第一步…',
            style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
      );
    }
    return ListView.builder(
      controller: controller,
      padding: const EdgeInsets.all(12),
      itemCount: director.events.length,
      itemBuilder: (context, index) {
        final event = director.events[index];
        final isThinking = event.position.row == -1;
        // 引擎模式下这里是战术理由（如「堵对手成五」），完整展示不截断。
        final thought = event.reasoning.trim();
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CharacterAvatar(fallbackText: event.avatar, size: 32),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(event.seatName,
                            style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: cs.onSurface)),
                        const SizedBox(width: 6),
                        Text(event.stone.label,
                            style: TextStyle(
                                fontSize: 11, color: cs.onSurfaceVariant)),
                      ],
                    ),
                    const SizedBox(height: 4),
                    if (thought.isNotEmpty)
                      SelectionContainer.disabled(
                        child: Text(
                          thought,
                          style: TextStyle(
                              fontSize: 12,
                              color: cs.onSurfaceVariant,
                              height: 1.4),
                          // 完整展示决策理由，不截断；列表本身可滚动。
                        ),
                      ),
                    const SizedBox(height: 4),
                    if (isThinking)
                      Text(
                        '落子中…',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          // 用 onSurfaceVariant 而非 outline：四套皮肤下都清晰可读。
                          color: cs.onSurfaceVariant,
                        ),
                      )
                    else
                      Row(
                        children: [
                          Text(
                            '落子 (${event.position.row},${event.position.col})',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: cs.primary,
                            ),
                          ),
                          if (event.elapsedMs > 0) ...[
                            const SizedBox(width: 6),
                            Text(
                              '${(event.elapsedMs / 1000).toStringAsFixed(1)}s',
                              style: TextStyle(
                                fontSize: 10,
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ],
                      ),
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

import 'dart:async';

import 'package:chat_group/core/database/database_service_provider.dart';
import 'package:chat_group/features/ai_governance/ai_governance_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'doudizhu_ai_player.dart';
import 'doudizhu_budget_resolver.dart';
import 'doudizhu_game_director.dart';
import 'doudizhu_game_providers.dart';
import 'doudizhu_game_state.dart';
import 'doudizhu_move_generator.dart';
import 'doudizhu_setup_view.dart';
import 'doudizhu_table_view.dart';

class DoudizhuGamePage extends ConsumerStatefulWidget {
  const DoudizhuGamePage({super.key});

  @override
  ConsumerState<DoudizhuGamePage> createState() => _DoudizhuGamePageState();
}

class _DoudizhuGamePageState extends ConsumerState<DoudizhuGamePage> {
  DoudizhuGameDirector? _director;
  StreamSubscription<void>? _subscription;
  final Set<int> _selectedCards = <int>{};
  int? _lastTurnId;
  int? _lastDealNumber;
  List<List<int>?> _hintActions = const [];
  int _hintIndex = 0;

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    _director?.dispose();
    super.dispose();
  }

  void _startGame(DoudizhuMatchSetup setup) {
    final budget = _buildBudgetResolver();
    final hardEngine = ref.read(doudizhuHardMoveEngineProvider);
    final seats = List<DoudizhuSeat>.generate(3, (index) {
      final role = setup.roles[index];
      if (role == null) {
        return const DoudizhuSeat(name: '你', avatar: '我');
      }
      return DoudizhuSeat(
        name: role.character.name,
        avatar: role.character.avatar,
        player: DoudizhuCharacterPlayer(
          primary: AiDoudizhuPlayer(
            character: role.character,
            config: role.config,
            budgetResolver: budget.resolve,
            inputBudgetResolver: budget.resolveInputTokens,
            api: ref.read(doudizhuChatApiServiceProvider),
            credentials: ref.read(doudizhuCredentialResolverProvider),
          ),
          fallback: hardEngine,
        ),
      );
    });
    final director = DoudizhuGameDirector(
      seats: seats,
      viewMode: setup.mode == DoudizhuSetupMode.god
          ? DoudizhuViewMode.god
          : DoudizhuViewMode.participant,
      humanSeat: setup.humanSeat,
      seed: ref.read(doudizhuSeedProvider),
      moveSpacing: ref.read(doudizhuMoveSpacingProvider),
      transitionSpacing: ref.read(doudizhuTransitionSpacingProvider),
    );
    unawaited(_subscription?.cancel());
    _director?.dispose();
    _selectedCards.clear();
    _clearHintCycle();
    _lastTurnId = null;
    _lastDealNumber = null;
    setState(() => _director = director);
    _subscription = director.changes.listen((_) {
      if (!mounted) return;
      final current = director.snapshot();
      if (_lastTurnId != current.turnId ||
          _lastDealNumber != current.dealNumber) {
        _selectedCards.clear();
        _clearHintCycle();
      }
      _lastTurnId = current.turnId;
      _lastDealNumber = current.dealNumber;
      setState(() {});
    });
    director.start();
  }

  RegistryDoudizhuBudgetResolver _buildBudgetResolver() {
    final store =
        AiGovernanceStore.forDatabase(ref.read(databaseServiceProvider));
    return RegistryDoudizhuBudgetResolver(
      customCapability: (provider, model) =>
          store.customCapability(provider, model),
    );
  }

  void _restart() {
    _selectedCards.clear();
    _clearHintCycle();
    _director?.restart();
  }

  void _clearHintCycle() {
    _hintActions = const [];
    _hintIndex = 0;
  }

  void _toggleCard(int cardId) {
    _clearHintCycle();
    if (_selectedCards.contains(cardId)) {
      _selectedCards.remove(cardId);
    } else {
      _selectedCards.add(cardId);
    }
    setState(() {});
  }

  void _setCardSelected(int cardId, bool selected) {
    _clearHintCycle();
    if (selected) {
      _selectedCards.add(cardId);
    } else {
      _selectedCards.remove(cardId);
    }
    setState(() {});
  }

  void _clearSelection() {
    _selectedCards.clear();
    _clearHintCycle();
    setState(() {});
  }

  void _showHint(DoudizhuTableSnapshot snapshot) {
    final hand =
        snapshot.seats.where((seat) => seat.isHuman).firstOrNull?.visibleHand;
    if (!snapshot.isHumanTurn ||
        snapshot.phase != DoudizhuPhase.playing ||
        hand == null) {
      return;
    }
    if (_hintActions.isEmpty) {
      final indexedMoves = generateDoudizhuMoves(
        hand,
        lastPlay: snapshot.trick?.move,
        wingChoices: 2,
      ).indexed.toList()
        ..sort((a, b) {
          final size = a.$2.cardIds.length.compareTo(b.$2.cardIds.length);
          if (size != 0) return size;
          final rank = a.$2.rank.compareTo(b.$2.rank);
          return rank != 0 ? rank : a.$1.compareTo(b.$1);
        });
      _hintActions = [
        for (final entry in indexedMoves) entry.$2.cardIds,
        if (snapshot.trick != null) null,
      ];
      _hintIndex = 0;
    }
    if (_hintActions.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有可提示的合法出牌')),
      );
      return;
    }
    final action = _hintActions[_hintIndex];
    _hintIndex = (_hintIndex + 1) % _hintActions.length;
    _selectedCards
      ..clear()
      ..addAll(action ?? const <int>[]);
    setState(() {});
    if (action == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('建议不出')),
      );
    }
  }

  void _submit(DoudizhuAction action) {
    final director = _director;
    if (director == null) return;
    final result = director.submitAction(director.currentSeat, action);
    if (result.legal) {
      _selectedCards.clear();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.reason ?? '该动作不合法')),
      );
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final director = _director;
    return Scaffold(
      appBar: AppBar(
        title: const Text('斗地主'),
        actions: [
          if (director != null &&
              director.status == DoudizhuMatchStatus.playing)
            IconButton(
              tooltip: '停止对局',
              icon: const Icon(Icons.stop_circle_outlined),
              onPressed: director.stop,
            ),
          if (director != null)
            IconButton(
              tooltip: '重新发牌',
              icon: const Icon(Icons.restart_alt_rounded),
              onPressed: _restart,
            ),
        ],
      ),
      body: director == null
          ? DoudizhuSetupView(onStart: _startGame)
          : DoudizhuTableView(
              snapshot: director.snapshot(),
              selectedCardIds: _selectedCards,
              onToggleCard: _toggleCard,
              onSetCardSelected: _setCardSelected,
              onBid: (score) => _submit(DoudizhuBidAction(score)),
              onPlay: (cards) => _submit(DoudizhuPlayAction(cards)),
              onPass: () => _submit(const DoudizhuPassAction()),
              onHint: () => _showHint(director.snapshot()),
              onClearSelection: _clearSelection,
            ),
    );
  }
}

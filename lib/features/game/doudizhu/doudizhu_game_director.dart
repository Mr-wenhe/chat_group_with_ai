import 'dart:async';

import 'package:dio/dio.dart' show CancelToken;

import 'doudizhu_ai_player.dart';
import 'doudizhu_game_state.dart';
import 'doudizhu_move_generator.dart';
import 'doudizhu_rules.dart';

enum DoudizhuMatchStatus { playing, stopped, finished, error }

enum DoudizhuViewMode { god, participant }

class DoudizhuSeat {
  const DoudizhuSeat({
    required this.name,
    required this.avatar,
    this.player,
  });

  final String name;
  final String avatar;
  final DoudizhuTurnPlayer? player;
  bool get isHuman => player == null;
}

class DoudizhuPublicEvent {
  const DoudizhuPublicEvent({
    required this.dealNumber,
    required this.message,
    this.seat,
    this.actionKind,
    this.cardIds = const [],
    this.typeLabel,
    this.bidScore,
    this.source,
    this.modelAttempts,
    this.publicLine,
    this.fallbackNote,
    this.multiplier,
    this.engineElapsedMilliseconds,
    this.engineCandidateCount,
    this.engineHandsBefore,
    this.engineHandsAfter,
    this.engineScore,
  });

  final int dealNumber;
  final String message;
  final int? seat;
  final DoudizhuLogKind? actionKind;
  final List<int> cardIds;
  final String? typeLabel;
  final int? bidScore;
  final DoudizhuDecisionSource? source;
  final int? modelAttempts;
  final String? publicLine;
  final String? fallbackNote;
  final int? multiplier;
  final int? engineElapsedMilliseconds;
  final int? engineCandidateCount;
  final int? engineHandsBefore;
  final int? engineHandsAfter;
  final int? engineScore;
}

class DoudizhuSeatSnapshot {
  const DoudizhuSeatSnapshot({
    required this.index,
    required this.name,
    required this.avatar,
    required this.handSize,
    required this.roleLabel,
    required this.isCurrent,
    required this.isHuman,
    this.visibleHand,
    this.bid,
  });

  final int index;
  final String name;
  final String avatar;
  final int handSize;
  final String roleLabel;
  final bool isCurrent;
  final bool isHuman;
  final List<int>? visibleHand;
  final int? bid;
}

class DoudizhuTableSnapshot {
  const DoudizhuTableSnapshot({
    required this.mode,
    required this.status,
    required this.phase,
    required this.statusMessage,
    required this.seats,
    required this.events,
    required this.multiplier,
    required this.dealNumber,
    required this.turnId,
    required this.isHumanTurn,
    required this.highestBid,
    required this.passCount,
    required this.landlord,
    required this.bidTurn,
    required this.playedCounts,
    required this.scores,
    this.trick,
    this.bottomCards,
  });

  final DoudizhuViewMode mode;
  final DoudizhuMatchStatus status;
  final DoudizhuPhase phase;
  final String statusMessage;
  final List<DoudizhuSeatSnapshot> seats;
  final List<DoudizhuPublicEvent> events;
  final int multiplier;
  final int dealNumber;
  final int turnId;
  final bool isHumanTurn;
  final int highestBid;
  final int passCount;
  final int landlord;
  final int bidTurn;
  final List<int> playedCounts;
  final List<int> scores;
  final DoudizhuTrick? trick;
  final List<int>? bottomCards;
}

/// Match lifecycle, turn scheduler and the sole action commit gate.
class DoudizhuGameDirector {
  DoudizhuGameDirector({
    required List<DoudizhuSeat> seats,
    required this.viewMode,
    required this.humanSeat,
    int? seed,
    this.moveSpacing = const Duration(milliseconds: 350),
    this.transitionSpacing = const Duration(milliseconds: 620),
  })  : assert(seats.length == 3, '斗地主需要三个席位'),
        assert(
          viewMode == DoudizhuViewMode.god || humanSeat != null,
          '真人参与模式必须指定真人席位',
        ),
        _seats = List.unmodifiable(seats),
        _state = DoudizhuGameState(seed: seed);

  final List<DoudizhuSeat> _seats;
  final DoudizhuViewMode viewMode;
  final int? humanSeat;
  final Duration moveSpacing;
  final Duration transitionSpacing;
  final StreamController<void> _notifier =
      StreamController<void>.broadcast(sync: true);
  final List<DoudizhuPublicEvent> _events = <DoudizhuPublicEvent>[];

  DoudizhuGameState _state;
  DoudizhuMatchStatus _status = DoudizhuMatchStatus.playing;
  String _statusMessage = '等待叫分';
  CancelToken? _activeCancelToken;
  Timer? _scheduledTimer;
  DateTime? _lastAiTurnAt;
  int _matchGeneration = 0;
  int _dealGeneration = 0;
  int _turnGeneration = 0;
  bool _turnInFlight = false;
  bool _started = false;
  bool _disposed = false;

  Stream<void> get changes => _notifier.stream;
  List<DoudizhuSeat> get seats => _seats;
  List<DoudizhuPublicEvent> get events => List.unmodifiable(_events);
  DoudizhuGameState get state => _state;
  DoudizhuMatchStatus get status => _status;
  String get statusMessage => _statusMessage;
  int get turnId => _turnGeneration;
  int get dealId => _dealGeneration;
  bool get isHumanTurn =>
      !_disposed &&
      _status == DoudizhuMatchStatus.playing &&
      !_turnInFlight &&
      _seats[_state.phase == DoudizhuPhase.bidding
              ? _state.bidTurn
              : _state.turn]
          .isHuman;

  int get currentSeat =>
      _state.phase == DoudizhuPhase.bidding ? _state.bidTurn : _state.turn;

  void start() {
    if (_disposed || _started || _status != DoudizhuMatchStatus.playing) return;
    _started = true;
    _driveCurrentTurn();
  }

  /// Every human, model and engine action reaches this method and the same rules.
  DoudizhuActionOutcome submitAction(
    int seat,
    DoudizhuAction action, {
    int? expectedMatch,
    int? expectedDeal,
    int? expectedTurn,
    DoudizhuPlayerDecision? decision,
  }) {
    if (_disposed || _status != DoudizhuMatchStatus.playing) {
      return const DoudizhuActionOutcome(legal: false, reason: '本局当前不能操作');
    }
    final isAutomated =
        expectedMatch != null || expectedDeal != null || expectedTurn != null;
    if (isAutomated) {
      if (expectedMatch != _matchGeneration ||
          expectedDeal != _dealGeneration ||
          expectedTurn != _turnGeneration ||
          !_turnInFlight ||
          seat != currentSeat ||
          _seats[seat].isHuman) {
        return const DoudizhuActionOutcome(
          legal: false,
          reason: '本回合已变化，请重新操作',
        );
      }
    } else if (!isHumanTurn || seat != currentSeat || _turnInFlight) {
      return const DoudizhuActionOutcome(
        legal: false,
        reason: '还没轮到真人席位操作',
      );
    }

    final dealNumber = _state.dealNumber;
    final outcome = switch (_state.phase) {
      DoudizhuPhase.bidding when action is DoudizhuBidAction =>
        _state.nextBid(seat, action.score),
      DoudizhuPhase.playing when action is DoudizhuPlayAction =>
        _state.play(seat, action.cardIds),
      DoudizhuPhase.playing when action is DoudizhuPassAction =>
        _state.pass(seat),
      _ => const DoudizhuActionOutcome(
          legal: false,
          reason: '当前动作与游戏阶段不符',
        ),
    };
    if (!outcome.legal) return outcome;

    _turnGeneration++;
    _turnInFlight = false;
    _cancelActiveTurn('斗地主动作已提交');
    _appendActionEvent(
      seat: seat,
      action: action,
      dealNumber: dealNumber,
      decision: decision,
    );

    if (outcome.redeal) {
      _dealGeneration++;
      _statusMessage = '三家都不叫，重新发牌';
      _events.add(
        DoudizhuPublicEvent(
          dealNumber: _state.dealNumber,
          message: '三家都不叫，重新发牌',
        ),
      );
      _notify();
      _scheduleDrive(transitionSpacing);
      return outcome;
    }
    if (outcome.bidsComplete) {
      _turnInFlight = true;
      _statusMessage = '${_seats[_state.landlord].name} 成为地主，准备亮底牌';
      _notify();
      final match = _matchGeneration;
      final deal = _dealGeneration;
      final turn = _turnGeneration;
      _schedule(transitionSpacing, () {
        if (!_isCurrent(match, deal, turn)) return;
        if (!_state.startPlay()) {
          _fail('无法开始出牌阶段');
          return;
        }
        _turnInFlight = false;
        _events.add(
          DoudizhuPublicEvent(
            dealNumber: _state.dealNumber,
            message: '${_seats[_state.landlord].name} 拿到底牌，开始出牌',
          ),
        );
        _statusMessage =
            '地主 ${_seats[_state.landlord].name} 首出 · 倍数 ×${_state.multiplier}';
        _notify();
        _scheduleDrive(moveSpacing);
      });
      return outcome;
    }
    if (outcome.matchOver) {
      _status = DoudizhuMatchStatus.finished;
      final team = _state.landlordWin ? '地主' : '农民';
      _statusMessage =
          '$team获胜 · 倍数 ×${_state.multiplier} · 结算 ${_state.settle().join('/')}';
      _events.add(
        DoudizhuPublicEvent(
          dealNumber: _state.dealNumber,
          message: _statusMessage,
          multiplier: _state.multiplier,
        ),
      );
      _notify();
      return outcome;
    }

    _statusMessage = _actionMessage(seat, action);
    _notify();
    _scheduleDrive(moveSpacing);
    return outcome;
  }

  void stop() {
    if (_disposed || _status != DoudizhuMatchStatus.playing) {
      return;
    }
    _matchGeneration++;
    _turnGeneration++;
    _cancelScheduled();
    _cancelActiveTurn('用户停止斗地主对局');
    _turnInFlight = false;
    _status = DoudizhuMatchStatus.stopped;
    _statusMessage = '对局已停止';
    _notify();
  }

  void restart() {
    if (_disposed) return;
    _matchGeneration++;
    _dealGeneration++;
    _turnGeneration++;
    _cancelScheduled();
    _cancelActiveTurn('重新开始斗地主对局');
    _state = DoudizhuGameState();
    _events.clear();
    _status = DoudizhuMatchStatus.playing;
    _statusMessage = '重新发牌，开始叫分';
    _turnInFlight = false;
    _started = true;
    _lastAiTurnAt = null;
    _notify();
    _driveCurrentTurn();
  }

  DoudizhuTableSnapshot snapshot() {
    final viewIsGod = viewMode == DoudizhuViewMode.god;
    final seats = List<DoudizhuSeatSnapshot>.generate(3, (index) {
      final seat = _seats[index];
      final showHand = viewIsGod || index == humanSeat;
      return DoudizhuSeatSnapshot(
        index: index,
        name: seat.name,
        avatar: seat.avatar,
        handSize: _state.hands[index].length,
        roleLabel: _state.landlord < 0
            ? '待定'
            : _state.landlord == index
                ? '地主'
                : '农民',
        isCurrent:
            _status == DoudizhuMatchStatus.playing && currentSeat == index,
        isHuman: seat.isHuman,
        visibleHand: showHand ? List.unmodifiable(_state.hands[index]) : null,
        bid: _state.bids[index],
      );
    });
    final revealBottom = viewIsGod || _state.landlord >= 0;
    return DoudizhuTableSnapshot(
      mode: viewMode,
      status: _status,
      phase: _state.phase,
      statusMessage: _statusMessage,
      seats: List.unmodifiable(seats),
      events: events,
      multiplier: _state.multiplier,
      dealNumber: _state.dealNumber,
      turnId: _turnGeneration,
      isHumanTurn: isHumanTurn,
      highestBid: _state.highestBid,
      passCount: _state.passCount,
      landlord: _state.landlord,
      bidTurn: _state.bidTurn,
      playedCounts: List.unmodifiable(_state.playedCounts),
      scores: _state.isOver ? List.unmodifiable(_state.settle()) : const [],
      trick: _state.lastPlay,
      bottomCards: revealBottom ? List.unmodifiable(_state.bottom) : null,
    );
  }

  void _driveCurrentTurn() {
    if (_disposed ||
        !_started ||
        _status != DoudizhuMatchStatus.playing ||
        _turnInFlight) {
      return;
    }
    if (_state.phase == DoudizhuPhase.over) {
      _status = DoudizhuMatchStatus.finished;
      _notify();
      return;
    }
    final seat = currentSeat;
    if (_seats[seat].isHuman) {
      _statusMessage = _state.phase == DoudizhuPhase.bidding
          ? '轮到 ${_seats[seat].name} 叫分'
          : '轮到 ${_seats[seat].name} 出牌';
      _notify();
      return;
    }
    final options = _buildOptions(seat);
    if (_state.phase == DoudizhuPhase.playing &&
        _state.lastPlay != null &&
        options.length == 1 &&
        options.single.action is DoudizhuPassAction &&
        findAnyLegalDoudizhuResponse(
              _state.hands[seat],
              _state.lastPlay!.move,
            ) ==
            null) {
      _turnInFlight = true;
      final match = _matchGeneration;
      final deal = _dealGeneration;
      final turn = _turnGeneration;
      _statusMessage = '${_seats[seat].name} 无牌可压，自动过牌';
      _notify();
      submitAction(
        seat,
        const DoudizhuPassAction(),
        expectedMatch: match,
        expectedDeal: deal,
        expectedTurn: turn,
      );
      return;
    }
    if (_state.phase == DoudizhuPhase.playing &&
        _state.lastPlay == null &&
        options.isEmpty) {
      _fail('领出阶段没有可提交的合法牌');
      return;
    }
    _turnInFlight = true;
    _lastAiTurnAt = DateTime.now();
    final match = _matchGeneration;
    final deal = _dealGeneration;
    final turn = _turnGeneration;
    final token = CancelToken();
    _activeCancelToken = token;
    final seatName = _seats[seat].name;
    final isBidding = _state.phase == DoudizhuPhase.bidding;
    final player = _seats[seat].player;
    if (player is DoudizhuCharacterPlayer) {
      if (!player.primary.hasConfiguredModel) {
        _statusMessage = isBidding
            ? '$seatName 未配置可用模型，本地叫分策略接手…'
            : '$seatName 未配置可用模型，宗师正在接手…';
      } else {
        final timeout = player.primary.turnTimeout.inSeconds;
        _statusMessage = isBidding
            ? '$seatName 正在叫分 · 模型最多等待 $timeout 秒，失败后本地策略接手'
            : '$seatName 正在思考出牌 · 模型最多等待 $timeout 秒，失败或超时后宗师接手';
      }
    } else {
      _statusMessage = '$seatName 正在${isBidding ? '叫分' : '出牌'}…';
    }
    _notify();
    unawaited(_runAutomatedTurn(
      seat: seat,
      options: options,
      match: match,
      deal: deal,
      turn: turn,
      token: token,
    ));
  }

  Future<void> _runAutomatedTurn({
    required int seat,
    required List<DoudizhuActionOption> options,
    required int match,
    required int deal,
    required int turn,
    required CancelToken token,
  }) async {
    try {
      final input = _inputForSeat(seat, options);
      final decision = await _seats[seat].player!.decide(
            input,
            cancelToken: token,
          );
      if (!_isCurrent(match, deal, turn) ||
          token.isCancelled ||
          decision == null) {
        return;
      }
      final outcome = submitAction(
        seat,
        decision.action,
        expectedMatch: match,
        expectedDeal: deal,
        expectedTurn: turn,
        decision: decision,
      );
      if (!outcome.legal && _isCurrent(match, deal, turn)) {
        _fail('自动玩家动作未通过规则校验');
      }
    } on Object {
      if (_isCurrent(match, deal, turn)) {
        _fail('角色模型与宗师引擎均无法完成本回合');
      }
    }
  }

  DoudizhuAiTurnInput _inputForSeat(
    int seat,
    List<DoudizhuActionOption> options,
  ) {
    final bidding = _state.phase == DoudizhuPhase.bidding;
    final role = bidding
        ? '叫分中'
        : _state.landlord == seat
            ? '地主'
            : '农民';
    return DoudizhuAiTurnInput(
      seat: seat,
      seatName: _seats[seat].name,
      teamLabel: role,
      phase: _state.phase,
      ownHand: _state.hands[seat],
      bids: _state.bids,
      highestBid: _state.highestBid,
      landlord: _state.landlord,
      handSizes: _state.hands.map((hand) => hand.length).toList(),
      publicLog: _state.log,
      lastPlay: _state.lastPlay,
      publicBottom: bidding ? null : _state.bottom,
      passCount: _state.passCount,
      multiplier: _state.multiplier,
      options: options,
    );
  }

  List<DoudizhuActionOption> _buildOptions(int seat) {
    if (_state.phase == DoudizhuPhase.bidding) {
      return [
        for (final score in [0, 1, 2, 3])
          if (score == 0 || score > _state.highestBid)
            DoudizhuActionOption(
              actionId: 'b$score',
              action: DoudizhuBidAction(score),
              typeLabel: '叫分',
              cardIds: const [],
              bidScore: score,
            ),
      ];
    }
    final trick = _state.lastPlay;
    final moves = generateDoudizhuMoves(
      _state.hands[seat],
      lastPlay: trick?.move,
      wingChoices: 3,
    );
    final options = <DoudizhuActionOption>[
      for (var index = 0; index < moves.length; index++)
        DoudizhuActionOption(
          actionId: 'm$index',
          action: DoudizhuPlayAction(moves[index].cardIds),
          typeLabel: moves[index].type.label,
          cardIds: moves[index].cardIds,
        ),
    ];
    if (trick != null && moves.isEmpty) {
      final exact = findAnyLegalDoudizhuResponse(
        _state.hands[seat],
        trick.move,
      );
      if (exact != null) {
        options.add(
          DoudizhuActionOption(
            actionId: 'x0',
            action: DoudizhuPlayAction(exact.cardIds),
            typeLabel: exact.type.label,
            cardIds: exact.cardIds,
          ),
        );
      }
    }
    if (trick != null) {
      options.add(
        const DoudizhuActionOption(
          actionId: 'p',
          action: DoudizhuPassAction(),
          typeLabel: '不出',
          cardIds: [],
        ),
      );
    }
    return options;
  }

  void _appendActionEvent({
    required int seat,
    required DoudizhuAction action,
    required int dealNumber,
    DoudizhuPlayerDecision? decision,
  }) {
    final name = _seats[seat].name;
    if (action is DoudizhuBidAction) {
      _events.add(
        DoudizhuPublicEvent(
          dealNumber: dealNumber,
          seat: seat,
          actionKind: DoudizhuLogKind.bid,
          bidScore: action.score,
          message: action.score == 0 ? '$name 不叫' : '$name 叫 ${action.score} 分',
          source: decision?.source,
          modelAttempts: decision?.modelAttempts,
          publicLine: decision?.publicLine,
          fallbackNote: decision?.fallbackNote,
        ),
      );
    } else if (action is DoudizhuPassAction) {
      _events.add(
        DoudizhuPublicEvent(
          dealNumber: dealNumber,
          seat: seat,
          actionKind: DoudizhuLogKind.pass,
          message: '$name 不出',
          source: decision?.source,
          modelAttempts: decision?.modelAttempts,
          publicLine: decision?.publicLine,
          fallbackNote: decision?.fallbackNote,
          multiplier: _state.multiplier,
        ),
      );
    } else if (action is DoudizhuPlayAction) {
      final move = DoudizhuRules.classify(action.cardIds);
      _events.add(
        DoudizhuPublicEvent(
          dealNumber: dealNumber,
          seat: seat,
          actionKind: DoudizhuLogKind.play,
          cardIds: List.unmodifiable(action.cardIds),
          typeLabel: move?.type.label,
          message:
              '$name 出 ${move?.type.label ?? '牌'} ${DoudizhuRules.cardsLabel(action.cardIds)}',
          source: decision?.source,
          modelAttempts: decision?.modelAttempts,
          publicLine: decision?.publicLine,
          fallbackNote: decision?.fallbackNote,
          multiplier: _state.multiplier,
          engineElapsedMilliseconds: decision?.engineElapsedMilliseconds,
          engineCandidateCount: decision?.engineCandidateCount,
          engineHandsBefore: decision?.engineHandsBefore,
          engineHandsAfter: decision?.engineHandsAfter,
          engineScore: decision?.engineScore,
        ),
      );
    }
  }

  String _actionMessage(int seat, DoudizhuAction action) {
    if (action is DoudizhuBidAction) {
      return action.score == 0
          ? '${_seats[seat].name} 不叫'
          : '${_seats[seat].name} 叫 ${action.score} 分';
    }
    if (action is DoudizhuPassAction) return '${_seats[seat].name} 不出';
    final cards = (action as DoudizhuPlayAction).cardIds;
    final type = DoudizhuRules.classify(cards)?.type.label ?? '牌';
    return '${_seats[seat].name} 出 $type ${DoudizhuRules.cardsLabel(cards)}';
  }

  void _scheduleDrive(Duration delay) {
    if (_disposed || _status != DoudizhuMatchStatus.playing) return;
    final seat = currentSeat;
    if (_seats[seat].isHuman) {
      _driveCurrentTurn();
      return;
    }
    final spacing = _lastAiTurnAt == null
        ? Duration.zero
        : moveSpacing - DateTime.now().difference(_lastAiTurnAt!);
    final effective = spacing > delay ? spacing : delay;
    final match = _matchGeneration;
    final deal = _dealGeneration;
    final turn = _turnGeneration;
    _schedule(effective, () {
      if (_isCurrent(match, deal, turn)) _driveCurrentTurn();
    });
  }

  void _schedule(Duration delay, void Function() callback) {
    _cancelScheduled();
    _scheduledTimer = Timer(delay, () {
      _scheduledTimer = null;
      if (!_disposed) callback();
    });
  }

  bool _isCurrent(int match, int deal, int turn) =>
      !_disposed &&
      _status == DoudizhuMatchStatus.playing &&
      match == _matchGeneration &&
      deal == _dealGeneration &&
      turn == _turnGeneration;

  void _fail(String message) {
    _turnGeneration++;
    _cancelScheduled();
    _cancelActiveTurn('斗地主对局故障');
    _turnInFlight = false;
    _status = DoudizhuMatchStatus.error;
    _statusMessage = message;
    _notify();
  }

  void _cancelActiveTurn(String reason) {
    final token = _activeCancelToken;
    _activeCancelToken = null;
    if (token != null && !token.isCancelled) token.cancel(reason);
  }

  void _cancelScheduled() {
    _scheduledTimer?.cancel();
    _scheduledTimer = null;
  }

  void _notify() {
    if (!_disposed && !_notifier.isClosed) _notifier.add(null);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _matchGeneration++;
    _dealGeneration++;
    _turnGeneration++;
    _cancelScheduled();
    _cancelActiveTurn('斗地主页面已离开');
    _turnInFlight = false;
    unawaited(_notifier.close());
  }
}

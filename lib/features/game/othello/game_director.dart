import 'dart:async';

import 'package:dio/dio.dart' show CancelToken;

import 'character_othello_player.dart';
import 'othello_rules.dart';
import 'othello_types.dart';

class OthelloSeat {
  const OthelloSeat({
    required this.name,
    required this.avatar,
    required this.side,
    this.ai,
  });

  final String name;
  final String avatar;
  final OthelloSide side;
  final CharacterOthelloPlayer? ai;

  bool get isHuman => ai == null;
}

enum OthelloPhase { playing, stopped, finished, error }

enum OthelloEventKind { move, pass }

class OthelloEvent {
  const OthelloEvent({
    required this.kind,
    required this.side,
    required this.seatName,
    required this.avatar,
    required this.moveNumber,
    this.move,
    this.reason = '',
    this.source,
    this.fallbackNote,
    this.flipsCount = 0,
    this.elapsedMilliseconds = 0,
  });

  final OthelloEventKind kind;
  final OthelloSide side;
  final String seatName;
  final String avatar;
  final int moveNumber;
  final OthelloMove? move;
  final String reason;
  final OthelloDecisionSource? source;
  final String? fallbackNote;
  final int flipsCount;
  final int elapsedMilliseconds;
}

/// Match scheduler. All submitted moves pass through [OthelloRules.makeMove].
class OthelloGameDirector {
  OthelloGameDirector({
    required List<OthelloSeat> seats,
    OthelloGameState? initialState,
    this.moveSpacing = const Duration(milliseconds: 350),
    this.onFinished,
  })  : assert(seats.length == 2, 'Othello needs exactly two seats'),
        assert(
          seats[0].side != seats[1].side,
          'Othello seats must use opposite colors',
        ),
        _seats = List.unmodifiable(seats),
        _state = initialState ?? OthelloRules.createInitialState();

  final List<OthelloSeat> _seats;
  final Duration moveSpacing;
  final void Function(OthelloGameDirector director)? onFinished;
  final StreamController<void> _notifier =
      StreamController<void>.broadcast(sync: true);
  final List<OthelloEvent> _events = [];

  OthelloGameState _state;
  OthelloPhase _phase = OthelloPhase.playing;
  String? _statusMessage;
  CancelToken? _activeCancelToken;
  DateTime? _lastAiTurnAt;
  int _generation = 0;
  bool _started = false;
  bool _turnInFlight = false;
  bool _disposed = false;
  bool _finishDelivered = false;

  OthelloGameState get state => _state;
  OthelloBoard get board => _state.board;
  List<OthelloEvent> get events => List.unmodifiable(_events);
  List<OthelloSeat> get seats => _seats;
  OthelloPhase get phase => _phase;
  String? get statusMessage => _statusMessage;
  Stream<void> get changes => _notifier.stream;
  OthelloSeat get currentSeat => seatFor(_state.currentSide);
  OthelloDiscCounts get discCounts => OthelloRules.countDiscs(_state.board);
  bool get isHumanTurn =>
      _phase == OthelloPhase.playing && !_turnInFlight && currentSeat.isHuman;

  OthelloSeat seatFor(OthelloSide side) =>
      _seats.firstWhere((seat) => seat.side == side);

  /// Starts once; no-model/no-legal-move turns are settled before AI dispatch.
  void start() {
    if (_disposed || _started || _phase != OthelloPhase.playing) return;
    _started = true;
    _resolveTurnAndDrive();
  }

  /// Human input is accepted only for a human seat and current generated move.
  void humanMove(int row, int col) {
    if (!isHumanTurn) return;
    final move = OthelloMove(row, col);
    _commitMove(move, source: null, reason: '', elapsedMilliseconds: 0);
  }

  /// Stop invalidates the current turn and cancels its active model/isolate job.
  void stop() {
    if (_disposed || _phase != OthelloPhase.playing) return;
    _generation++;
    _cancelActiveTurn('Othello match stopped');
    _turnInFlight = false;
    _phase = OthelloPhase.stopped;
    _statusMessage = '对局已停止';
    _notify();
  }

  /// Restart the selected sides from the standard opening position.
  void restart() {
    if (_disposed) return;
    _generation++;
    _cancelActiveTurn('Othello match restarted');
    _state = OthelloRules.createInitialState();
    _events.clear();
    _phase = OthelloPhase.playing;
    _statusMessage = null;
    _turnInFlight = false;
    _started = true;
    _finishDelivered = false;
    _lastAiTurnAt = null;
    _resolveTurnAndDrive();
  }

  void _resolveTurnAndDrive() {
    if (_disposed || _phase != OthelloPhase.playing) return;
    if (_state.validMoves.isEmpty) {
      final resolution = OthelloRules.resolveNoMoves(_state);
      _state = resolution.state;
      for (final side in resolution.passedSides) {
        _events.add(
          OthelloEvent(
            kind: OthelloEventKind.pass,
            side: side,
            seatName: seatFor(side).name,
            avatar: seatFor(side).avatar,
            moveNumber: _state.moveHistory.length,
          ),
        );
      }
      if (_state.isFinished) {
        _finishGame();
        return;
      }
      _notify();
    }
    _driveIfAiTurn();
  }

  void _driveIfAiTurn() {
    if (_disposed || _phase != OthelloPhase.playing || _turnInFlight) return;
    final seat = currentSeat;
    if (seat.isHuman) {
      _statusMessage = '轮到你执${seat.side.shortLabel}子';
      _notify();
      return;
    }
    _turnInFlight = true;
    _generation++;
    final generation = _generation;
    final token = CancelToken();
    _activeCancelToken = token;
    _statusMessage = '${seat.name}（${seat.side.shortLabel}）正在选择落点…';
    _notify();
    unawaited(_runAiTurn(seat, token, generation));
  }

  Future<void> _runAiTurn(
    OthelloSeat seat,
    CancelToken token,
    int generation,
  ) async {
    final lastTurnAt = _lastAiTurnAt;
    if (lastTurnAt != null) {
      final wait = moveSpacing - DateTime.now().difference(lastTurnAt);
      if (wait > Duration.zero) await Future<void>.delayed(wait);
    }
    if (!_isCurrentTurn(generation, token, seat)) return;

    final stopwatch = Stopwatch()..start();
    OthelloMoveDecision? decision;
    try {
      decision = await seat.ai!.decideMove(
        board: _state.board,
        side: seat.side,
        legalMoves: _state.validMoves,
        cancelToken: token,
      );
    } on Object {
      if (!_isCurrentTurn(generation, token, seat)) return;
      _failTurn(seat, '模型与 Hard 兜底均未能返回落点');
      return;
    }
    if (!_isCurrentTurn(generation, token, seat)) return;
    if (decision == null) {
      _failTurn(seat, '模型与 Hard 兜底均未能返回落点');
      return;
    }

    _lastAiTurnAt = DateTime.now();
    final elapsed = stopwatch.elapsedMilliseconds;
    _commitMove(
      decision.move,
      source: decision.source,
      fallbackNote: decision.fallbackNote,
      reason: decision.reason,
      elapsedMilliseconds: elapsed,
      expectedGeneration: generation,
      token: token,
    );
  }

  bool _isCurrentTurn(
    int generation,
    CancelToken token,
    OthelloSeat seat,
  ) =>
      !_disposed &&
      _phase == OthelloPhase.playing &&
      generation == _generation &&
      !token.isCancelled &&
      identical(_activeCancelToken, token) &&
      currentSeat == seat;

  void _commitMove(
    OthelloMove move, {
    required OthelloDecisionSource? source,
    String? fallbackNote,
    required String reason,
    required int elapsedMilliseconds,
    int? expectedGeneration,
    CancelToken? token,
  }) {
    if (_disposed || _phase != OthelloPhase.playing) return;
    if (expectedGeneration != null &&
        (expectedGeneration != _generation ||
            token == null ||
            !_isCurrentTurn(expectedGeneration, token, currentSeat))) {
      return;
    }
    final seat = currentSeat;
    if (seat.isHuman == (source != null)) return;

    // This is the single commit gate for both model and human actions.
    final nextState = OthelloRules.makeMove(_state, move);
    if (nextState == null) {
      if (!seat.isHuman) {
        _failTurn(seat, '返回的落点不在当前合法列表中');
      }
      return;
    }

    final legalMove = _state.validMoves.firstWhere(
      (candidate) => candidate.move == move,
    );
    _state = nextState;
    _events.add(
      OthelloEvent(
        kind: OthelloEventKind.move,
        side: seat.side,
        seatName: seat.name,
        avatar: seat.avatar,
        moveNumber: _state.moveHistory.length,
        move: move,
        reason: reason,
        source: source,
        fallbackNote: fallbackNote,
        flipsCount: legalMove.flipsCount,
        elapsedMilliseconds: elapsedMilliseconds,
      ),
    );
    if (_state.passedSide != null) {
      final skipped = seatFor(_state.passedSide!);
      _events.add(
        OthelloEvent(
          kind: OthelloEventKind.pass,
          side: skipped.side,
          seatName: skipped.name,
          avatar: skipped.avatar,
          moveNumber: _state.moveHistory.length,
        ),
      );
    }

    _generation++;
    _cancelActiveTurn('Othello turn completed');
    _turnInFlight = false;
    _statusMessage = null;
    if (_state.isFinished) {
      _finishGame();
      return;
    }
    _notify();
    _resolveTurnAndDrive();
  }

  void _failTurn(OthelloSeat seat, String publicMessage) {
    _generation++;
    _cancelActiveTurn('Othello turn failed');
    _turnInFlight = false;
    _phase = OthelloPhase.error;
    _statusMessage = '${seat.name} 无法落子：$publicMessage';
    _notify();
  }

  void _finishGame() {
    _phase = OthelloPhase.finished;
    final counts = discCounts;
    _statusMessage = _state.winner == null
        ? '对局结束，${counts.black}:${counts.white} 和棋'
        : '${_state.winner!.label}获胜 · 黑 ${counts.black}：白 ${counts.white}';
    _turnInFlight = false;
    if (!_finishDelivered) {
      _finishDelivered = true;
      onFinished?.call(this);
    }
    _notify();
  }

  void _cancelActiveTurn(String reason) {
    final token = _activeCancelToken;
    _activeCancelToken = null;
    if (token != null && !token.isCancelled) token.cancel(reason);
  }

  void _notify() {
    if (!_disposed && !_notifier.isClosed) _notifier.add(null);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _cancelActiveTurn('Othello page disposed');
    _turnInFlight = false;
    unawaited(_notifier.close());
  }
}

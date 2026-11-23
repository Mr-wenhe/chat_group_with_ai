/// 五子棋对局调度器：驱动「AI 角色 / 真人」轮流落子，输出可观战的事件流。
///
/// 这是纯逻辑控制器（不依赖 widget），UI 通过 [addListener] 订阅状态变化。
/// 轮转、落子校验、终局判定全部收口于此，玩家只负责「给出坐标」——
/// 至于坐标来自本地引擎还是模型，调度器不关心。
library;

import 'dart:async';

import 'gomoku_board.dart';
import 'gomoku_player.dart';

/// 一个玩家席位。
class GomokuSeat {
  /// 座位显示名（AI 角色名或「你」）。
  final String name;

  /// 头像文本（AI 用角色 avatar，真人用「我」）。
  final String avatar;

  /// 执子颜色。
  final GomokuStone stone;

  /// 为 null 表示真人席位，由 UI 落子。
  ///
  /// 类型只依赖统一决策接口：本地引擎玩家与模型玩家都能入座。
  final GomokuPlayer? ai;

  GomokuSeat({
    required this.name,
    required this.avatar,
    required this.stone,
    this.ai,
  });

  bool get isHuman => ai == null;
}

/// 观战事件：每一步的落子者、坐标、思考文本与当前棋盘快照。
class GomokuEvent {
  final String seatName;
  final String avatar;
  final GomokuPosition position;
  final GomokuStone stone;
  final String reasoning;
  final int moveNumber;

  /// 该步决策耗时（毫秒）；真人与思考占位为 0。
  final int elapsedMs;

  const GomokuEvent({
    required this.seatName,
    required this.avatar,
    required this.position,
    required this.stone,
    required this.reasoning,
    required this.moveNumber,
    this.elapsedMs = 0,
  });
}

/// 对局状态。
enum GomokuPhase {
  /// 等待当前玩家落子（玩家决策中，或等真人点击）。
  playing,

  /// 分出胜负或和棋。
  finished,

  /// 某玩家决策失败并停止。
  error,
}

/// 五子棋对局调度器。
class GameDirector {
  final List<GomokuSeat> _seats;
  final void Function(GameDirector director)? onFinished;
  final GomokuBoard _board = GomokuBoard();
  final List<GomokuEvent> _events = <GomokuEvent>[];
  final StreamController<void> _notifier = StreamController<void>.broadcast();

  int _currentSeatIndex = 0;
  GomokuPhase _phase = GomokuPhase.playing;
  String? _statusMessage;
  bool _disposed = false;
  bool _running = false;

  /// 上一手 AI 落子时间：引擎是毫秒级计算，不稍微留点间隔的话
  /// AI 对 AI 一局会瞬间闪完，观战区根本看不清。
  DateTime? _lastAiDecisionAt;

  /// 两手之间的最小间隔（可调，测试可设为 Duration.zero）。
  final Duration moveSpacing;

  static const _defaultMoveSpacing = Duration(milliseconds: 300);

  GameDirector({
    required List<GomokuSeat> seats,
    this.moveSpacing = _defaultMoveSpacing,
    this.onFinished,
  })  : assert(seats.length == 2, '五子棋需要恰好两个席位'),
        assert(seats[0].stone != seats[1].stone, '两个席位必须执不同颜色'),
        _seats = List.unmodifiable(seats);

  GomokuBoard get board => _board;
  List<GomokuEvent> get events => List.unmodifiable(_events);
  List<GomokuSeat> get seats => _seats;
  GomokuPhase get phase => _phase;
  String? get statusMessage => _statusMessage;
  Stream<void> get changes => _notifier.stream;

  GomokuSeat get currentSeat => _seats[_currentSeatIndex];

  /// 当前是否为真人回合。
  bool get isHumanTurn => _phase == GomokuPhase.playing && currentSeat.isHuman;

  bool get isDisposed => _disposed;

  /// 启动对局：若先手是 AI，自动驱动它落子。
  void start() {
    if (_running) return;
    _running = true;
    _driveIfNeeded();
  }

  /// 真人落子入口。仅在真人回合、坐标合法时生效。
  Future<void> humanMove(int row, int col) async {
    if (!isHumanTurn) return;
    await _commitMove(currentSeat, GomokuPosition(row, col), reasoning: '');
  }

  /// 若当前是 AI 回合，异步驱动它决策并落子。
  void _driveIfNeeded() {
    if (_disposed || _phase != GomokuPhase.playing) return;
    final seat = currentSeat;
    if (seat.isHuman) {
      _statusMessage = '轮到你落子';
      _notify();
      return;
    }

    _statusMessage = '${seat.name} 正在落子…';
    _notify();

    // 拉起一次决策；进度通过事件流里的占位条目实时回吐给观战区。
    unawaited(_runAiTurn(seat));
  }

  Future<void> _runAiTurn(GomokuSeat seat) async {
    final ai = seat.ai!;
    final buffer = StringBuffer();
    final thinkingEventIndex = _events.length;

    // 引擎落子是瞬时的，稍微拉开间隔，让观战区能一步步看清棋局推进。
    final last = _lastAiDecisionAt;
    if (last != null) {
      final gap = DateTime.now().difference(last);
      if (gap < moveSpacing) {
        await Future<void>.delayed(moveSpacing - gap);
      }
    }

    final decision = await ai.decideMove(
      board: _board,
      myStone: seat.stone,
      onThinking: (delta) {
        buffer.write(delta);
        // 决策中先插入一条「落子未定」的占位条目，让观战看到进度。
        final thinking = GomokuEvent(
          seatName: seat.name,
          avatar: seat.avatar,
          position: const GomokuPosition(-1, -1), // 哨兵：尚未落子
          stone: seat.stone,
          reasoning: buffer.toString(),
          moveNumber: _events.length + 1,
        );
        if (_events.length == thinkingEventIndex) {
          _events.add(thinking);
        } else {
          _events[thinkingEventIndex] = thinking;
        }
        _notify();
      },
    );

    if (_disposed) return;
    _lastAiDecisionAt = DateTime.now();

    if (!decision.isSuccess) {
      // 不再「系统代落」：决策失败就明确停在错误态，把真实原因展示出来。
      // 五子棋已切到本地引擎，正常对局不会走到这里；保留错误态是为了
      // 任何未来接入的决策器失败时不会被冒充成 AI 的一手。
      if (_events.isNotEmpty && _events.last.position.row == -1) {
        _events.removeLast();
      }
      _phase = GomokuPhase.error;
      final reason = decision.reasoning.trim();
      final error = decision.error?.trim() ?? '';
      _statusMessage = [
        if (reason.isNotEmpty) reason,
        if (error.isNotEmpty) error,
        '${seat.name} 未能落子',
      ].join(' · ');
      _notify();
      return;
    }

    await _commitMove(
      seat,
      decision.position!,
      reasoning: decision.reasoning,
      elapsedMs: decision.elapsedMs,
    );
  }

  /// 落子并推进回合；决策中的占位条目在这里被替换为正式落子。
  Future<void> _commitMove(
    GomokuSeat seat,
    GomokuPosition position, {
    required String reasoning,
    int elapsedMs = 0,
  }) async {
    final result = _board.place(position.row, position.col, seat.stone);
    if (result != GomokuMoveResult.ok) {
      // AI 给了非法坐标：真人回合静默忽略；AI 回合记为错误。
      if (!seat.isHuman) {
        _phase = GomokuPhase.error;
        _statusMessage = '${seat.name} 落子非法：$position（$result）';
        _notify();
      }
      return;
    }

    // 替换思考占位条目（若存在）为正式落子事件。
    final event = GomokuEvent(
      seatName: seat.name,
      avatar: seat.avatar,
      position: position,
      stone: seat.stone,
      reasoning: reasoning,
      moveNumber: _board.moveCount,
      elapsedMs: elapsedMs,
    );
    if (_events.isNotEmpty &&
        _events.last.position.row == -1 &&
        _events.last.seatName == seat.name) {
      _events[_events.length - 1] = event;
    } else {
      _events.add(event);
    }

    if (_board.winner != null) {
      _phase = GomokuPhase.finished;
      _statusMessage =
          '${_board.winner!.label}方（${_stoneOwnerName(_board.winner!)}）获胜！';
    } else if (_board.isFull) {
      _phase = GomokuPhase.finished;
      _statusMessage = '棋盘已满，和棋';
    } else {
      _currentSeatIndex = (_currentSeatIndex + 1) % _seats.length;
      _statusMessage = null;
    }
    if (_phase == GomokuPhase.finished) onFinished?.call(this);
    _notify();

    if (_phase == GomokuPhase.playing) _driveIfNeeded();
  }

  String _stoneOwnerName(GomokuStone stone) =>
      _seats.firstWhere((s) => s.stone == stone).name;

  void _notify() {
    if (!_disposed) _notifier.add(null);
  }

  void dispose() {
    _disposed = true;
    _notifier.close();
  }
}

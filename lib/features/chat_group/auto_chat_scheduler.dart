import 'dart:async';

/// Runs automatic chat rounds sequentially and owns all timer lifecycle.
class AutoChatScheduler {
  AutoChatScheduler({
    required this.nextInterval,
    required this.runRound,
  });

  final Duration Function() nextInterval;
  final Future<void> Function() runRound;
  Timer? _timer;
  bool _running = false;
  bool _disposed = false;
  bool _stopped = false;

  /// Set by [coolDown()] during an active round to suppress the normal
  /// [nextInterval] scheduling in the finally block.
  bool _cooldownRequestedDuringRound = false;

  bool get isRunning => _running;

  /// 调度器是否还活着：正在跑一轮，或已经排好下一次。
  ///
  /// "停止生成"、生命周期暂停、burst 冷却都可能把它停掉；调用方据此判断要不要
  /// 重新拉起，避免重复排期把计时器不断往后推。
  bool get isActive => _running || (_timer?.isActive ?? false);

  void start({required Duration initialDelay}) {
    if (_disposed) return;
    _stopped = false;
    _cooldownRequestedDuringRound = false;
    _schedule(initialDelay);
  }

  void coolDown(Duration duration) {
    if (_disposed) return;
    _timer?.cancel();
    _stopped = false;
    _cooldownRequestedDuringRound = true;
    _schedule(duration);
  }

  void stop() {
    _stopped = true;
    _timer?.cancel();
  }

  void _schedule(Duration delay) {
    _timer?.cancel();
    _timer = Timer(delay, _tick);
  }

  Future<void> _tick() async {
    if (_disposed || _running) return;
    _running = true;
    _cooldownRequestedDuringRound = false;
    try {
      await runRound();
    } finally {
      _running = false;
    }
    if (_disposed || _stopped) return;

    // 仅当本轮内部未调用 coolDown() 时调度下一轮。
    // coolDown() 已自行安排冷却定时器，此处再 _schedule 会覆盖它。
    if (!_cooldownRequestedDuringRound) {
      _schedule(nextInterval());
    }
    _cooldownRequestedDuringRound = false;
  }

  void dispose() {
    _disposed = true;
    _stopped = true;
    _timer?.cancel();
    _timer = null;
  }
}

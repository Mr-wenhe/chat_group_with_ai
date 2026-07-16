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

  bool get isRunning => _running;

  void start({required Duration initialDelay}) {
    if (_disposed) return;
    _schedule(initialDelay);
  }

  void coolDown(Duration duration) {
    if (_disposed) return;
    _timer?.cancel();
    _schedule(duration);
  }

  void stop() => _timer?.cancel();

  void _schedule(Duration delay) {
    _timer?.cancel();
    _timer = Timer(delay, _tick);
  }

  Future<void> _tick() async {
    if (_disposed || _running) return;
    _running = true;
    try {
      await runRound();
    } finally {
      _running = false;
      if (!_disposed) _schedule(nextInterval());
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }
}

import 'dart:async';

import 'package:chat_group/core/streaming/chat_stream_event.dart';

class StreamingReplyResult {
  final String content;
  final bool failed;
  final bool stopped;
  final String? error;
  final int? promptTokens;
  final int? completionTokens;
  final int? cachedTokens;

  const StreamingReplyResult({
    required this.content,
    required this.failed,
    required this.stopped,
    this.error,
    this.promptTokens,
    this.completionTokens,
    this.cachedTokens,
  });
}

/// Owns one SSE subscription, cancellation and throttled draft delivery.
class StreamingReplySession {
  StreamingReplySession({
    this.flushInterval = const Duration(milliseconds: 80),
    this.stallTimeout = defaultStallTimeout,
    this.onCancel,
    this.onCompatibilityRetry,
  });

  /// 正文停滞看门狗的默认阈值。
  ///
  /// 上游（尤其自建中转）可能发完响应头就再也不发任何数据、也不关闭连接：
  /// dio 的 receiveTimeout 只覆盖"等响应头"，响应体流没有任何超时，这一轮就会
  /// 永久停在「AI 正在生成...」。180 秒与工作模式的首字节停滞时限取同一量级。
  static const Duration defaultStallTimeout = Duration(seconds: 180);

  /// 上一次收到上游事件后的静默上限；`null` 或非正直表示关闭看门狗。
  final Duration? stallTimeout;

  /// 会话被放弃（用户停止、页面销毁、看门狗判停滞）时回调，用来 abort 上游请求。
  final void Function()? onCancel;

  /// 上游拒绝本次采样参数、正在自动兼容重发时回调（用来给用户一个可见提示）。
  final void Function()? onCompatibilityRetry;

  final Duration flushInterval;
  StreamSubscription<ChatStreamEvent>? _subscription;
  Completer<StreamingReplyResult>? _done;
  Timer? _flushTimer;
  Timer? _stallTimer;
  void Function(String draft)? _onDraft;
  String _content = '';
  String? _error;
  int? _promptTokens;
  int? _completionTokens;
  int? _cachedTokens;
  bool _failed = false;
  bool _disposed = false;

  bool get isActive => _done != null && !_done!.isCompleted;

  Future<StreamingReplyResult> run(
    Stream<ChatStreamEvent> events, {
    required void Function(String draft) onDraft,
  }) {
    if (_disposed || isActive) {
      throw StateError('StreamingReplySession is unavailable');
    }
    _reset();
    _onDraft = onDraft;
    final done = Completer<StreamingReplyResult>();
    _done = done;
    _subscription = events.listen(
      _handleEvent,
      onError: (Object error) {
        _failed = true;
        _error = error.toString();
        _finish();
      },
      onDone: _finish,
      cancelOnError: false,
    );
    _armStallWatchdog();
    return done.future;
  }

  void _handleEvent(ChatStreamEvent event) {
    if (_disposed || !isActive) return;
    // 任何上游事件（含一次被拒后的兼容重试）都说明这条连接还活着，重置停滞计时。
    _armStallWatchdog();
    if (event.transportFailure != null) {
      // 这条事件只在「刚才那次请求被拒、客户端马上换参数重发」时出现：
      // 用户此刻看不到任何正文，必须给出可见提示，否则就是几十秒的空等。
      onCompatibilityRetry?.call();
      return;
    }
    switch (event.type) {
      case ChatStreamEventType.token:
        _content += event.delta ?? '';
        _scheduleFlush();
      case ChatStreamEventType.done:
        if ((event.content ?? '').isNotEmpty) _content = event.content!;
        _promptTokens = event.promptTokens;
        _completionTokens = event.completionTokens;
        _cachedTokens = event.cachedTokens;
        _finish();
      case ChatStreamEventType.error:
        _failed = true;
        _error = event.message;
        _finish();
    }
  }

  void _scheduleFlush() {
    if (flushInterval == Duration.zero) {
      _flush();
      return;
    }
    if (_flushTimer?.isActive ?? false) return;
    _flushTimer = Timer(flushInterval, _flush);
  }

  void _flush() {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (!_disposed) _onDraft?.call(_content);
  }

  Future<void> stop() async {
    if (!isActive) return;
    // 先收尾再取消订阅：async* 的取消**打断不了挂起的 await**（Dart 只在与
    // yield 对齐时才会真正取消生成器）。上游卡在等字节/等响应时，`cancel()`
    // 永远不返回，先 await 它就是把「停止生成」变成永久无响应——界面停在
    // 「AI 正在生成...」，再点多少次都是同一件事。收尾本身会发起取消，只不等。
    _abandonUpstream();
    _finish(stopped: true);
  }

  /// 通知上游放弃（abort 传输层请求）。取消只需要发起，不需要等它完成。
  void _abandonUpstream() {
    final callback = onCancel;
    if (callback == null) return;
    try {
      callback();
    } on Object {
      // 上游取消失败不能反过来阻断本地收尾。
    }
  }

  void _armStallWatchdog() {
    _stallTimer?.cancel();
    _stallTimer = null;
    final timeout = stallTimeout;
    if (timeout == null || timeout <= Duration.zero || !isActive) return;
    _stallTimer = Timer(timeout, _handleStall);
  }

  void _handleStall() {
    _stallTimer = null;
    if (_disposed || !isActive) return;
    // 判失败而不是 stopped：用户没点停止，这条失败要落成可见回复并触发重试。
    _failed = true;
    _error =
        '模型长时间没有返回内容（超时：已等待 ${(stallTimeout ?? Duration.zero).inSeconds} 秒）';
    _abandonUpstream();
    _finish();
  }

  void _finish({bool stopped = false}) {
    final done = _done;
    if (done == null || done.isCompleted) return;
    _stallTimer?.cancel();
    _stallTimer = null;
    if (!_disposed) _flush();
    unawaited(_subscription?.cancel());
    _subscription = null;
    done.complete(StreamingReplyResult(
      content: _content,
      failed: _failed,
      stopped: stopped,
      error: _error,
      promptTokens: _promptTokens,
      completionTokens: _completionTokens,
      cachedTokens: _cachedTokens,
    ));
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _flushTimer?.cancel();
    _stallTimer?.cancel();
    _stallTimer = null;
    _abandonUpstream();
    final done = _done;
    final subscription = _subscription;
    _subscription = null;
    // 与 stop() 同一条纪律：先让调用方拿到结果，再发起取消、**不等**它完成。
    // 上游卡在 await 时 cancel 不会返回，await 它就是让 dispose 永远挂在那里。
    if (done != null && !done.isCompleted) {
      done.complete(StreamingReplyResult(
        content: _content,
        failed: _failed,
        stopped: true,
        error: _error,
        promptTokens: _promptTokens,
        completionTokens: _completionTokens,
        cachedTokens: _cachedTokens,
      ));
    }
    unawaited(subscription?.cancel());
  }

  void _reset() {
    _flushTimer?.cancel();
    _flushTimer = null;
    _stallTimer?.cancel();
    _stallTimer = null;
    _content = '';
    _error = null;
    _promptTokens = null;
    _completionTokens = null;
    _cachedTokens = null;
    _failed = false;
  }
}

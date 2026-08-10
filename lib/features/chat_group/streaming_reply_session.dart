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
  });

  final Duration flushInterval;
  StreamSubscription<ChatStreamEvent>? _subscription;
  Completer<StreamingReplyResult>? _done;
  Timer? _flushTimer;
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
    return done.future;
  }

  void _handleEvent(ChatStreamEvent event) {
    if (_disposed || !isActive) return;
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
    await _subscription?.cancel();
    _finish(stopped: true);
  }

  void _finish({bool stopped = false}) {
    final done = _done;
    if (done == null || done.isCompleted) return;
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
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
    final done = _done;
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
  }

  void _reset() {
    _content = '';
    _error = null;
    _promptTokens = null;
    _completionTokens = null;
    _cachedTokens = null;
    _failed = false;
  }
}

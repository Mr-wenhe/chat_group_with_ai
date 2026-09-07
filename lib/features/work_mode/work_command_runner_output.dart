part of 'work_command_runner.dart';

enum WorkCommandOutputStream { stdout, stderr }

class WorkCommandOutputChunk {
  final WorkCommandOutputStream stream;
  final String text;
  final int byteLength;
  final DateTime timestamp;

  WorkCommandOutputChunk({
    required this.stream,
    required this.text,
    required this.byteLength,
    DateTime? timestamp,
  }) : timestamp = (timestamp ?? DateTime.now()).toUtc();
}

typedef WorkCommandOutputSink = FutureOr<void> Function(
  WorkCommandOutputChunk chunk,
);

class _OutputCollector {
  final int limit;
  final SearchSecretScanner scanner;
  final WorkCommandOutputSink? sink;
  final void Function(_StopReason reason) requestStop;
  int usedBytes = 0;
  bool truncated = false;
  String stdout = '';
  String stderr = '';
  final Map<WorkCommandOutputStream, String> _pendingLines = {
    WorkCommandOutputStream.stdout: '',
    WorkCommandOutputStream.stderr: '',
  };

  _OutputCollector({
    required this.limit,
    required this.scanner,
    required this.sink,
    required this.requestStop,
  });

  void add(WorkCommandOutputStream stream, List<int> bytes) {
    if (bytes.isEmpty || truncated) return;
    final remaining = limit - usedBytes;
    final acceptedLength = bytes.length.clamp(0, remaining).toInt();
    final accepted = bytes.sublist(0, acceptedLength);
    usedBytes += acceptedLength;
    if (accepted.isNotEmpty) {
      final raw = utf8.decode(accepted, allowMalformed: true);
      final combined = '${_pendingLines[stream]}$raw';
      final lineEnd = combined.lastIndexOf('\n');
      if (lineEnd >= 0) {
        final complete = combined.substring(0, lineEnd + 1);
        _pendingLines[stream] = combined.substring(lineEnd + 1);
        _emitSafe(stream, complete);
      } else {
        _pendingLines[stream] = combined;
      }
    }
    if (acceptedLength < bytes.length) {
      truncated = true;
      requestStop(_StopReason.outputLimit);
    }
  }

  void flush(WorkCommandOutputStream stream) {
    final pending = _pendingLines[stream] ?? '';
    if (pending.isEmpty) return;
    _pendingLines[stream] = '';
    _emitSafe(stream, pending);
  }

  void _emitSafe(WorkCommandOutputStream stream, String raw) {
    final safe = scanner.redact(raw, includeOpaqueTokens: true);
    if (safe.isEmpty) return;
    if (stream == WorkCommandOutputStream.stdout) {
      stdout += safe;
    } else {
      stderr += safe;
    }
    _emit(
      WorkCommandOutputChunk(
        stream: stream,
        text: safe,
        byteLength: utf8.encode(safe).length,
      ),
    );
  }

  void _emit(WorkCommandOutputChunk chunk) {
    final callback = sink;
    if (callback == null) return;
    try {
      final result = callback(chunk);
      if (result is Future<void>) {
        unawaited(result.catchError((Object _) {}));
      }
    } on Object {
      // Output observers must not keep a child process alive or change its
      // result. The durable event store performs its own error accounting.
    }
  }
}

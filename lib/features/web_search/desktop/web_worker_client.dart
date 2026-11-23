import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Owns a private, bundled gateway process. Never resolves executables via PATH.
class WebWorkerClient {
  WebWorkerClient({required this.executable, required this.entryPoint});

  static bool get isSupported =>
      !kIsWeb && (Platform.isMacOS || Platform.isWindows);

  factory WebWorkerClient.bundled() {
    if (!isSupported) {
      throw UnsupportedError('此平台联网工具未实现。');
    }
    final base = p.dirname(Platform.resolvedExecutable);
    final root = Platform.isMacOS
        ? p.normalize(p.join(base, '..', 'Resources', 'web_worker'))
        : p.join(base, 'web_worker');
    _bundledPool ??= WebWorkerPool(() => WebWorkerClient(
          executable: p.join(root, Platform.isWindows ? 'node.exe' : 'node'),
          entryPoint: p.join(root, 'src', 'desktop_worker.ts'),
        ));
    return _bundledPool!.acquire();
  }

  static WebWorkerPool? _bundledPool;

  final String executable;
  final String entryPoint;
  Process? _process;
  Future<void>? _starting;
  int _sequence = 0;
  bool _closed = false;
  final _pending = <String, StreamController<Map<String, dynamic>>>{};

  Future<void> _start() => _starting ??= _launch().catchError((Object error) {
        _starting = null;
        throw error;
      });

  Future<void> _launch() async {
    if (_closed) throw StateError('联网工具已关闭。');
    final process = await Process.start(
      executable,
      ['--experimental-strip-types', entryPoint],
      runInShell: false,
      includeParentEnvironment: false,
    );
    if (_closed) {
      process.kill();
      throw StateError('联网工具已关闭。');
    }
    _process = process;
    process.stderr.drain<void>();
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
      (line) {
        if (!identical(_process, process)) return;
        try {
          if (line.length > 100000) throw const FormatException();
          final value = jsonDecode(line);
          if (value is! Map<String, dynamic> || value['id'] is! String) {
            throw const FormatException();
          }
          _pending[value['id']]?.add(value);
        } on Object {
          _failAll(StateError('联网工具返回无效协议。'));
          process.kill();
        }
      },
      onError: (Object _) {
        if (!identical(_process, process)) return;
        _failAll(StateError('联网工具通信中断。'));
        process.kill();
      },
    );
    unawaited(process.stdin.done.then<void>((_) {}, onError: (Object _) {
      process.kill();
    }));
    unawaited(process.exitCode.then((_) {
      if (!identical(_process, process)) return;
      _process = null;
      _starting = null;
      _failAll(StateError('联网工具已退出。'));
    }));
    try {
      final reply = await _request(process, {'operation': 'hello'})
          .first
          .timeout(const Duration(seconds: 5));
      if (reply['status'] != 'ok' || reply['version'] != 1) {
        throw StateError('联网工具版本不兼容。');
      }
    } on Object {
      process.kill();
      await process.exitCode;
      rethrow;
    }
  }

  Stream<Map<String, dynamic>> request(Map<String, dynamic> arguments) async* {
    await _start();
    final process = _process;
    if (_closed || process == null) throw StateError('联网工具不可用。');
    yield* _request(process, arguments);
  }

  Stream<Map<String, dynamic>> _request(
      Process process, Map<String, dynamic> arguments) async* {
    final id = 'web_${++_sequence}';
    final controller = StreamController<Map<String, dynamic>>();
    _pending[id] = controller;
    try {
      process.stdin.writeln(jsonEncode({...arguments, 'id': id}));
      await for (final frame
          in controller.stream.timeout(const Duration(seconds: 30))) {
        yield frame;
        if (const {'ok', 'done', 'error'}.contains(frame['status'])) return;
      }
    } finally {
      _pending.remove(id);
      if (!_closed && identical(_process, process)) {
        process.stdin.writeln(jsonEncode({'id': id, 'operation': 'cancel'}));
      }
      unawaited(controller.close());
    }
  }

  Future<void> handshake() async {
    final reply = await request({'operation': 'hello'}).first;
    if (reply['status'] != 'ok' || reply['version'] != 1) {
      close();
      throw StateError('联网工具版本不兼容。');
    }
  }

  void _failAll(Object error) {
    for (final controller in _pending.values.toList()) {
      controller.addError(error);
      unawaited(controller.close());
    }
    _pending.clear();
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _failAll(StateError('联网工具已关闭。'));
    _process?.kill();
    _process = null;
  }
}

/// Ref-counted leases keep concurrent app features on one private process.
class WebWorkerPool {
  WebWorkerPool(this.create);
  final WebWorkerClient Function() create;
  WebWorkerClient? _client;
  int _leases = 0;

  WebWorkerClient acquire() {
    final client = _client ??= create();
    _leases++;
    return _WebWorkerLease(client, () {
      if (--_leases == 0) {
        client.close();
        _client = null;
      }
    });
  }
}

class _WebWorkerLease extends WebWorkerClient {
  _WebWorkerLease(this.client, this.release)
      : super(executable: client.executable, entryPoint: client.entryPoint);
  final WebWorkerClient client;
  final void Function() release;
  bool _released = false;
  final _subscriptions = <StreamSubscription<Map<String, dynamic>>,
      StreamController<Map<String, dynamic>>>{};

  @override
  Stream<Map<String, dynamic>> request(Map<String, dynamic> arguments) {
    if (_released) return Stream.error(StateError('联网会话已关闭。'));
    late StreamController<Map<String, dynamic>> controller;
    StreamSubscription<Map<String, dynamic>>? subscription;
    controller = StreamController(onListen: () {
      subscription = client
          .request(arguments)
          .listen(controller.add, onError: controller.addError, onDone: () {
        _subscriptions.remove(subscription);
        unawaited(controller.close());
      });
      _subscriptions[subscription!] = controller;
    }, onCancel: () async {
      final current = subscription;
      _subscriptions.remove(current);
      await current?.cancel();
    });
    return controller.stream;
  }

  @override
  void close() {
    if (_released) return;
    _released = true;
    for (final entry in _subscriptions.entries.toList()) {
      unawaited(entry.key.cancel());
      unawaited(entry.value.close());
    }
    _subscriptions.clear();
    release();
  }
}

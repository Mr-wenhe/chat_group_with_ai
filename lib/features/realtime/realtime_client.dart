import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'realtime_protocol.dart';
import 'realtime_socket.dart';

/// 连接所处的阶段。界面据此决定显示「连接中」还是「已断开」。
enum RealtimeConnectionState {
  /// 还没开始连。
  idle,

  /// 正在建立连接，或已连上但还没收到服务端的 `joined`。
  connecting,

  /// 已入群，可以收发消息。
  connected,

  /// 掉线了，正在按退避策略重试。
  reconnecting,

  /// 被服务端明确拒绝，不再重试（房间满、协议不符等）。
  closed,
}

/// 与实时中继的一条群聊连接。
///
/// 只做三件事：连上并入群、把服务端帧解析成事件流、掉线后自动重连。
/// 它不碰 Hive、不碰 UI，所以连接状态流转和重连退避都可以脱离 Flutter 单测——
/// 这两块恰恰是手工点击最难验、又最容易出错的部分。
class RealtimeClient {
  RealtimeClient({
    required this.uri,
    required this.roomId,
    required this.userId,
    required this.displayName,
    RealtimeSocketOpener opener = openRealtimeSocket,
    Duration reconnectBaseDelay = const Duration(seconds: 1),
    Duration reconnectMaxDelay = const Duration(seconds: 30),
    Random? random,
  })  : _opener = opener,
        _reconnectBaseDelay = reconnectBaseDelay,
        _reconnectMaxDelay = reconnectMaxDelay,
        _random = random ?? Random();

  /// 已经带好共享令牌的 `ws://` 地址。
  final Uri uri;
  final String roomId;
  final String userId;
  final String displayName;

  final RealtimeSocketOpener _opener;
  final Duration _reconnectBaseDelay;
  final Duration _reconnectMaxDelay;
  final Random _random;

  final _events = StreamController<RealtimeServerEvent>.broadcast();
  final _state = ValueNotifier<RealtimeConnectionState>(RealtimeConnectionState.idle);

  RealtimeSocket? _socket;
  StreamSubscription<String>? _subscription;
  Timer? _retryTimer;
  int _attempt = 0;
  bool _disposed = false;
  bool _rejectedByServer = false;

  /// 服务端下行事件：入群回执、群消息、成员进出、错误。
  Stream<RealtimeServerEvent> get events => _events.stream;

  /// 连接状态，可直接交给 `ValueListenableBuilder`。
  ValueListenable<RealtimeConnectionState> get state => _state;

  /// 发起首次连接。重复调用是安全的：已连上时直接返回。
  Future<void> connect() async {
    if (_disposed || _socket != null) return;
    _state.value = RealtimeConnectionState.connecting;
    await _openOnce();
  }

  /// 发送一条群消息。
  ///
  /// [speaker] 用于主人端替本机 AI 角色发言，让客人端知道这句话是谁说的；
  /// 传 null 表示说话的就是本账号。
  ///
  /// 返回 false 表示当前没连上、这条消息没能发出去——调用方应当把消息留在本地
  /// 并提示用户，而不是假装发送成功。
  bool say(String text, {RealtimeSpeaker? speaker}) {
    final socket = _socket;
    if (socket == null || _state.value != RealtimeConnectionState.connected) {
      return false;
    }
    socket.send(encodeRealtimeSay(text, speaker: speaker));
    return true;
  }

  Future<void> dispose() async {
    _disposed = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    await _subscription?.cancel();
    _subscription = null;
    await _socket?.close();
    _socket = null;
    await _events.close();
    _state.dispose();
  }

  Future<void> _openOnce() async {
    try {
      final socket = await _opener(uri);
      if (_disposed) {
        await socket.close();
        return;
      }
      _socket = socket;
      // 服务端要求连接后限时入群，所以 join 必须紧跟握手发出去。
      socket.send(encodeRealtimeJoin(
        roomId: roomId,
        userId: userId,
        displayName: displayName,
      ));
      _subscription = socket.messages.listen(
        _handleFrame,
        onError: (Object _) => _handleDisconnect(),
        onDone: _handleDisconnect,
        cancelOnError: true,
      );
    } on Object {
      _handleDisconnect();
    }
  }

  void _handleFrame(String raw) {
    final event = parseRealtimeServerEvent(raw);
    if (event == null) {
      // 单条坏帧不该拖垮整条连接：丢掉并记录，继续收后续帧。
      debugPrint('实时群聊：无法解析的服务端帧 ${raw.length} 字节');
      return;
    }
    switch (event) {
      case RealtimeJoined():
        // 只有真正入群了才算连上；此前一直停在 connecting。
        _attempt = 0;
        // 上一次被拒绝之后服务端可能已经腾出位置（比如有人退群），
        // 这一轮既然进来了，就不能再拿旧结论否决后续重连。
        _rejectedByServer = false;
        _state.value = RealtimeConnectionState.connected;
      case RealtimeErrorEvent():
        // 服务端明确拒绝时重连只会重复失败，直接停下并让界面说明原因。
        _rejectedByServer = true;
      case RealtimeIncomingMessage():
      case RealtimePresence():
        break;
    }
    if (!_events.isClosed) _events.add(event);
  }

  void _handleDisconnect() {
    unawaited(_subscription?.cancel());
    _subscription = null;
    _socket = null;
    if (_disposed) return;

    if (_rejectedByServer) {
      _state.value = RealtimeConnectionState.closed;
      return;
    }

    _state.value = RealtimeConnectionState.reconnecting;
    _retryTimer?.cancel();
    _retryTimer = Timer(_nextDelay(), () {
      if (_disposed) return;
      unawaited(_openOnce());
    });
  }

  Duration _nextDelay() {
    // 指数退避封顶在 _reconnectMaxDelay。先夹住指数再乘，避免尝试次数一多
    // 就构造出一个溢出的 Duration。
    final exponent = _attempt > 16 ? 16 : _attempt;
    _attempt++;
    final exponential = _reconnectBaseDelay * pow(2, exponent).toDouble();
    final capped = exponential > _reconnectMaxDelay ? _reconnectMaxDelay : exponential;
    // 抖动：否则所有客户端会在服务端重启后同一毫秒一起回来。
    return capped + Duration(milliseconds: _random.nextInt(500));
  }
}

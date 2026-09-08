import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'volcengine_frame_codec.dart';
import 'volcengine_ws_types.dart';

/// 火山引擎流式语音识别（SAUC bigmodel / bigasr）WebSocket 端点。
const String volcAsrDefaultUrl =
    'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel';

/// ASR 会话默认用户标识。
const String _uid = 'flutter-voice-user';

/// ASR 会话级错误。
class VolcengineAsrException implements Exception {
  VolcengineAsrException(this.message);
  final String message;
  @override
  String toString() => 'VolcengineAsrException: $message';
}

/// 一次流式识别会话。参考工程 `virtual/src/backend/asr.js` 的状态机移植：
/// 建立连接→发送 JSON 启动帧→持续发送裸 PCM→收到中间/最终识别结果→
/// 结束帧收尾。一个会话对象只用一次。
class VolcengineAsrSession {
  VolcengineAsrSession({
    required this.open,
    required this.apiKey,
    required this.resourceId,
    String url = volcAsrDefaultUrl,
    this.idleTimeout = const Duration(seconds: 30),
  })  : _url = url,
        _connectId = 'asr-${DateTime.now().microsecondsSinceEpoch}';

  final VolcSocketOpener open;
  final String apiKey;
  final String resourceId;
  final Duration idleTimeout;
  final String _url;
  final String _connectId;

  /// 每次服务端下发识别文本；`isFinal=true` 表示该段已定稿。
  void Function(String text, bool isFinal)? onResult;

  /// 会话级错误（连接失败/超时/服务端错误）。
  void Function(String message)? onError;

  /// 会话正常结束（用户 `finish()` 或服务端收尾后）。
  void Function()? onEnd;

  VolcWsSocket? _socket;
  StreamSubscription<Uint8List>? _sub;
  Timer? _watchdog;
  bool _active = false;
  bool _ended = false;

  bool get isActive => _active;

  /// 建立连接并发送启动帧。麦克风开始采集前 await 本方法可避免丢首帧。
  Future<void> start() async {
    if (_active) return;
    final VolcWsSocket socket;
    try {
      socket = await open(_url, {
        'X-Api-Key': apiKey,
        'X-Api-Resource-Id': resourceId,
        'X-Api-Connect-Id': _connectId,
      });
    } catch (e) {
      _fireError('语音连接失败: $e');
      return;
    }
    _socket = socket;
    _active = true;
    _armWatchdog();

    _sub = socket.messages.listen(
      (bytes) {
        try {
          _armWatchdog(); // 任一服务端帧 = 会话活跃，重置空闲窗口。
          _handleFrame(bytes);
        } catch (e) {
          _fireError('ASR 帧处理异常: $e');
          _close();
        }
      },
      onError: (Object e) {
        _fireError('语音连接错误: $e');
        _close();
      },
      onDone: () {
        if (_active && !_ended) {
          _fireError('语音连接已关闭');
        }
        _close();
      },
    );

    // 连接建立即发送 JSON 启动帧。
    socket.send(buildVolcAsrStartFrame({
      'user': {'uid': _uid},
      'audio': {'format': 'pcm', 'sample_rate': 16000, 'channel': 1, 'bits': 16},
      'request': {
        'reqid': _connectId,
        'sequence': 1,
        'show_utterances': true,
        'result_type': 'single',
        'enable_itn': true,
        'enable_punc': true,
        'end_window_size': 800,
        'force_to_speech_time': 1000,
      },
    }));
  }

  /// 发送一包 16k/16bit/单声道 PCM。末包请置 `isLast=true`。
  void sendAudio(List<int> pcm, {bool isLast = false}) {
    if (!_active || _ended) return;
    _socket?.send(buildVolcAsrAudioFrame(pcm, isLast: isLast));
  }

  /// 请求结束会话：发送结束帧，留出窗口等最终结果，再收尾。
  Future<void> finish() async {
    if (_ended) return;
    _ended = true;
    if (_active) {
      try {
        _socket?.send(buildVolcAsrFinishFrame(_connectId));
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    _close();
    onEnd?.call();
  }

  /// 立即放弃会话（不等待结果）。
  void cancel() {
    if (_ended && !_active) return;
    _ended = true;
    _close();
  }

  void _handleFrame(Uint8List bytes) {
    final f = parseVolcAsrFrame(bytes);
    if (f.msgType == volcMsgError) {
      _fireError('ASR 服务端错误: code=${f.errorCode} '
          '${utf8.decode(f.payload, allowMalformed: true)}');
      _close();
      return;
    }
    if (f.msgType != volcMsgJsonServer) return; // 其余帧（音频回传等）忽略。

    final dynamic json;
    try {
      json = jsonDecode(utf8.decode(f.payload, allowMalformed: true));
    } catch (_) {
      return; // 中间控制帧可能不是 JSON，忽略。
    }
    final code = (json as Map<String, dynamic>)['code'];
    if (code is num && code != 0) {
      _fireError('ASR 会话错误: code=$code ${json['message'] ?? ''}');
      _close();
      return;
    }
    final result = json['result'];
    if (result is! Map) return;
    final text = result['text'];
    final utterances = result['utterances'];
    if ((text == null || text.toString().isEmpty) &&
        (utterances is! List || utterances.isEmpty)) {
      return; // 中间控制帧。
    }
    final definite = (utterances as List? ?? [])
        .any((u) => u is Map && u['definite'] == true);
    final isFinal = f.flags == 0x2 || f.flags == 0x3 || definite;
    onResult?.call(text?.toString() ?? '', isFinal);
  }

  void _armWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer(idleTimeout, () {
      if (_ended) return;
      _fireError('ASR 会话超时');
      _close();
    });
  }

  void _fireError(String message) {
    if (_ended) return;
    onError?.call(message);
  }

  void _close() {
    _active = false;
    _watchdog?.cancel();
    _watchdog = null;
    unawaited(_sub?.cancel());
    _sub = null;
    final s = _socket;
    _socket = null;
    if (s != null) {
      unawaited(s.close());
    }
  }
}

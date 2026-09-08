import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'volcengine_frame_codec.dart';
import 'volcengine_ws_types.dart';

/// 火山引擎大模型语音合成（seed-tts / BidirectionalTTS）WebSocket 端点。
const String volcTtsDefaultUrl =
    'wss://openspeech.bytedance.com/api/v3/tts/bidirection';

/// 默认会话用户标识（服务端示例约定值）。
const String _uid = 'flutter-voice-user';

/// TTS 合成失败（网络/协议/服务端错误/超时）。
class VolcengineTtsException implements Exception {
  VolcengineTtsException(this.message);
  final String message;
  @override
  String toString() => 'VolcengineTtsException: $message';
}

/// 一次 TTS 合成结果：整句 PCM（16bit / 单声道 / [sampleRate]Hz）或错误。
class VolcengineTtsResult {
  VolcengineTtsResult({required this.pcm});
  final Uint8List pcm;
}

/// 火山 BidirectionalTTS 客户端：每次 `synthesize` 建立一条新连接，
/// 完成连接握手→开启会话→提交文本→收齐 PCM→结束会话。参考工程
/// `virtual/src/backend/volcengine.js` 的实现移植。
///
/// 仅负责帧协议与事件状态机；实际数据通过注入的 [VolcSocketOpener]
/// 收发，便于测试用内存 socket 驱动。
class VolcengineTtsClient {
  VolcengineTtsClient({
    required this.open,
    this.timeout = const Duration(seconds: 20),
  });

  final VolcSocketOpener open;

  /// 单次合成看门狗：超时未收到结束帧即报错。
  final Duration timeout;

  /// 合成 [text] 为 PCM 音频。
  ///
  /// [speaker] 为音色 id（见 `voice.md`）；[resourceId] 通常为
  /// `seed-tts-1.0`；[apiKey] 即火山 API Key；三者的 HTTP 头与
  /// `X-Api-*` 一一对应。
  Future<Uint8List> synthesize({
    required String text,
    required String speaker,
    required String resourceId,
    required String apiKey,
    String url = volcTtsDefaultUrl,
    int sampleRate = 24000,
    String? connectId,
    String? sessionId,
  }) async {
    if (text.trim().isEmpty) return Uint8List(0);
    final now = DateTime.now().microsecondsSinceEpoch;
    final cid = connectId ?? 'tts-$now';
    final sid = sessionId ?? 'sess-${now.toString().substring(now.toString().length - 8)}';

    final VolcWsSocket socket;
    try {
      socket = await open(url, {
        'X-Api-Key': apiKey,
        'X-Api-Resource-Id': resourceId,
        'X-Api-Connect-Id': cid,
      });
    } catch (e) {
      throw VolcengineTtsException('TTS 连接失败: $e');
    }

    final pcm = BytesBuilder(copy: false);
    var finished = false;
    final completer = Completer<Uint8List>();
    final watchdog = Timer(timeout, () {
      if (finished) return;
      finished = true;
      unawaited(socket.close());
      completer.completeError(VolcengineTtsException('TTS 合成超时'));
    });

    void fail(VolcengineTtsException e) {
      if (finished) return;
      finished = true;
      watchdog.cancel();
      unawaited(socket.close());
      if (!completer.isCompleted) completer.completeError(e);
    }

    void succeed() {
      if (finished) return;
      finished = true;
      watchdog.cancel();
      unawaited(socket.close());
      if (!completer.isCompleted) completer.complete(pcm.toBytes());
    }

    StreamSubscription<Uint8List>? sub;
    sub = socket.messages.listen(
      (bytes) {
        try {
          final f = parseVolcTtsFrame(bytes);
          switch (f.event) {
            case 50: // ConnectionStarted → 开启会话（携带 speaker/音频格式）。
              socket.send(buildVolcSessionFrame(
                event: 100,
                sessionId: sid,
                payload: {
                  'user': {'uid': _uid},
                  'event': 100,
                  'req_params': {
                    'speaker': speaker,
                    'audio_params': {
                      'format': 'pcm',
                      'sample_rate': sampleRate,
                      'enable_timestamp': true,
                    },
                  },
                },
              ));
              break;
            case 150: // SessionStarted → 提交文本并请求结束会话。
              socket.send(buildVolcSessionFrame(
                event: 200,
                sessionId: sid,
                payload: {
                  'user': {'uid': _uid},
                  'event': 200,
                  'req_params': {'text': text},
                },
              ));
              socket.send(buildVolcSessionFrame(
                event: 102,
                sessionId: sid,
                payload: {
                  'user': {'uid': _uid},
                  'event': 102,
                },
              ));
              break;
            case 152: // SessionFinished → 合成成功。
              succeed();
              break;
            case 153: // SessionFailed。
              fail(VolcengineTtsException(
                  'TTS SessionFailed: ${utf8.decode(f.payload, allowMalformed: true)}'));
              break;
            case 351: // TTSSentenceEnd（时间戳），本实现不需要词级时间戳。
              break;
            default:
              if (f.msgType == volcMsgAudioOnlyServer && f.payload.isNotEmpty) {
                pcm.add(f.payload);
              } else if (f.msgType == volcMsgError) {
                fail(VolcengineTtsException(
                    'TTS error frame: ${utf8.decode(f.payload, allowMalformed: true)}'));
              }
          }
        } catch (e) {
          fail(e is VolcengineTtsException
              ? e
              : VolcengineTtsException('TTS 帧处理异常: $e'));
        }
      },
      onError: (Object e) {
        fail(VolcengineTtsException('TTS 连接错误: $e'));
      },
      onDone: () {
        if (!finished) {
          fail(VolcengineTtsException('TTS 连接提前关闭'));
        }
      },
    );

    // 连接建立后立刻发送连接请求帧。
    socket.send(buildVolcConnectionFrame(
      event: 1,
      payload: {'namespace': 'BidirectionalTTS'},
    ));

    try {
      return await completer.future;
    } finally {
      await sub.cancel();
      watchdog.cancel();
    }
  }
}

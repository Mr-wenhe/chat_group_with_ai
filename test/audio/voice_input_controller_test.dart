import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:chat_group/core/audio/voice_input_controller.dart';
import 'package:chat_group/core/audio/voice_mic_source.dart';
import 'package:chat_group/core/audio/volcengine_asr.dart';
import 'package:chat_group/core/audio/volcengine_frame_codec.dart';
import 'package:chat_group/core/audio/volcengine_ws_types.dart';
import 'package:flutter_test/flutter_test.dart';

/// 内存假 socket（与 volcengine_clients_test 同款，测试文件间不共享避免耦合）。
class _FakeSocket implements VolcWsSocket {
  final sent = <Uint8List>[];
  final _incoming = StreamController<Uint8List>();
  bool closed = false;

  @override
  Stream<Uint8List> get messages => _incoming.stream;

  @override
  void send(Uint8List bytes) => sent.add(bytes);

  @override
  Future<void> close() async {
    closed = true;
    await _incoming.close();
  }

  void push(Uint8List bytes) => _incoming.add(bytes);
}

class _OpenRecorder {
  _FakeSocket? last;
  Future<VolcWsSocket> Function(String, Map<String, String>) get opener =>
      (url, headers) async {
        final s = _FakeSocket();
        last = s;
        return s;
      };
}

/// 假麦克风：权限可控，可用受控 StreamController 推入 PCM。
class _FakeMic implements VoiceMicSource {
  bool granted = true;
  final _stream = StreamController<Uint8List>();
  bool started = false;
  bool stopped = false;
  bool disposed = false;
  int lastSampleRate = 0;

  @override
  Future<bool> hasPermission() async => granted;

  @override
  Future<Stream<Uint8List>> startStream({int sampleRate = 16000}) async {
    started = true;
    stopped = false;
    lastSampleRate = sampleRate;
    return _stream.stream;
  }

  @override
  Future<void> stop() async {
    stopped = true;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await _stream.close();
  }
}

/// 构造 ASR 服务端 JSON 结果帧。
Uint8List _resultFrame({
  required int flags,
  required int sequence,
  required String text,
  bool definite = false,
}) {
  final payload = utf8.encode(jsonEncode({
    'code': 0,
    'result': {
      'text': text,
      'utterances': definite
          ? [
              {'text': text, 'definite': true},
            ]
          : <Object>[],
    },
  }));
  final out = BytesBuilder(copy: false)
    ..add(Uint8List.fromList(
        [0x11, (volcMsgJsonServer << 4) | flags, volcSerJson << 4, 0]));
  out.add(Uint8List.sublistView(ByteData(4)..setInt32(0, sequence)));
  out.add(Uint8List.sublistView(ByteData(4)..setUint32(0, payload.length)));
  out.add(payload);
  return out.toBytes();
}

Future<void> _flush([int turns = 10]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('VoiceInputController', () {
    test('start→interim/final 汇入文案→喂音频→stop 末包收尾', () async {
      final rec = _OpenRecorder();
      final mic = _FakeMic();
      final controller = VoiceInputController(
        mic: mic,
        createSession: () => VolcengineAsrSession(
          open: rec.opener,
          apiKey: 'secret-key',
          resourceId: 'volc.bigasr.sauc.duration',
        ),
      );
      final displayHistory = <String>[];
      String? error;
      controller.onDisplayChanged = displayHistory.add;
      controller.onError = (m) => error = m;

      expect(await controller.start(), isNull);
      expect(controller.phase, VoiceInputPhase.listening);
      expect(mic.started, isTrue);
      expect(mic.lastSampleRate, 16000);
      expect(controller.committedText, '');

      final socket = rec.last!;
      // interim → display 只含候补；final → 定稿进 committed。
      socket.push(_resultFrame(flags: 0x1, sequence: 2, text: '你'));
      await _flush();
      socket.push(
          _resultFrame(flags: 0x3, sequence: 3, text: '你好世界', definite: true));
      await _flush();
      expect(displayHistory.last, '你好世界');
      expect(controller.committedText, '你好世界');

      // 喂一段音频 → 应转成音频帧发给服务端。
      mic._stream.add(Uint8List.fromList(List<int>.filled(3200, 0)));
      await _flush();
      final sentBeforeStop = socket.sent.map(parseVolcAsrFrame).toList();
      expect(sentBeforeStop.where((f) => f.msgType == volcMsgAudioOnly),
          isNotEmpty);

      await controller.stop();
      await _flush();
      expect(controller.phase, VoiceInputPhase.idle);
      expect(mic.stopped, isTrue);
      expect(controller.committedText, '你好世界');
      expect(error, isNull);

      // 收尾帧链：最后一帧是结束帧（event=2），其前是带末包标记的音频帧。
      final sent = socket.sent.map(parseVolcAsrFrame).toList();
      final finishJson = jsonDecode(utf8.decode(socket.sent.last.sublist(8)))
          as Map<String, dynamic>;
      expect(finishJson['event'], 2);
      expect(
          sent.where((f) =>
              f.msgType == volcMsgAudioOnly && (f.flags & volcFlagLast) != 0),
          hasLength(1));
    });

    test('拒绝权限时 start 返回错误且不建立会话', () async {
      final rec = _OpenRecorder();
      final mic = _FakeMic()..granted = false;
      final controller = VoiceInputController(
        mic: mic,
        createSession: () => VolcengineAsrSession(
            open: rec.opener, apiKey: 'k', resourceId: 'r'),
      );
      expect(await controller.start(), contains('麦克风权限'));
      expect(rec.last, isNull);
      expect(controller.phase, VoiceInputPhase.idle);
    });

    test('cancel 丢弃文本且不等待最终结果', () async {
      final rec = _OpenRecorder();
      final mic = _FakeMic();
      final controller = VoiceInputController(
        mic: mic,
        createSession: () => VolcengineAsrSession(
            open: rec.opener, apiKey: 'k', resourceId: 'r'),
      );
      await controller.start();
      final socket = rec.last!;
      socket.push(
          _resultFrame(flags: 0x3, sequence: 2, text: '已识别内容', definite: true));
      await _flush();

      await controller.cancel();
      expect(controller.phase, VoiceInputPhase.idle);
      expect(controller.committedText, isEmpty);
      expect(mic.stopped, isTrue);
    });

    test('服务端错误在聆听中触发 onError 并复位', () async {
      final rec = _OpenRecorder();
      final mic = _FakeMic();
      final controller = VoiceInputController(
        mic: mic,
        createSession: () => VolcengineAsrSession(
            open: rec.opener, apiKey: 'k', resourceId: 'r'),
      );
      final errors = <String>[];
      controller.onError = errors.add;
      await controller.start();
      final socket = rec.last!;
      final errPayload = utf8.encode('waiting data timeout');
      final frame = BytesBuilder(copy: false)
        ..add(Uint8List.fromList([0x11, volcMsgError << 4, 0, 0]));
      frame.add(Uint8List.sublistView(ByteData(4)..setUint32(0, 45000081)));
      frame.add(
          Uint8List.sublistView(ByteData(4)..setUint32(0, errPayload.length)));
      frame.add(errPayload);
      socket.push(frame.toBytes());
      await _flush();

      expect(errors, hasLength(1));
      expect(controller.phase, VoiceInputPhase.idle);
      expect(mic.stopped, isTrue);
    });
  });
}

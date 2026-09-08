import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:chat_group/core/audio/volcengine_asr.dart';
import 'package:chat_group/core/audio/volcengine_frame_codec.dart';
import 'package:chat_group/core/audio/volcengine_tts.dart';
import 'package:chat_group/core/audio/volcengine_ws_types.dart';
import 'package:flutter_test/flutter_test.dart';

/// 内存假 socket：捕获上行帧、可注入下行帧。
class FakeVolcSocket implements VolcWsSocket {
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

/// 记录每次 open 的 (headers, socket)。
class OpenRecorder {
  final opened = <({String url, Map<String, String> headers, FakeVolcSocket socket})>[];

  Future<VolcWsSocket> Function(String, Map<String, String>) get opener =>
      (url, headers) async {
        final s = FakeVolcSocket();
        opened.add((url: url, headers: headers, socket: s));
        return s;
      };

  FakeVolcSocket get single => opened.single.socket;
}

/// 手工构造 TTS 服务端事件帧。
Uint8List _serverEventFrame({
  required int event,
  String sessionId = '',
  String connectId = '',
  List<int> payload = const [],
}) {
  final out = BytesBuilder(copy: false)
    ..add(Uint8List.fromList([0x11, 0x14, 0x10, 0]));
  out.add(Uint8List.sublistView(ByteData(4)..setInt32(0, event)));
  if (!const {1, 2, 50, 51, 52}.contains(event)) {
    out.add(Uint8List.sublistView(
        ByteData(4)..setUint32(0, utf8.encode(sessionId).length)));
    out.add(utf8.encode(sessionId));
  }
  if (const {50, 51, 52}.contains(event)) {
    out.add(Uint8List.sublistView(
        ByteData(4)..setUint32(0, utf8.encode(connectId).length)));
    out.add(utf8.encode(connectId));
  }
  out.add(Uint8List.sublistView(ByteData(4)..setUint32(0, payload.length)));
  out.add(payload);
  return out.toBytes();
}

/// 构造 TTS 服务端音频帧（msgType=0xB，无 event 字段）。
Uint8List _audioServerFrame(List<int> pcm) {
  final out = BytesBuilder(copy: false)
    ..add(Uint8List.fromList([0x11, volcMsgAudioOnlyServer << 4, 0, 0]));
  out.add(Uint8List.sublistView(ByteData(4)..setUint32(0, pcm.length)));
  out.add(pcm);
  return out.toBytes();
}

/// 构造 ASR 服务端 JSON 结果帧。
Uint8List _asrResultFrame({
  required int flags,
  required int sequence,
  required Map<String, Object?> body,
}) {
  final payload = utf8.encode(jsonEncode(body));
  final out = BytesBuilder(copy: false)
    ..add(Uint8List.fromList(
        [0x11, (volcMsgJsonServer << 4) | flags, volcSerJson << 4, 0]));
  out.add(Uint8List.sublistView(ByteData(4)..setInt32(0, sequence)));
  out.add(Uint8List.sublistView(ByteData(4)..setUint32(0, payload.length)));
  out.add(payload);
  return out.toBytes();
}

/// 构造 ASR 服务端错误帧。
Uint8List _asrErrorFrame(int errorCode, String text) {
  final payload = utf8.encode(text);
  final out = BytesBuilder(copy: false)
    ..add(Uint8List.fromList([0x11, volcMsgError << 4, 0, 0]));
  out.add(Uint8List.sublistView(ByteData(4)..setUint32(0, errorCode)));
  out.add(Uint8List.sublistView(ByteData(4)..setUint32(0, payload.length)));
  out.add(payload);
  return out.toBytes();
}

Future<void> _flush([int turns = 8]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('VolcengineTtsClient', () {
    test('完整握手：连接→会话→提交文本→收 PCM→结束', () async {
      final rec = OpenRecorder();
      final client = VolcengineTtsClient(open: rec.opener);

      final fut = client.synthesize(
        text: '你好，世界。',
        speaker: 'zh_female_meilinvyou_moon_bigtts',
        resourceId: 'seed-tts-1.0',
        apiKey: 'secret-key',
      );
      await _flush();
      expect(rec.opened, hasLength(1));
      expect(rec.opened.single.url, volcTtsDefaultUrl);
      expect(rec.opened.single.headers['X-Api-Key'], 'secret-key');
      expect(rec.opened.single.headers['X-Api-Resource-Id'], 'seed-tts-1.0');

      final s = rec.single;
      // ① 连接请求帧。
      expect(parseVolcTtsFrame(s.sent[0]).event, 1);

      // ② ConnectionStarted → 客户端应发 session 开启帧（event=100）。
      s.push(_serverEventFrame(
          event: 50, connectId: 'conn-x', payload: utf8.encode('{}')));
      await _flush();
      final started =
          s.sent.map(parseVolcTtsFrame).firstWhere((f) => f.event == 100);
      final startedJson =
          jsonDecode(utf8.decode(started.payload)) as Map<String, dynamic>;
      expect((startedJson['req_params'] as Map)['speaker'],
          'zh_female_meilinvyou_moon_bigtts');
      expect(
          ((startedJson['req_params'] as Map)['audio_params'] as Map)[
              'sample_rate'],
          24000);

      // ③ SessionStarted → 提交文本（200）与结束会话（102）。
      s.push(_serverEventFrame(
          event: 150, sessionId: 'sess-1', payload: utf8.encode('{}')));
      await _flush();
      final events =
          s.sent.map(parseVolcTtsFrame).map((f) => f.event).toList();
      expect(events, containsAll([200, 102]));
      final submit =
          s.sent.map(parseVolcTtsFrame).firstWhere((f) => f.event == 200);
      final submitJson =
          jsonDecode(utf8.decode(submit.payload)) as Map<String, dynamic>;
      expect((submitJson['req_params'] as Map)['text'], '你好，世界。');

      // ④ 服务端推送两段 PCM 音频，随后 SessionFinished。
      final pcm1 = List<int>.generate(4800, (i) => i % 251);
      final pcm2 = List<int>.generate(2400, (i) => (i + 17) % 251);
      s.push(_audioServerFrame(pcm1));
      s.push(_audioServerFrame(pcm2));
      await _flush();
      s.push(_serverEventFrame(
          event: 152, sessionId: 'sess-1', payload: utf8.encode('{}')));
      await _flush();

      final result = await fut;
      expect(result, orderedEquals([...pcm1, ...pcm2]));
      expect(s.closed, isTrue, reason: '成功后客户端应关闭连接');
    });

    test('SessionFailed 抛异常并关闭连接', () async {
      final rec = OpenRecorder();
      final client = VolcengineTtsClient(open: rec.opener);
      final fut = client.synthesize(
          text: 'x', speaker: 's', resourceId: 'r', apiKey: 'k');
      // 先挂载期望，避免 future 出错时没有监听者。
      final expectation = expectLater(
        fut,
        throwsA(isA<VolcengineTtsException>()
            .having((e) => e.message, 'message', contains('bad voice id'))),
      );
      await _flush();
      final s = rec.single;

      s.push(_serverEventFrame(
          event: 153,
          sessionId: 'sess-1',
          payload: utf8.encode('bad voice id')));
      await _flush();

      await expectation;
      expect(s.closed, isTrue);
    });
  });

  group('VolcengineAsrSession', () {
    test('启动→interim→final→发送音频→结束收尾', () async {
      final rec = OpenRecorder();
      final session = VolcengineAsrSession(
        open: rec.opener,
        apiKey: 'secret-key',
        resourceId: 'volc.bigasr.sauc.duration',
      );
      final results = <(String, bool)>[];
      String? error;
      var ended = false;
      session.onResult = (t, f) => results.add((t, f));
      session.onError = (m) => error = m;
      session.onEnd = () => ended = true;

      await session.start();
      await _flush();
      expect(rec.opened, hasLength(1));
      expect(rec.opened.single.url, volcAsrDefaultUrl);
      final s = rec.single;

      // 启动帧为 JSON（msgType=0x1，无 event 标志）。
      expect(s.sent, hasLength(1));
      final startJson =
          jsonDecode(utf8.decode(s.sent[0].sublist(8))) as Map<String, dynamic>;
      expect((startJson['audio'] as Map)['sample_rate'], 16000);

      // interim 结果（flags=0x1）。
      s.push(_asrResultFrame(
        flags: 0x1,
        sequence: 2,
        body: {
          'code': 0,
          'result': {'text': '你', 'utterances': <Object>[]},
        },
      ));
      await _flush();
      expect(results.last, ('你', false));

      // final 结果（utterances 带 definite）。
      s.push(_asrResultFrame(
        flags: 0x3,
        sequence: 3,
        body: {
          'code': 0,
          'result': {
            'text': '你好世界',
            'utterances': [
              {'text': '你好世界', 'definite': true},
            ],
          },
        },
      ));
      await _flush();
      expect(results.last, ('你好世界', true));

      // 发送音频帧（isLast）→ 帧数为 2（启动 + 音频）。
      session.sendAudio(List<int>.filled(3200, 0), isLast: true);
      await _flush();
      expect(s.sent.length, 2);

      await session.finish();
      await _flush();
      expect(ended, isTrue);
      expect(error, isNull);
      // 最后一帧是结束帧（event=2）。
      final finishJson =
          jsonDecode(utf8.decode(s.sent.last.sublist(8))) as Map<String, dynamic>;
      expect(finishJson['event'], 2);
      expect(s.closed, isTrue);
    });

    test('服务端错误帧触发 onError 并关闭连接', () async {
      final rec = OpenRecorder();
      final session = VolcengineAsrSession(
        open: rec.opener,
        apiKey: 'k',
        resourceId: 'r',
      );
      String? error;
      var endedNormally = false;
      session.onError = (m) => error = m;
      session.onEnd = () => endedNormally = true;

      await session.start();
      await _flush();
      final s = rec.single;
      s.push(_asrErrorFrame(45000081, 'waiting data timeout'));
      await _flush();

      expect(error, contains('45000081'));
      expect(endedNormally, isFalse);
      expect(s.closed, isTrue);
    });
  });
}

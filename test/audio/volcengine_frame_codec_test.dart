import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:chat_group/core/audio/volcengine_frame_codec.dart';
import 'package:flutter_test/flutter_test.dart';

/// 手工构造一个服务端帧（TTS 事件帧），便于断言解析路径。
Uint8List _craftServerFrame({
  required int msgType,
  int flags = 0,
  int serialization = 0,
  int compression = 0,
  int? event,
  String? sessionId,
  String? connectId,
  List<int> payload = const [],
}) {
  final out = BytesBuilder(copy: false)
    ..add(Uint8List.fromList(
        [0x11, (msgType << 4) | flags, (serialization << 4) | compression, 0]));
  if (event != null) {
    out.add(Uint8List.sublistView(ByteData(4)..setInt32(0, event)));
  }
  void addLenPrefixed(List<int> bytes) {
    out.add(Uint8List.sublistView(ByteData(4)..setUint32(0, bytes.length)));
    out.add(bytes);
  }

  if (event != null && !const {1, 2, 50, 51, 52}.contains(event)) {
    addLenPrefixed(utf8.encode(sessionId ?? ''));
  }
  if (event != null && const {50, 51, 52}.contains(event)) {
    addLenPrefixed(utf8.encode(connectId ?? ''));
  }
  addLenPrefixed(payload);
  return out.toBytes();
}

/// 手工构造 ASR 服务端帧。
Uint8List _craftAsrServerFrame({
  required int msgType,
  int flags = 0x1,
  int serialization = 0x1,
  int compression = 0x0,
  int? sequence,
  int? errorCode,
  List<int> payload = const [],
}) {
  final out = BytesBuilder(copy: false)
    ..add(Uint8List.fromList(
        [0x11, (msgType << 4) | flags, (serialization << 4) | compression, 0]));
  if (msgType != volcMsgAudioOnly &&
      (flags == 0x1 || flags == 0x2 || flags == 0x3)) {
    out.add(Uint8List.sublistView(ByteData(4)..setInt32(0, sequence ?? 0)));
  }
  if (msgType == volcMsgError) {
    out.add(Uint8List.sublistView(ByteData(4)..setUint32(0, errorCode ?? 0)));
  }
  out.add(Uint8List.sublistView(ByteData(4)..setUint32(0, payload.length)));
  out.add(payload);
  return out.toBytes();
}

void main() {
  group('VolcEngine TTS 客户端帧构造', () {
    test('连接级帧（event=1）头部正确且可回环解析', () {
      final frame = buildVolcConnectionFrame(
        event: 1,
        payload: {'namespace': 'BidirectionalTTS'},
      );

      expect(frame[0], 0x11);
      // (msgType=0x1 <<4)|flags(0x4) = 0x14
      expect(frame[1], 0x14);
      // (ser=0x1<<4)|comp=0x0 = 0x10
      expect(frame[2], 0x10);
      expect(frame[3], 0x00);

      final parsed = parseVolcTtsFrame(frame);
      expect(parsed.event, 1);
      expect(parsed.msgType, volcMsgFullClient);
      expect(parsed.sessionId, '');
      expect(parsed.connectId, '');
      expect(jsonDecode(utf8.decode(parsed.payload)),
          {'namespace': 'BidirectionalTTS'});
    });

    test('会话级帧（event=100）带 sessionId 且可回环解析', () {
      final frame = buildVolcSessionFrame(
        event: 100,
        sessionId: 'sess-abcd1234',
        payload: {'user': {'uid': 'demo-user'}, 'req_params': {'speaker': 'x'}},
      );
      final parsed = parseVolcTtsFrame(frame);
      expect(parsed.event, 100);
      expect(parsed.sessionId, 'sess-abcd1234');
      expect(parsed.connectId, '');
      expect(parsed.payload, isNotEmpty);
    });
  });

  group('VolcEngine TTS 服务端帧解析', () {
    test('连接级事件（50）携带 connectId，无 sessionId', () {
      final raw = _craftServerFrame(
        msgType: volcMsgFullClient,
        flags: volcFlagEvent,
        serialization: volcSerJson,
        event: 50,
        connectId: 'conn-abc',
        payload: utf8.encode('{}'),
      );
      final parsed = parseVolcTtsFrame(raw);
      expect(parsed.event, 50);
      expect(parsed.connectId, 'conn-abc');
      expect(parsed.sessionId, '');
    });

    test('会话级事件（351/352）携带 sessionId', () {
      final raw = _craftServerFrame(
        msgType: volcMsgFullClient,
        flags: volcFlagEvent,
        serialization: volcSerJson,
        event: 351,
        sessionId: 'sess-xyz',
        payload: utf8.encode('{"res_params":{"words":[]}}'),
      );
      final parsed = parseVolcTtsFrame(raw);
      expect(parsed.event, 351);
      expect(parsed.sessionId, 'sess-xyz');
      expect(jsonDecode(utf8.decode(parsed.payload)),
          {'res_params': {'words': []}});
    });

    test('音频帧 msgType=0xB，payload 为裸 PCM', () {
      final pcm = List<int>.generate(64, (i) => i % 251);
      final raw = _craftServerFrame(
        msgType: volcMsgAudioOnlyServer,
        flags: 0,
        serialization: 0,
        payload: pcm,
      );
      final parsed = parseVolcTtsFrame(raw);
      expect(parsed.msgType, volcMsgAudioOnlyServer);
      expect(parsed.payload, orderedEquals(pcm));
    });
  });

  group('VolcEngine ASR 帧构造/解析', () {
    test('启动帧是 JSON 全客户端帧，头部无 event 标志', () {
      final frame = buildVolcAsrStartFrame({
        'user': {'uid': 'demo'},
        'audio': {'format': 'pcm', 'sample_rate': 16000},
      });
      expect(frame[0], 0x11);
      expect(frame[1], 0x10, reason: 'msgType=0x1, flags=0');
      expect(frame[2], 0x10, reason: 'ser=0x1');
      final json = jsonDecode(utf8.decode(frame.sublist(8)));
      expect(json['audio']['sample_rate'], 16000);
    });

    test('音频帧为裸 PCM，末包 flags=0x2', () {
      final pcm = List<int>.filled(3200, 0x7f);
      final normal = buildVolcAsrAudioFrame(pcm);
      expect(normal[1], 0x20, reason: 'msgType=0x2, flags=0');
      expect(normal[2], 0x00, reason: '裸字节');
      expect(normal.sublist(8), orderedEquals(pcm));

      final last = buildVolcAsrAudioFrame(pcm, isLast: true);
      expect(last[1], 0x22, reason: 'flags=0x2 表示末包');
    });

    test('结束帧 JSON 携带 event=2 与 reqid', () {
      final frame = buildVolcAsrFinishFrame('req-1');
      final json = jsonDecode(utf8.decode(frame.sublist(8)));
      expect(json, {'event': 2, 'reqid': 'req-1'});
    });

    test('JSON 结果帧（msgType=0x9）带 sequence，payload 可解', () {
      final resultPayload = utf8.encode(
          '{"code":0,"result":{"text":"你好","utterances":[]}}');
      final raw = _craftAsrServerFrame(
        msgType: volcMsgJsonServer,
        flags: 0x1,
        sequence: 5,
        payload: resultPayload,
      );
      final parsed = parseVolcAsrFrame(raw);
      expect(parsed.msgType, volcMsgJsonServer);
      expect(parsed.sequence, 5);
      expect(jsonDecode(utf8.decode(parsed.payload))['result']['text'], '你好');
    });

    test('gzip 压缩的 JSON 结果帧被自动解压', () {
      final json = utf8.encode('{"code":0,"result":{"text":"压缩内容"}}');
      final gzipped = Uint8List.fromList(GZipEncoder().encode(json));
      final raw = _craftAsrServerFrame(
        msgType: volcMsgJsonServer,
        flags: 0x3,
        compression: volcCompGzip,
        sequence: 7,
        payload: gzipped,
      );
      final parsed = parseVolcAsrFrame(raw);
      expect(parsed.compression, volcCompGzip);
      expect(jsonDecode(utf8.decode(parsed.payload))['result']['text'],
          '压缩内容');
    });

    test('错误帧（0xF）携带 errorCode 与文本', () {
      final raw = _craftAsrServerFrame(
        msgType: volcMsgError,
        serialization: volcSerJson,
        flags: 0x1,
        errorCode: 45000081,
        payload: utf8.encode('waiting data timeout'),
      );
      final parsed = parseVolcAsrFrame(raw);
      expect(parsed.msgType, volcMsgError);
      expect(parsed.errorCode, 45000081);
      expect(utf8.decode(parsed.payload), 'waiting data timeout');
    });
  });

  group('容错', () {
    test('头部不足 4 字节抛 VolcFrameException', () {
      expect(() => parseVolcTtsFrame(Uint8List.fromList([0x11])),
          throwsA(isA<VolcFrameException>()));
    });

    test('payload 长度超过剩余字节抛 VolcFrameException', () {
      final bad = Uint8List.fromList([
        0x11,
        0x10,
        0x10,
        0x00,
        0x00,
        0x00,
        0x00,
        0x64, // 声明 100 字节 payload，实际 0
      ]);
      expect(() => parseVolcAsrFrame(bad), throwsA(isA<VolcFrameException>()));
    });
  });
}

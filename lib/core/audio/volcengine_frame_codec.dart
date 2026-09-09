/// 火山引擎开放平台语音双向流式协议的二进制帧编解码。
///
/// 移植自参考工程 `virtual/src/backend/volcengine-frame.js`（大模型 TTS
/// `BidirectionalTTS` 事件帧）与 `volcengine-asr-frame.js`（SAUC 流式识别帧）。
/// 两者共用 4 字节帧头：`[0]=0x11(version/headerSize)`、`[1]=(msgType<<4)|flags`、
/// `[2]=(serialization<<4)|compression`、`[3]=保留`。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart' show GZipDecoder;

/// 帧消息类型：全客户端 JSON 请求（TTS 事件帧 / ASR 启动帧）。
const int volcMsgFullClient = 0x1;

/// 帧消息类型：ASR 裸 PCM 音频帧。
const int volcMsgAudioOnly = 0x2;

/// 帧消息类型：ASR 服务端 JSON 结果帧。
const int volcMsgJsonServer = 0x9;

/// 帧消息类型：TTS 音频数据帧（服务端→客户端）。
const int volcMsgAudioOnlyServer = 0xB;

/// 帧消息类型：错误帧。
const int volcMsgError = 0xF;

/// 帧 flags：TTS event 帧携带。
const int volcFlagEvent = 0x4;

/// 帧 flags：ASR 末包（无序列）。
const int volcFlagLast = 0x2;

/// 帧序列化：JSON。
const int volcSerJson = 0x1;

/// 帧序列化：裸字节。
const int volcSerRaw = 0x0;

/// 帧压缩：无。
const int volcCompNone = 0x0;

/// 帧压缩：gzip（SAUC 服务端 JSON 帧可能压缩）。
const int volcCompGzip = 0x1;

/// 火山 TTS 连接级事件号集合（帧内携带 connectId，不携带 sessionId）。
const Set<int> _ttsConnectionLevelEvents = {50, 51, 52};

/// 火山 TTS 既不携带 connectId 也不携带 sessionId 的事件号（1=连接开始, 2=连接结束）。
const Set<int> _ttsNoSessionEvents = {1, 2, 50, 51, 52};

/// 帧解析/构造异常。
class VolcFrameException implements Exception {
  VolcFrameException(this.message);
  final String message;
  @override
  String toString() => 'VolcFrameException: $message';
}

/// 解析后的服务端帧。TTS 帧与 ASR 帧共用一个结构，不存在的字段保持默认值。
class VolcFrame {
  VolcFrame({
    required this.msgType,
    required this.flags,
    required this.serialization,
    required this.compression,
    this.event,
    this.sequence,
    this.errorCode,
    this.sessionId = '',
    this.connectId = '',
    required this.payload,
  });

  final int msgType;
  final int flags;
  final int serialization;
  final int compression;

  /// TTS 事件号（连接/会话/音频/结果等），仅 TTS 帧有效。
  final int? event;

  /// ASR 服务端帧的序号（flags ∈ {1,2,3} 时存在），仅 ASR 帧有效。
  final int? sequence;

  /// 错误码（msgType=0xF 时存在）。
  final int? errorCode;

  /// 会话 id（TTS 会话级事件帧携带）。
  final String sessionId;

  /// 连接 id（TTS 连接级事件帧携带）。
  final String connectId;

  /// 帧体（若为 gzip 压缩则已解压）。
  final Uint8List payload;

  @override
  String toString() =>
      'VolcFrame(msgType=$msgType flags=$flags ser=$serialization '
      'comp=$compression event=$event seq=$sequence err=$errorCode '
      'payload=${payload.length}B)';
}

/// 校验 [data] 头部之后仍有 [count] 字节可读。
void _needBytes(Uint8List data, int offset, int count, String what) {
  if (data.length < offset + count) {
    throw VolcFrameException(
        '$what 不足：需 $count 字节，实际剩余 ${data.length - offset}');
  }
}

int _readI32(Uint8List data, int offset) =>
    ByteData.sublistView(data).getInt32(offset, Endian.big);

int _readU32(Uint8List data, int offset) =>
    ByteData.sublistView(data).getUint32(offset, Endian.big);

String _decodeText(Uint8List data, int start, int length) =>
    String.fromCharCodes(data.sublist(start, start + length));

Uint8List _header(int msgType, int flags, int ser, int comp) =>
    Uint8List.fromList([0x11, (msgType << 4) | flags, (ser << 4) | comp, 0x00]);

Uint8List _makeU32(int value) =>
    Uint8List.sublistView(ByteData(4)..setUint32(0, value, Endian.big));

Uint8List _makeI32(int value) =>
    Uint8List.sublistView(ByteData(4)..setInt32(0, value, Endian.big));

Uint8List _encodeJson(Map<String, Object?> payload) =>
    Uint8List.fromList(utf8.encode(jsonEncode(payload)));

/// 构造 TTS「连接级」事件帧（无会话 id），例如 `ConnectionStarted`（event=1）。
Uint8List buildVolcConnectionFrame({
  required int event,
  required Map<String, Object?> payload,
}) {
  final body = _encodeJson(payload);
  final out = BytesBuilder(copy: false)
    ..add(_header(volcMsgFullClient, volcFlagEvent, volcSerJson, volcCompNone))
    ..add(_makeI32(event))
    ..add(_makeU32(body.length))
    ..add(body);
  return out.toBytes();
}

/// 构造 TTS「会话级」事件帧，例如提交文本（event=200）、结束会话（event=102）。
Uint8List buildVolcSessionFrame({
  required int event,
  required String sessionId,
  required Map<String, Object?> payload,
}) {
  final sid = Uint8List.fromList(utf8.encode(sessionId));
  final body = _encodeJson(payload);
  final out = BytesBuilder(copy: false)
    ..add(_header(volcMsgFullClient, volcFlagEvent, volcSerJson, volcCompNone))
    ..add(_makeI32(event))
    ..add(_makeU32(sid.length))
    ..add(sid)
    ..add(_makeU32(body.length))
    ..add(body);
  return out.toBytes();
}

/// 解析 TTS（BidirectionalTTS）服务端帧。
VolcFrame parseVolcTtsFrame(Uint8List data) {
  if (data.length < 4) {
    throw VolcFrameException('TTS 帧截断：头部不足 4 字节，实际 ${data.length}');
  }
  final headerSize = (data[0] & 0x0F) * 4;
  _needBytes(data, 0, headerSize, 'TTS 帧头');
  final msgType = (data[1] >> 4) & 0x0F;
  final flags = data[1] & 0x0F;
  final serialization = (data[2] >> 4) & 0x0F;
  final compression = data[2] & 0x0F;
  var offset = headerSize;

  int? event;
  var sessionId = '';
  var connectId = '';
  if ((flags & volcFlagEvent) != 0) {
    _needBytes(data, offset, 4, 'TTS event 字段');
    event = _readI32(data, offset);
    offset += 4;
    if (!_ttsNoSessionEvents.contains(event)) {
      // 会话级事件（不带 sessionId 的事件号之外）：4 字节长度 + sessionId。
      _needBytes(data, offset, 4, 'sessionId 长度字段');
      final sidLen = _readU32(data, offset);
      offset += 4;
      _needBytes(data, offset, sidLen, 'sessionId 数据');
      sessionId = _decodeText(data, offset, sidLen);
      offset += sidLen;
    }
    if (_ttsConnectionLevelEvents.contains(event)) {
      // 连接级事件：4 字节长度 + connectId。
      _needBytes(data, offset, 4, 'connectId 长度字段');
      final cidLen = _readU32(data, offset);
      offset += 4;
      _needBytes(data, offset, cidLen, 'connectId 数据');
      connectId = _decodeText(data, offset, cidLen);
      offset += cidLen;
    }
  }

  return _finishParse(
    data,
    offset,
    msgType: msgType,
    flags: flags,
    serialization: serialization,
    compression: compression,
    event: event,
    sessionId: sessionId,
    connectId: connectId,
    what: 'TTS 帧',
  );
}

/// 构造 ASR（SAUC bigmodel）启动帧：JSON 配置。
Uint8List buildVolcAsrStartFrame(Map<String, Object?> payload) {
  final body = _encodeJson(payload);
  final out = BytesBuilder(copy: false)
    ..add(_header(volcMsgFullClient, 0x0, volcSerJson, volcCompNone))
    ..add(_makeU32(body.length))
    ..add(body);
  return out.toBytes();
}

/// 构造 ASR 音频帧：纯 PCM 字节（`isLast=true` 表示末包）。
Uint8List buildVolcAsrAudioFrame(List<int> pcm, {bool isLast = false}) {
  final flags = isLast ? volcFlagLast : 0x0;
  final out = BytesBuilder(copy: false)
    ..add(_header(volcMsgAudioOnly, flags, volcSerRaw, volcCompNone))
    ..add(_makeU32(pcm.length))
    ..add(pcm);
  return out.toBytes();
}

/// 构造 ASR 结束帧。
Uint8List buildVolcAsrFinishFrame(String reqid) =>
    buildVolcAsrStartFrame({'event': 2, 'reqid': reqid});

/// 解析 ASR（SAUC bigmodel）服务端帧。
VolcFrame parseVolcAsrFrame(Uint8List data) {
  if (data.length < 4) {
    throw VolcFrameException('ASR 帧截断：头部不足 4 字节，实际 ${data.length}');
  }
  final headerSize = (data[0] & 0x0F) * 4;
  _needBytes(data, 0, headerSize, 'ASR 帧头');
  final msgType = (data[1] >> 4) & 0x0F;
  final flags = data[1] & 0x0F;
  final serialization = (data[2] >> 4) & 0x0F;
  final compression = data[2] & 0x0F;
  var offset = headerSize;

  int? sequence;
  int? errorCode;
  // 服务端非音频帧 flags ∈ {1,2,3} 均带 int32 sequence。
  if (msgType != volcMsgAudioOnly &&
      (flags == 0x1 || flags == 0x2 || flags == 0x3)) {
    _needBytes(data, offset, 4, 'ASR sequence 字段');
    sequence = _readI32(data, offset);
    offset += 4;
  }
  if (msgType == volcMsgError) {
    _needBytes(data, offset, 4, 'ASR errorCode 字段');
    errorCode = _readU32(data, offset);
    offset += 4;
  }

  return _finishParse(
    data,
    offset,
    msgType: msgType,
    flags: flags,
    serialization: serialization,
    compression: compression,
    sequence: sequence,
    errorCode: errorCode,
    what: 'ASR 帧',
  );
}

/// 解析 payload 长度并取出 payload（必要时 gzip 解压）。
VolcFrame _finishParse(
  Uint8List data,
  int offset, {
  required int msgType,
  required int flags,
  required int serialization,
  required int compression,
  int? event,
  int? sequence,
  int? errorCode,
  String sessionId = '',
  String connectId = '',
  required String what,
}) {
  _needBytes(data, offset, 4, '$what payload 长度字段');
  final payloadSize = _readU32(data, offset);
  offset += 4;
  _needBytes(data, offset, payloadSize, '$what payload 数据');
  var payload = data.sublist(offset, offset + payloadSize);
  if (compression == volcCompGzip) {
    try {
      payload = Uint8List.fromList(const GZipDecoder().decodeBytes(payload));
    } catch (e) {
      throw VolcFrameException('$what gzip 解压失败: $e');
    }
  }
  return VolcFrame(
    msgType: msgType,
    flags: flags,
    serialization: serialization,
    compression: compression,
    event: event,
    sequence: sequence,
    errorCode: errorCode,
    sessionId: sessionId,
    connectId: connectId,
    payload: payload,
  );
}

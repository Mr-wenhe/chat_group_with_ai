import 'dart:typed_data';

import 'package:web_socket_channel/io.dart';

import 'volcengine_ws_types.dart';

/// 基于 `IOWebSocketChannel` 的二进制 socket 实现。
class VolcIoSocket implements VolcWsSocket {
  VolcIoSocket(this._channel);

  final IOWebSocketChannel _channel;

  @override
  Stream<Uint8List> get messages => _channel.stream.map((dynamic m) {
        if (m is String) {
          throw const FormatException('火山协议应为二进制帧，却收到文本帧');
        }
        return m is Uint8List ? m : Uint8List.fromList(m as List<int>);
      });

  @override
  void send(Uint8List bytes) => _channel.sink.add(bytes);

  @override
  Future<void> close() async {
    try {
      await _channel.sink.close();
    } catch (_) {
      // 连接已关闭时 sink.close 可能抛错，忽略即可。
    }
  }
}

/// 打开到火山开放平台的二进制 WebSocket（带认证头）。仅 I/O 平台可用。
Future<VolcWsSocket> openVolcWsImpl(
    String url, Map<String, String> headers) async {
  final channel = IOWebSocketChannel.connect(url, headers: headers);
  await channel.ready;
  return VolcIoSocket(channel);
}

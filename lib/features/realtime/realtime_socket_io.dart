import 'package:web_socket_channel/io.dart';

import 'realtime_socket_types.dart';

class _IoRealtimeSocket implements RealtimeSocket {
  _IoRealtimeSocket(this._channel);

  final IOWebSocketChannel _channel;

  @override
  Stream<String> get messages => _channel.stream.map((dynamic frame) {
        if (frame is String) return frame;
        // 服务端只发文本帧；收到二进制说明对面不是我们的协议。
        throw const FormatException('实时群聊协议应为文本帧，却收到二进制帧');
      });

  @override
  void send(String text) => _channel.sink.add(text);

  @override
  Future<void> close() async {
    try {
      await _channel.sink.close();
    } catch (_) {
      // 连接已经关闭时再关一次会抛错，忽略即可。
    }
  }
}

/// 打开到实时中继的文本 WebSocket。仅 I/O 平台可用。
///
/// 共享令牌走查询参数而不是请求头：Web 平台的 WebSocket 构造器不接受自定义
/// 请求头，用查询参数可以让同一份代码在两端都成立。代价是令牌会出现在
/// 服务端访问日志里——见 realtime/README.md 的「No TLS」说明。
Future<RealtimeSocket> openRealtimeSocketImpl(Uri uri) async {
  final channel = IOWebSocketChannel.connect(uri);
  await channel.ready;
  return _IoRealtimeSocket(channel);
}

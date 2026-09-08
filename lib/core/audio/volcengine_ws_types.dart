import 'dart:typed_data';

/// 火山语音协议所需的最小 WebSocket 传输抽象（仅收发二进制帧）。
///
/// 面向火山开放平台实现见 `volcengine_ws_io.dart`（I/O 平台），Web 平台为
/// `volcengine_ws_stub.dart`（抛 UnsupportedError）。核心客户端只依赖本接口，
/// 便于在测试里用内存假 socket 驱动状态机。
abstract class VolcWsSocket {
  /// 二进制下行帧流。实现方保证每个元素都是完整的二进制帧字节。
  Stream<Uint8List> get messages;

  /// 发送一个二进制帧。
  void send(Uint8List bytes);

  /// 关闭底层连接。
  Future<void> close();
}

/// 打开一个火山 WebSocket 连接的工厂：入参是端点 URL 与认证头。
typedef VolcSocketOpener = Future<VolcWsSocket> Function(
    String url, Map<String, String> headers);

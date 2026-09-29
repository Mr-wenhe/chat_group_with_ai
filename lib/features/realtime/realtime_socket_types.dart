/// 一条已建立的文本 WebSocket 连接的抽象。
///
/// 不直接用 `WebSocketChannel` 是为了让 `RealtimeClient` 的重连、去重、
/// 状态流转可以在没有任何真实网络的情况下单测——这些恰恰是最容易写错、
/// 又最难靠手工点击验证的部分。
abstract class RealtimeSocket {
  /// 收到的文本帧，按到达顺序。连接断开（正常或异常）时流结束。
  Stream<String> get messages;

  void send(String text);

  Future<void> close();
}

/// 打开一条连接。测试通过注入假实现来避免真实网络。
typedef RealtimeSocketOpener = Future<RealtimeSocket> Function(Uri uri);

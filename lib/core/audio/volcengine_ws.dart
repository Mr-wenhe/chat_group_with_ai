import 'volcengine_ws_io.dart'
    if (dart.library.html) 'volcengine_ws_stub.dart' as impl;
import 'volcengine_ws_types.dart';

export 'volcengine_ws_types.dart' show VolcWsSocket, VolcSocketOpener;

/// 打开到火山开放平台的二进制 WebSocket（带认证头）。
///
/// 非 Web 平台走 `IOWebSocketChannel`；Web 平台抛 [UnsupportedError]
/// （由上层 `kIsWeb` 守卫避免调用）。
Future<VolcWsSocket> openVolcWs(String url, Map<String, String> headers) =>
    impl.openVolcWsImpl(url, headers);

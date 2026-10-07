import 'realtime_socket_io.dart'
    if (dart.library.html) 'realtime_socket_stub.dart' as impl;
import 'realtime_socket_types.dart';

export 'realtime_socket_types.dart' show RealtimeSocket, RealtimeSocketOpener;

/// 打开到实时中继的文本 WebSocket。
///
/// 非 Web 平台走 `IOWebSocketChannel`；Web 平台抛 [UnsupportedError]
/// （由上层 `kIsWeb` 守卫避免调用）。
Future<RealtimeSocket> openRealtimeSocket(Uri uri) =>
    impl.openRealtimeSocketImpl(uri);

import 'realtime_socket_types.dart';

/// Web 平台桩：多人群聊的实时连接尚未在 Web 端验证过。
///
/// 功能入口一律用 `kIsWeb` 守卫，正常情况下不会走到这里。
Future<RealtimeSocket> openRealtimeSocketImpl(Uri uri) async {
  throw UnsupportedError('多人实时群聊暂不支持 Web 平台');
}

import 'volcengine_ws_types.dart';

/// Web 平台桩：火山语音（WebSocket 二进制）在 Web 端不支持。
///
/// 功能入口一律用 `kIsWeb` 守卫，正常情况下不会走到这里。
Future<VolcWsSocket> openVolcWsImpl(
    String url, Map<String, String> headers) async {
  throw UnsupportedError('火山引擎语音（WebSocket 二进制协议）不支持 Web 平台');
}

import 'package:dio/dio.dart';
import 'package:chat_group/core/storage/secure_storage_service.dart';

/// 企业微信出站推送结果。
class WeComPushResult {
  final bool ok;
  final int? errcode;
  final String? errmsg;
  final String detail;

  const WeComPushResult({
    required this.ok,
    this.errcode,
    this.errmsg,
    required this.detail,
  });
}

/// 企业微信出站推送服务（单向：App -> 企微）。
///
/// 两条通道：
/// - 推给同事(人)：自建应用 [message/send]，需 corpid/corpsecret/agentid 换 token。
/// - 推给群：群机器人 Webhook [webhook/send]，只需群机器人的 key。
///
/// 不接收企微消息（入站需公网中转，本次不做）。凭证从 [SecureStorageService] 读取，
/// 不落明文 Hive。
class WeComPushService {
  static const String _baseUrl = 'https://qyapi.weixin.qq.com';

  final Dio _dio;
  final SecureStorageService _secure;

  String? _cachedToken;
  DateTime? _tokenExpireAt;

  WeComPushService({Dio? dio, SecureStorageService? secure})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 15),
            )),
        _secure = secure ?? SecureStorageService();

  /// 构造「发给同事」请求体（纯函数，便于测试）。
  static Map<String, dynamic> buildUserBody(
    String userId,
    String content,
    int agentId,
  ) =>
      {
        'touser': userId,
        'msgtype': 'text',
        'agentid': agentId,
        'text': {'content': content},
      };

  /// 构造「发到群」请求体（纯函数，便于测试）。
  static Map<String, dynamic> buildGroupBody(String content) => {
        'msgtype': 'markdown',
        'markdown': {'content': content},
      };

  /// 解析企微 API 响应（纯函数，便于测试）。
  static WeComPushResult parseResult(dynamic data) {
    if (data is! Map) {
      return const WeComPushResult(ok: false, detail: '未知响应格式');
    }
    final errcode = data['errcode'];
    final errmsg = data['errmsg']?.toString();
    if (errcode == 0) {
      return const WeComPushResult(ok: true, detail: '已发送');
    }
    return WeComPushResult(
      ok: false,
      errcode: errcode is int ? errcode : null,
      errmsg: errmsg,
      detail: '企微返回错误：errcode=$errcode, errmsg=$errmsg',
    );
  }

  Future<Map<String, String>?> _loadConfig() => _secure.getWeComAppConfig();

  Future<String?> _getToken() async {
    if (_cachedToken != null &&
        _tokenExpireAt != null &&
        _tokenExpireAt!.isAfter(DateTime.now().add(const Duration(minutes: 5)))) {
      return _cachedToken;
    }
    final cfg = await _loadConfig();
    final corpid = cfg?['corpid'];
    final corpsecret = cfg?['corpsecret'];
    if (corpid == null || corpsecret == null) return null;

    try {
      final resp = await _dio.get(
        '$_baseUrl/cgi-bin/gettoken',
        queryParameters: {'corpid': corpid, 'corpsecret': corpsecret},
      );
      final data = resp.data;
      if (data is Map && data['errcode'] == 0 && data['access_token'] != null) {
        _cachedToken = data['access_token'] as String;
        final expires = (data['expires_in'] as int? ?? 7200);
        _tokenExpireAt = DateTime.now().add(Duration(seconds: expires));
        return _cachedToken;
      }
      return null;
    } on DioException {
      return null;
    }
  }

  /// 把文本推送给指定同事（UserID，可 `id1|id2` 多人）。
  Future<WeComPushResult> sendToUser(String userId, String content) async {
    final cfg = await _loadConfig();
    final agentId = int.tryParse(cfg?['agentid'] ?? '');
    if (agentId == null) {
      return const WeComPushResult(
        ok: false,
        detail: '未配置企业微信自建应用（缺少 agentid），请先在设置页填写',
      );
    }
    final token = await _getToken();
    if (token == null) {
      return const WeComPushResult(
        ok: false,
        detail: '获取 access_token 失败，请检查 corpid / corpsecret 是否正确',
      );
    }
    try {
      final resp = await _dio.post(
        '$_baseUrl/cgi-bin/message/send',
        queryParameters: {'access_token': token},
        data: buildUserBody(userId, content, agentId),
      );
      return parseResult(resp.data);
    } on DioException catch (e) {
      return WeComPushResult(ok: false, detail: '网络错误：${e.message}');
    }
  }

  /// 把文本推送到群（使用群机器人 Webhook 的 key）。
  Future<WeComPushResult> sendToGroup(String webhookKey, String content) async {
    try {
      final resp = await _dio.post(
        '$_baseUrl/cgi-bin/webhook/send',
        queryParameters: {'key': webhookKey},
        data: buildGroupBody(content),
      );
      return parseResult(resp.data);
    } on DioException catch (e) {
      return WeComPushResult(ok: false, detail: '网络错误：${e.message}');
    }
  }
}

import 'package:dio/dio.dart';

import 'realtime_protocol.dart';
import 'realtime_settings.dart';

/// 群注册 / 邀请码解析失败。
///
/// [message] 是已经翻译好的中文原因，可以直接展示给用户；调用方不需要
/// 再去辨认 HTTP 状态码。
class RealtimeGroupException implements Exception {
  const RealtimeGroupException(this.message, {this.isTransportFailure = false});

  final String message;

  /// 失败发生在网络层（连不上、超时），而不是服务端明确拒绝了这次请求。
  ///
  /// 调用方据此决定能否退回本地已有的数据：连不上服务端时继续显示手里那个
  /// 邀请码是合理的，令牌错误还这么干就是把主人蒙在鼓里。
  final bool isTransportFailure;

  @override
  String toString() => message;
}

/// 邀请码的人机边界：负责把人类输入规范成服务端认识的样子。
///
/// 邀请码口头转述时很容易被念成小写或带上空格，服务端虽然也做了大小写兼容，
/// 但在客户端先规范化一次能让「群不存在」这类报错只对应真正的输错。
String normalizeInviteCode(String raw) =>
    raw.replaceAll(RegExp(r'[\s-]'), '').toUpperCase();

/// 调用实时服务端的 HTTP 接口，只做两件事：注册群、按邀请码找群。
///
/// 与 [RealtimeClient] 分开是因为两者失败模式完全不同：这里是「一次性请求
/// 失败要立刻告诉用户」，那里是「长连接断了要自己重连」。
class RealtimeGroupService {
  RealtimeGroupService({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 10),
              // 状态码由我们自己翻译，交给 Dio 抛通用异常会丢掉服务端的错误码。
              validateStatus: (_) => true,
            ));

  final Dio _dio;

  /// 把本地群注册到服务端，拿到房间号与邀请码。主人点「邀请客人」时调用。
  ///
  /// 传了 [roomId] 就变成幂等的「保证这个房间已注册」：已经注册过的群拿回
  /// 原来的房间号和原来的邀请码，不会凭空多出一个房间。这条路径真正要解决的
  /// 是服务端重启——注册表在内存里，重启后旧邀请码一律解析不了，而客人手里的
  /// roomId 还是好的（重连时房间会被重新建出来）。此时用同一个 roomId 重新
  /// 注册会换发新码，客人不受影响，主人手上那个码则必须换掉。
  Future<RealtimeGroupRegistration> registerGroup({
    required RealtimeSettings settings,
    required String name,
    required String hostUserId,
    required String hostDisplayName,
    String? roomId,
  }) {
    return _request(
      settings: settings,
      send: () => _dio.postUri<Object?>(
        settings.groupsUri,
        data: <String, Object?>{
          'name': name,
          'hostUserId': hostUserId,
          'hostDisplayName': hostDisplayName,
          // 不带这个键才是「新建一个群」。服务端据此区分「没有房间号」和
          // 「房间号不合法」，所以未共享的群绝不能补一个空串占位。
          if (roomId != null && roomId.isNotEmpty) 'roomId': roomId,
        },
        options: _options(settings),
      ),
    );
  }

  /// 用邀请码换取房间信息。客人输码加入时调用。
  Future<RealtimeGroupRegistration> resolveInviteCode({
    required RealtimeSettings settings,
    required String inviteCode,
  }) {
    final normalized = normalizeInviteCode(inviteCode);
    return _request(
      settings: settings,
      send: () => _dio.getUri<Object?>(
        settings.groupByCodeUri(normalized),
        options: _options(settings),
      ),
      onNotFound: '邀请码 $normalized 不存在或已失效',
    );
  }

  /// 令牌为空就完全不带 Authorization 头。
  ///
  /// 发一个 `Bearer ` （空值）服务端虽然也认，但那是"带着一个空凭据"，
  /// 在抓包和日志里看着像配错了；不带才是"这台服务不需要凭据"。
  Options _options(RealtimeSettings settings) {
    final token = settings.token.trim();
    return Options(
      headers: token.isEmpty
          ? const <String, String>{}
          : <String, String>{'Authorization': 'Bearer $token'},
    );
  }

  Future<RealtimeGroupRegistration> _request({
    required RealtimeSettings settings,
    required Future<Response<Object?>> Function() send,
    String onNotFound = '群不存在或已失效',
  }) async {
    if (!settings.isConfigured) {
      throw const RealtimeGroupException('尚未配置多人联机服务，请先在设置里填写服务地址');
    }

    final Response<Object?> response;
    try {
      response = await send();
    } on DioException catch (error) {
      throw RealtimeGroupException(
        _describeTransportFailure(error),
        isTransportFailure: true,
      );
    }

    final status = response.statusCode ?? 0;
    if (status == 200 || status == 201) {
      final parsed = RealtimeGroupRegistration.fromJson(response.data);
      if (parsed == null) {
        throw const RealtimeGroupException('服务端返回了无法识别的数据');
      }
      return parsed;
    }
    throw RealtimeGroupException(_describeStatus(status, onNotFound));
  }

  String _describeStatus(int status, String onNotFound) {
    switch (status) {
      case 401:
        // 令牌是可选的，所以 401 只可能是这台服务器要求校验而我们没带对令牌，
        // 不可能是"漏填了必填项"。
        return '这台服务器要求共享令牌，当前令牌未填或不正确，请在设置里核对';
      case 404:
        return onNotFound;
      case 405:
        return '服务地址正确但接口不匹配，请确认填的是实时服务而不是别的服务';
      case 413:
        return '群名称过长';
      default:
        return status >= 500
            ? '实时服务暂时不可用（HTTP $status）'
            : '请求被拒绝（HTTP $status）';
    }
  }

  String _describeTransportFailure(DioException error) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return '连接实时服务超时，请检查网络与服务地址';
      case DioExceptionType.connectionError:
        return '无法连接实时服务，请检查服务地址与防火墙';
      default:
        return '请求实时服务失败：${error.message ?? '未知错误'}';
    }
  }
}

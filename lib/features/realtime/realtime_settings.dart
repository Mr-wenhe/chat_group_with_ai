import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import 'package:chat_group/core/storage/credential_repository.dart';

/// 编译期可覆盖的默认服务地址。
///
/// 地址本身不是机密，所以给一个开箱即用的默认值；换服务器用
/// `--dart-define=REALTIME_BASE_URL=...`。
const String realtimeDefaultBaseUrl = String.fromEnvironment(
  'REALTIME_BASE_URL',
  defaultValue: 'http://120.26.241.84:9210',
);

/// 编译期可覆盖的共享令牌。
///
/// 默认留空，而且**留空是正常工作状态**，不是"没配好"：服务端可以配置成不校验
/// 令牌，此时地址填对就能用，客户端一个凭据都不需要。需要校验的部署用
/// `--dart-define=REALTIME_TOKEN=...` 注入，或者让使用者在设置页手动填写。
///
/// 令牌仍然绝不写进代码：非空时会落到安全存储，不进入 Hive 明文或备份包。
const String realtimeDefaultToken = String.fromEnvironment('REALTIME_TOKEN');

/// 实时群聊服务的连接配置。
@immutable
class RealtimeSettings {
  const RealtimeSettings({required this.baseUrl, required this.token});

  /// 形如 `http://120.26.241.84:9210`，结尾不带斜杠。
  final String baseUrl;

  /// 与服务端 `REALTIME_SHARED_TOKEN` 一致的共享令牌。
  ///
  /// 空表示服务端不校验令牌，这是合法配置而不是缺配置。
  final String token;

  /// 只看地址：令牌是可选的，服务端不校验令牌时什么都不用填。
  bool get isConfigured => baseUrl.trim().isNotEmpty;

  /// WebSocket 地址。令牌非空时走查询参数，因为 Web 平台的 WebSocket
  /// 构造器不接受自定义请求头；为空就完全不带这个参数，省得服务端去解析
  /// 一个没有意义的空串。
  Uri get websocketUri {
    final base = Uri.parse(baseUrl.trim());
    final trimmedToken = token.trim();
    return base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: '/',
      queryParameters: trimmedToken.isEmpty
          ? null
          : <String, String>{'token': trimmedToken},
    );
  }

  Uri get groupsUri => Uri.parse('${baseUrl.trim()}/v1/groups');

  Uri groupByCodeUri(String inviteCode) =>
      Uri.parse('${baseUrl.trim()}/v1/groups/${Uri.encodeComponent(inviteCode.trim())}');

  /// 规范化用户输入：补协议、去结尾斜杠。
  static String normalizeBaseUrl(String raw) {
    var value = raw.trim();
    if (value.isEmpty) return '';
    if (!value.startsWith('http://') && !value.startsWith('https://')) {
      value = 'http://$value';
    }
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }

  @override
  bool operator ==(Object other) =>
      other is RealtimeSettings && other.baseUrl == baseUrl && other.token == token;

  @override
  int get hashCode => Object.hash(baseUrl, token);
}

/// 读写实时群聊配置。
///
/// 地址与令牌分开存：地址是普通配置放 `app_settings`，令牌是凭据走安全存储——
/// 与 `ApiConfig` 的密钥处理方式保持一致。Web 等没有 Keychain 的环境下
/// 安全存储不可用，此时保存会明确失败而不是退回 Hive 明文。
class RealtimeSettingsStore {
  RealtimeSettingsStore({
    required Box<dynamic> appSettingsBox,
    CredentialRepository? credentials,
  })  : _box = appSettingsBox,
        _credentials = credentials ?? CredentialRepository();

  static const String _baseUrlKey = 'realtime_base_url';
  /// 用户是否在设置页动过令牌。只影响"该不该退回编译期默认值"这一个判断，
  /// 令牌本身从不写进这个 box。
  static const String _tokenTouchedKey = 'realtime_token_touched';
  static const String _credentialId = 'realtime-relay';

  final Box<dynamic> _box;
  final CredentialRepository _credentials;

  bool get secureStorageAvailable => _credentials.secureStorageAvailable;

  Future<RealtimeSettings> load() async {
    final storedUrl = _box.get(_baseUrlKey);
    final baseUrl = storedUrl is String && storedUrl.trim().isNotEmpty
        ? storedUrl.trim()
        : realtimeDefaultBaseUrl;

    // 令牌的三种状态必须分开处理，混在一起就会出下面两行注释描述的两种故障：
    //   读到值        -> 用它
    //   读成功但为空  -> 用户手动清空过，就是"这台服务不需要令牌"
    //   读失败        -> 安全存储不可用，保留编译期默认值
    var token = realtimeDefaultToken;
    final read = await _credentials.read(_credentialId);
    if (read.isAvailable) {
      token = read.value!;
    } else if (read.isMissing && _box.get(_tokenTouchedKey) == true) {
      // 没有这个分支，"清空令牌"在带 --dart-define 的构建里看起来不生效——
      // 用户清掉之后应用会继续拿着编译期那个令牌去连。
      token = '';
    }
    // read 失败时保留编译期默认值而不是清空：后者会让整台机器在没有任何提示的
    // 情况下连不上需要令牌的服务。
    return RealtimeSettings(baseUrl: baseUrl, token: token);
  }

  /// 返回 null 表示成功，否则返回可直接展示给用户的原因。
  Future<String?> save(RealtimeSettings settings) async {
    final normalized = RealtimeSettings(
      baseUrl: RealtimeSettings.normalizeBaseUrl(settings.baseUrl),
      token: settings.token.trim(),
    );
    if (normalized.baseUrl.isEmpty) {
      return '服务地址不能为空';
    }

    if (normalized.token.isEmpty) {
      // 清空令牌同样是一条正常的保存：服务端可能压根不校验令牌。删除失败
      // 不当作错误——安全存储不可用时读也读不出来，残留的旧令牌不会被用到；
      // 为它挡住地址的保存只会让用户莫名其妙。
      await _credentials.delete(_credentialId);
    } else {
      final write = await _credentials.save(_credentialId, normalized.token);
      if (!write.isSuccess) {
        return '共享令牌无法写入安全存储，请检查系统钥匙串是否可用';
      }
    }

    // 两个分支都要记：清空和填写一样是"用户动过令牌"。[load] 靠这个标记
    // 决定要不要退回编译期默认值——不记的话，清空操作在带 --dart-define 的
    // 构建里会被默认值悄悄覆盖。
    await _box.put(_tokenTouchedKey, true);
    await _box.put(_baseUrlKey, normalized.baseUrl);
    return null;
  }
}

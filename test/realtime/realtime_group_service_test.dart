import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:chat_group/features/realtime/realtime_group_service.dart';
import 'package:chat_group/features/realtime/realtime_settings.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// 直接顶掉 Dio 的传输层，测试只关心"发了什么请求、拿到什么状态码之后怎么翻译"。
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.respond);

  final Future<ResponseBody> Function(RequestOptions options) respond;
  final List<RequestOptions> requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    requests.add(options);
    return respond(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object? body, int status) => ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );

({RealtimeGroupService service, _StubAdapter adapter}) _service(
  Future<ResponseBody> Function(RequestOptions options) respond,
) {
  final adapter = _StubAdapter(respond);
  final dio = Dio(BaseOptions(validateStatus: (_) => true))
    ..httpClientAdapter = adapter;
  return (service: RealtimeGroupService(dio: dio), adapter: adapter);
}

const _settings = RealtimeSettings(
  baseUrl: 'http://relay.invalid:9210',
  token: 'shared-token',
);

const _registration = <String, Object?>{
  'roomId': 'grp-1',
  'inviteCode': '7K2M9P',
  'name': '周末去哪儿',
  'hostUserId': 'host-1',
  'hostDisplayName': '小明',
};

void main() {
  group('normalizeInviteCode', () {
    test('去掉空格与连字符并转成大写', () {
      // 邀请码经常被口头转述或从聊天里复制，格式容错必须发生在客户端，
      // 否则用户看到的会是"邀请码不存在"而不是"你多打了个空格"。
      expect(normalizeInviteCode(' 7k2m9p '), '7K2M9P');
      expect(normalizeInviteCode('7k2-m9p'), '7K2M9P');
      expect(normalizeInviteCode('7K2M9P'), '7K2M9P');
    });
  });

  group('RealtimeSettings', () {
    test('baseUrl 补协议、去尾斜杠', () {
      expect(RealtimeSettings.normalizeBaseUrl('relay.invalid:9210'),
          'http://relay.invalid:9210');
      expect(RealtimeSettings.normalizeBaseUrl('https://relay.invalid/'),
          'https://relay.invalid');
      expect(RealtimeSettings.normalizeBaseUrl('   '), '');
    });

    test('WebSocket 地址带令牌且协议随 http/https 切换', () {
      expect(_settings.websocketUri.scheme, 'ws');
      expect(_settings.websocketUri.queryParameters['token'], 'shared-token');

      const secure =
          RealtimeSettings(baseUrl: 'https://relay.invalid', token: 't');
      expect(secure.websocketUri.scheme, 'wss');
    });

    test('邀请码进 URL 前会被转义', () {
      expect(
        _settings.groupByCodeUri('a/b').path,
        '/v1/groups/a%2Fb',
      );
    });
  });

  group('RealtimeGroupService', () {
    test('注册群：POST 到 /v1/groups，带 Bearer 令牌与主人信息', () async {
      final stub = _service((_) async => _json(_registration, 201));

      final result = await stub.service.registerGroup(
        settings: _settings,
        name: '周末去哪儿',
        hostUserId: 'host-1',
        hostDisplayName: '小明',
      );

      final request = stub.adapter.requests.single;
      expect(request.method, 'POST');
      expect(request.uri.toString(), 'http://relay.invalid:9210/v1/groups');
      expect(request.headers['Authorization'], 'Bearer shared-token');
      expect(request.data, <String, Object?>{
        'name': '周末去哪儿',
        'hostUserId': 'host-1',
        'hostDisplayName': '小明',
      });
      expect(result.inviteCode, '7K2M9P');
    });

    test('解析邀请码：GET /v1/groups/{code}，且先做大小写归一', () async {
      final stub = _service((_) async => _json(_registration, 200));

      final result =
          await stub.service.resolveInviteCode(settings: _settings, inviteCode: ' 7k2-m9p ');

      expect(stub.adapter.requests.single.method, 'GET');
      expect(stub.adapter.requests.single.uri.path, '/v1/groups/7K2M9P');
      expect(result.roomId, 'grp-1');
    });

    test('未配置时直接拒绝，不发任何请求', () async {
      final stub = _service((_) async => _json(_registration, 200));

      await expectLater(
        stub.service.registerGroup(
          settings: const RealtimeSettings(baseUrl: '', token: ''),
          name: '群',
          hostUserId: 'u1',
          hostDisplayName: '我',
        ),
        throwsA(isA<RealtimeGroupException>().having(
          (error) => error.message,
          'message',
          contains('尚未配置多人联机服务'),
        )),
      );
      expect(stub.adapter.requests, isEmpty);
    });

    test('状态码翻译成用户能直接看懂的中文原因', () async {
      Future<String> messageFor(int status) async {
        final stub = _service((_) async => _json(<String, Object?>{}, status));
        try {
          await stub.service.registerGroup(
            settings: _settings,
            name: '群',
            hostUserId: 'u1',
            hostDisplayName: '我',
          );
          fail('状态码 $status 应当抛出 RealtimeGroupException');
        } on RealtimeGroupException catch (error) {
          return error.message;
        }
      }

      // 令牌是可选的，所以 401 的措辞必须指向"这台服务器要求令牌"，
      // 而不是让用户以为有个必填项漏了。
      expect(await messageFor(401), contains('共享令牌'));
      expect(await messageFor(401), contains('设置'));
      expect(await messageFor(404), contains('群不存在或已失效'));
      expect(await messageFor(405), contains('接口不匹配'));
      expect(await messageFor(413), contains('群名称过长'));
      expect(await messageFor(503), contains('暂时不可用'));
    });

    test('邀请码不存在时给出带码的具体原因', () async {
      final stub = _service((_) async => _json(<String, Object?>{}, 404));

      await expectLater(
        stub.service
            .resolveInviteCode(settings: _settings, inviteCode: '7k2m9p'),
        throwsA(isA<RealtimeGroupException>().having(
          (error) => error.message,
          'message',
          contains('7K2M9P 不存在或已失效'),
        )),
      );
    });

    test('返回体缺字段时视为无法识别，不构造半个对象', () async {
      final stub = _service(
        (_) async => _json(<String, Object?>{'roomId': 'grp-1'}, 200),
      );

      await expectLater(
        stub.service
            .resolveInviteCode(settings: _settings, inviteCode: '7K2M9P'),
        throwsA(isA<RealtimeGroupException>().having(
          (error) => error.message,
          'message',
          contains('无法识别的数据'),
        )),
      );
    });

    test('连不上服务端时提示检查地址与防火墙', () async {
      final stub = _service((options) async {
        throw DioException.connectionError(
          requestOptions: options,
          reason: 'refused',
        );
      });

      await expectLater(
        stub.service.registerGroup(
          settings: _settings,
          name: '群',
          hostUserId: 'u1',
          hostDisplayName: '我',
        ),
        throwsA(isA<RealtimeGroupException>().having(
          (error) => error.message,
          'message',
          contains('无法连接实时服务'),
        )),
      );
    });
  });
}

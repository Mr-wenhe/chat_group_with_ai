import 'dart:convert';

import 'package:chat_group/core/images/image_generation_service.dart';
import 'package:chat_group/core/images/image_service_config.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

const _config = ImageServiceConfig(
  baseUrl: 'https://api.example.com',
  model: 'test-model',
  size: '1024x1024',
  apiKeyBound: true,
);

/// 按请求路径分发响应的测试桩。
///
/// [onRequest] 返回 null 表示由本桩按 [byPath] 给出响应；返回非 null 则用它
/// 覆盖（便于断言请求体形状）。计数器 [calls] / [getCalls] 用于断言「未发起 GET」。
class _FakeTransport {
  _FakeTransport({required this.byPath, this.onRequest});

  final Map<String, Object?> byPath;
  final Object? Function(RequestOptions options)? onRequest;
  final calls = <RequestOptions>[];
  final getCalls = <RequestOptions>[];

  Dio createDio() {
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        calls.add(options);
        if (options.method == 'GET') getCalls.add(options);
        final override = onRequest?.call(options);
        // Dio 把调用时传入的完整 URL 原样放进 `options.path`，相对路径 key
        // 必须再按 `options.uri.path` 查一次，否则 `/v1/...` 永远匹配不上。
        final payload = override ??
            byPath[options.path] ??
            byPath[options.uri.path];
        if (payload == null) {
          handler.reject(DioException(
            requestOptions: options,
            type: DioExceptionType.connectionError,
            message: 'no stub for ${options.path}',
          ));
          return;
        }
        if (payload is Response) {
          handler.resolve(payload);
          return;
        }
        handler.resolve(Response<Object?>(
          requestOptions: options,
          statusCode: 200,
          data: payload,
        ));
      },
    ));
    return dio;
  }
}

ImageGenerationService _service(
  _FakeTransport transport, {
  ImageServiceConfig config = _config,
  void Function(Duration)? onSleep,
}) {
  return ImageGenerationService(
    config: config,
    apiKey: 'sk-test',
    dio: transport.createDio(),
    retrySleep: (delay) async => onSleep?.call(delay),
  );
}

Response<Object?> _error(int status, Object? body) => Response<Object?>(
      requestOptions: RequestOptions(path: ''),
      statusCode: status,
      data: body,
    );

void main() {
  test('b64_json 成功路径返回解码后的图片字节', () async {
    final png = <int>[0x89, 0x50, 0x4E, 0x47];
    final transport = _FakeTransport(byPath: {
      '/v1/images/generations': {
        'data': [
          {'b64_json': base64Encode(png)}
        ]
      },
    });

    final bytes = await _service(transport).generate(prompt: 'p');

    expect(bytes, png);
    expect(transport.getCalls, isEmpty);
  });

  test('请求体形状：n=1、response_format=b64_json、空 quality 不发送', () async {
    late RequestOptions captured;
    final transport = _FakeTransport(
      byPath: {
        '/v1/images/generations': {
          'data': [
            {'b64_json': base64Encode([1, 2])}
          ]
        }
      },
      onRequest: (options) {
        // `options.path` 是完整 URL，只有 `uri.path` 才是 `/v1/images/generations`。
        if (options.uri.path == '/v1/images/generations') captured = options;
        return null;
      },
    );

    await _service(transport).generate(prompt: 'hello');

    final body = Map<String, dynamic>.from(captured.data as Map);
    expect(body['n'], 1);
    expect(body['response_format'], 'b64_json');
    expect(body['model'], 'test-model');
    expect(body['size'], '1024x1024');
    expect(body['prompt'], 'hello');
    expect(body.containsKey('quality'), isFalse);
    // 默认不发 watermark_enabled：OpenAI 等实现不认它，发了会 400。
    expect(body.containsKey('watermark_enabled'), isFalse);
    expect(captured.headers['Authorization'], 'Bearer sk-test');
  });

  test('quality 非空时才出现在请求体', () async {
    late RequestOptions captured;
    final transport = _FakeTransport(
      byPath: {
        '/v1/images/generations': {
          'data': [
            {'b64_json': base64Encode([1])}
          ]
        }
      },
      onRequest: (options) {
        captured = options;
        return null;
      },
    );

    await _service(transport, config: _config.copyWith(quality: 'hd'))
        .generate(prompt: 'p');

    expect((captured.data as Map)['quality'], 'hd');
  });

  test('去水印开启时才发 watermark_enabled: false', () async {
    late RequestOptions captured;
    final transport = _FakeTransport(
      byPath: {
        '/v1/images/generations': {
          'data': [
            {'b64_json': base64Encode([1])}
          ]
        }
      },
      onRequest: (options) {
        captured = options;
        return null;
      },
    );

    await _service(
      transport,
      config: _config.copyWith(disableWatermark: true),
    ).generate(prompt: 'p');

    final body = Map<String, dynamic>.from(captured.data as Map);
    // 必须是字面 false，不是字符串：智谱按 boolean 解析，字符串会被当非法值。
    expect(body['watermark_enabled'], isFalse);
  });

  test('只有可信 host 的 url 时才下载', () async {
    final png = <int>[9, 9, 9];
    final transport = _FakeTransport(byPath: {
      '/v1/images/generations': {
        'data': [
          {'url': 'https://cdn.aliyuncs.com/a.png'}
        ]
      },
      'https://cdn.aliyuncs.com/a.png': png,
    });

    final bytes = await _service(transport).generate(prompt: 'p');

    expect(bytes, png);
    expect(transport.getCalls, hasLength(1));
  });

  test('私网/本机 host 的 url 被拒绝且未发起 GET，报错带上 host', () async {
    final transport = _FakeTransport(byPath: {
      '/v1/images/generations': {
        'data': [
          {'url': 'https://127.0.0.1/a.png'}
        ]
      },
      'https://127.0.0.1/a.png': <int>[1],
    });

    await expectLater(
      _service(transport).generate(prompt: 'p'),
      throwsA(isA<ImageGenerationException>().having(
        (e) => e.message,
        'message',
        allOf(contains('不受信的图片地址'), contains('127.0.0.1')),
      )),
    );
    expect(transport.getCalls, isEmpty);
  });

  test('厂商对象存储等未知公网 host 允许下载（智谱落图即此形态）', () async {
    final png = <int>[7, 7, 7];
    final transport = _FakeTransport(byPath: {
      '/v1/images/generations': {
        'data': [
          {'url': 'https://maas-oss.example-vendor.com/a.png'}
        ]
      },
      'https://maas-oss.example-vendor.com/a.png': png,
    });

    final bytes = await _service(transport).generate(prompt: 'p');

    expect(bytes, png);
    expect(transport.getCalls, hasLength(1));
  });

  test('http 图片地址升级为 https 后再下载', () async {
    final png = <int>[8, 8];
    late RequestOptions download;
    final transport = _FakeTransport(
      byPath: {
        '/v1/images/generations': {
          'data': [
            {'url': 'http://img.example-vendor.com/a.png'}
          ]
        },
        'https://img.example-vendor.com/a.png': png,
      },
      onRequest: (options) {
        if (options.method == 'GET') download = options;
        return null;
      },
    );

    final bytes = await _service(transport).generate(prompt: 'p');

    expect(bytes, png);
    expect(download.uri.scheme, 'https');
  });

  test('isTrustedImageUrl 拒绝纯 IP、localhost 与非 https', () {
    expect(isTrustedImageUrl('https://127.0.0.1/a.png'), isFalse);
    expect(isTrustedImageUrl('https://localhost/a.png'), isFalse);
    expect(isTrustedImageUrl('https://metadata.google.internal/a.png'), isFalse);
    expect(isTrustedImageUrl('https://intranet.local/a.png'), isFalse);
    expect(isTrustedImageUrl('http://cdn.example.com/a.png'), isFalse);
    // 单标签主机名（无点）不是公网 DNS 名，拒绝。
    expect(isTrustedImageUrl('https://fileserver/a.png'), isFalse);
  });

  test('isTrustedImageUrl 放行任意公网 DNS 名', () {
    expect(isTrustedImageUrl('https://cdn.example.com/a.png'), isTrue);
    expect(isTrustedImageUrl('https://img.bigmodel.cn/a.png'), isTrue);
    expect(isTrustedImageUrl('https://open.bigmodel.cn/a.png'), isTrue);
    // 尾点 FQDN 归一化后同名。
    expect(isTrustedImageUrl('https://cdn.example.com./a.png'), isTrue);
  });

  test('空 data 报可解析错误', () async {
    final transport = _FakeTransport(byPath: {
      '/v1/images/generations': {'data': []},
    });

    await expectLater(
      _service(transport).generate(prompt: 'p'),
      throwsA(isA<ImageGenerationException>().having(
        (e) => e.message,
        'message',
        contains('无法解析'),
      )),
    );
  });

  test('坏 base64 报可解析错误', () async {
    final transport = _FakeTransport(byPath: {
      '/v1/images/generations': {
        'data': [
          {'b64_json': '!!!not-base64!!!'}
        ]
      },
    });

    await expectLater(
      _service(transport).generate(prompt: 'p'),
      throwsA(isA<ImageGenerationException>().having(
        (e) => e.message,
        'message',
        contains('无法解析'),
      )),
    );
  });

  test('超大 b64 报超限错误', () async {
    final huge = base64Encode(List<int>.filled(kImageMaxImageBytes + 1, 7));
    final transport = _FakeTransport(byPath: {
      '/v1/images/generations': {
        'data': [
          {'b64_json': huge}
        ]
      },
    });

    await expectLater(
      _service(transport).generate(prompt: 'p'),
      throwsA(isA<ImageGenerationException>()),
    );
  });

  test('401 / 403 映射为 Key 无效文案', () async {
    for (final status in [401, 403]) {
      final transport = _FakeTransport(byPath: {
        '/v1/images/generations':
            _error(status, {'error': {'message': 'bad key'}}),
      });
      await expectLater(
        _service(transport).generate(prompt: 'p'),
        throwsA(isA<ImageGenerationException>().having(
          (e) => e.message,
          'message',
          contains('API Key 无效'),
        )),
      );
    }
  });

  test('404 映射为地址或模型不正确', () async {
    final transport = _FakeTransport(byPath: {
      '/v1/images/generations': _error(404, {'error': {'message': 'nope'}}),
    });

    await expectLater(
      _service(transport).generate(prompt: 'p'),
      throwsA(isA<ImageGenerationException>().having(
        (e) => e.message,
        'message',
        contains('地址或模型名不正确'),
      )),
    );
  });

  test('429 映射为额度不足文案', () async {
    final transport = _FakeTransport(byPath: {
      '/v1/images/generations': _error(429, {'error': {'message': 'quota'}}),
    });

    await expectLater(
      _service(transport).generate(prompt: 'p'),
      throwsA(isA<ImageGenerationException>().having(
        (e) => e.message,
        'message',
        contains('额度不足'),
      )),
    );
  });

  test('5xx 重试一次后仍失败', () async {
    var calls = 0;
    final sleeps = <Duration>[];
    final transport = _FakeTransport(
      byPath: {},
      onRequest: (options) {
        calls++;
        return _error(503, {'error': {'message': 'busy'}});
      },
    );

    await expectLater(
      _service(transport, onSleep: sleeps.add).generate(prompt: 'p'),
      throwsA(isA<ImageGenerationException>().having(
        (e) => e.message,
        'message',
        contains('暂时不可用'),
      )),
    );
    expect(calls, 2); // 初始 1 次 + 重试 1 次
    expect(sleeps, hasLength(1));
  });

  test('5xx 重试后成功', () async {
    var calls = 0;
    final transport = _FakeTransport(
      byPath: {},
      onRequest: (options) {
        calls++;
        if (calls == 1) return _error(503, null);
        return {
          'data': [
            {'b64_json': base64Encode([4, 5])}
          ]
        };
      },
    );

    final bytes = await _service(transport).generate(prompt: 'p');

    expect(bytes, [4, 5]);
    expect(calls, 2);
  });

  test('4xx 不重试（避免重复计费）', () async {
    var calls = 0;
    final transport = _FakeTransport(
      byPath: {},
      onRequest: (options) {
        calls++;
        return _error(400, {'error': {'message': 'content filtered'}});
      },
    );

    await expectLater(
      _service(transport).generate(prompt: 'p'),
      throwsA(isA<ImageGenerationException>().having(
        (e) => e.message,
        'message',
        contains('图像服务拒绝了请求'),
      )),
    );
    expect(calls, 1);
  });

  test('未配置时直接报配置缺失，不发起请求', () async {
    final transport = _FakeTransport(byPath: {});

    await expectLater(
      _service(transport, config: ImageServiceConfig.empty)
          .generate(prompt: 'p'),
      throwsA(isA<ImageGenerationException>().having(
        (e) => e.message,
        'message',
        contains('尚未配置图像服务'),
      )),
    );
    expect(transport.calls, isEmpty);
  });

  test('服务端 error.message 被截断后带入文案', () async {
    final longDetail = 'E' * 300;
    final transport = _FakeTransport(byPath: {
      '/v1/images/generations':
          _error(400, {'error': {'message': longDetail}}),
    });

    await expectLater(
      _service(transport).generate(prompt: 'p'),
      throwsA(isA<ImageGenerationException>().having(
        (e) => e.message,
        'message',
        contains('${'E' * 120}…'),
      )),
    );
  });

  group('生图端点拼接 generationsEndpoint', () {
    // 端点形态是「配了却调不通」的头号来源：智谱 /api/paas/v4、火山 /api/v3
    // 都不带 /v1，硬编码版本段会让它们一律 404。这里把四家真实前缀钉死。
    String pathOf(String baseUrl) => generationsEndpoint(baseUrl).path;

    test('OpenAI 预设前缀（含 /v1）不重复插入版本段', () {
      expect(pathOf('https://api.openai.com/v1'), '/v1/images/generations');
    });

    test('智谱前缀 /api/paas/v4 直接拼尾段', () {
      expect(pathOf('https://open.bigmodel.cn/api/paas/v4'),
          '/api/paas/v4/images/generations');
    });

    test('火山方舟前缀 /api/v3 直接拼尾段', () {
      expect(pathOf('https://ark.cn-beijing.volces.com/api/v3'),
          '/api/v3/images/generations');
    });

    test('通义兼容模式前缀保留其 /v1 段', () {
      expect(pathOf('https://dashscope.aliyuncs.com/compatible-mode/v1'),
          '/compatible-mode/v1/images/generations');
    });

    test('只有域名时按 OpenAI 形态自动补 /v1', () {
      expect(pathOf('https://api.example.com'), '/v1/images/generations');
    });

    test('用户直接粘完整端点时原样使用', () {
      expect(pathOf('https://open.bigmodel.cn/api/paas/v4/images/generations'),
          '/api/paas/v4/images/generations');
    });

    test('尾斜杠被剥掉，不会拼出双斜杠', () {
      expect(pathOf('https://api.openai.com/v1/'), '/v1/images/generations');
    });

    test('空前缀直接报配置错误', () {
      expect(
        () => generationsEndpoint('  '),
        throwsA(isA<ImageGenerationException>()),
      );
    });
  });
}

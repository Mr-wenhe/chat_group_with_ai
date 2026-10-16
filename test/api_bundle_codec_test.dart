import 'dart:convert';

import 'package:chat_group/core/bundle/api_bundle_codec.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const secret = 'unit-test-secret';

  Map<String, dynamic> samplePayload() => <String, dynamic>{
        'v': 1,
        'label': '测试包',
        'chat': [
          {'provider': 'deepseek', 'apiKey': 'sk-abcdefghijklmnop'},
        ],
      };

  String encodeBody(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');

  List<int> decodeBody(String code) =>
      base64Url.decode(base64Url.normalize(code.split('.').last));

  group('ApiBundleCodec 往返', () {
    test('seal 后 open 得到等价载荷', () {
      final code = ApiBundleCodec.seal(samplePayload(), secret: secret);
      final opened = ApiBundleCodec.open(code, secret: secret);

      expect(opened['v'], 1);
      expect(opened['label'], '测试包');
      expect(opened['chat'], isA<List<Object?>>());
      expect((opened['chat'] as List<Object?>).length, 1);
    });

    test('线格式带前缀且不含 padding', () {
      final code = ApiBundleCodec.seal(samplePayload(), secret: secret);
      expect(code.startsWith('$apiBundlePrefix.'), isTrue);
      expect(code.contains('='), isFalse);
      expect(code.contains('+'), isFalse);
      expect(code.contains('/'), isFalse);
    });

    test('同一载荷两次 seal 产出不同密文（salt 与 nonce 每次重新生成）', () {
      final first = ApiBundleCodec.seal(samplePayload(), secret: secret);
      final second = ApiBundleCodec.seal(samplePayload(), secret: secret);
      expect(first, isNot(second));
      // 但两者都能解开成同一份载荷。
      expect(ApiBundleCodec.open(first, secret: secret),
          ApiBundleCodec.open(second, secret: secret));
    });

    test('空白与换行被容忍，因此可以折行分发', () {
      final code = ApiBundleCodec.seal(samplePayload(), secret: secret);
      final folded = '${code.substring(0, 20)}\n  ${code.substring(20)}\n';
      expect(ApiBundleCodec.open(folded, secret: secret)['v'], 1);
    });

    test('长载荷（超过单个密钥流块）往返一致', () {
      final payload = <String, dynamic>{
        'v': 1,
        'label': 'L' * 400,
        'blob': 'x' * 5000,
      };
      final code = ApiBundleCodec.seal(payload, secret: secret);
      final opened = ApiBundleCodec.open(code, secret: secret);
      expect(opened['blob'], 'x' * 5000);
      expect(opened['label'], 'L' * 400);
    });
  });

  group('ApiBundleCodec 认证', () {
    test('篡改密文任意一字节 → ApiBundleAuthError', () {
      final code = ApiBundleCodec.seal(samplePayload(), secret: secret);
      final bytes = decodeBody(code);
      // 取信封中部（salt 16 + nonce 16 之后的密文区）。
      bytes[40] = bytes[40] ^ 0x01;
      final tampered = '$apiBundlePrefix.${encodeBody(bytes)}';

      expect(
        () => ApiBundleCodec.open(tampered, secret: secret),
        throwsA(isA<ApiBundleAuthError>()),
      );
    });

    test('篡改 salt → ApiBundleAuthError', () {
      final code = ApiBundleCodec.seal(samplePayload(), secret: secret);
      final bytes = decodeBody(code);
      bytes[0] = bytes[0] ^ 0xff;
      expect(
        () => ApiBundleCodec.open('$apiBundlePrefix.${encodeBody(bytes)}',
            secret: secret),
        throwsA(isA<ApiBundleAuthError>()),
      );
    });

    test('篡改 nonce → ApiBundleAuthError', () {
      final code = ApiBundleCodec.seal(samplePayload(), secret: secret);
      final bytes = decodeBody(code);
      bytes[20] = bytes[20] ^ 0x80;
      expect(
        () => ApiBundleCodec.open('$apiBundlePrefix.${encodeBody(bytes)}',
            secret: secret),
        throwsA(isA<ApiBundleAuthError>()),
      );
    });

    test('篡改 MAC 尾部 → ApiBundleAuthError', () {
      final code = ApiBundleCodec.seal(samplePayload(), secret: secret);
      final bytes = decodeBody(code);
      bytes[bytes.length - 1] = bytes[bytes.length - 1] ^ 0x0f;
      expect(
        () => ApiBundleCodec.open('$apiBundlePrefix.${encodeBody(bytes)}',
            secret: secret),
        throwsA(isA<ApiBundleAuthError>()),
      );
    });

    test('口令不对 → ApiBundleAuthError，而不是解出乱码明文', () {
      final code = ApiBundleCodec.seal(samplePayload(), secret: secret);
      expect(
        () => ApiBundleCodec.open(code, secret: '别的口令'),
        throwsA(isA<ApiBundleAuthError>()),
      );
    });

    test('先验 MAC 再解密：认证失败时不会执行 XOR 解密', () {
      // 直接把密文区清零（等价于最坏情况的垃圾数据）。若实现先解密后校验，
      // jsonDecode 会先炸成 FormatException 而不是 ApiBundleAuthError。
      final code = ApiBundleCodec.seal(samplePayload(), secret: secret);
      final bytes = decodeBody(code);
      for (var i = 32; i < bytes.length - 16; i++) {
        bytes[i] = 0;
      }
      expect(
        () => ApiBundleCodec.open('$apiBundlePrefix.${encodeBody(bytes)}',
            secret: secret),
        throwsA(isA<ApiBundleAuthError>()),
      );
    });
  });

  group('ApiBundleCodec 格式错误', () {
    test('空串', () {
      expect(() => ApiBundleCodec.open('   \n ', secret: secret),
          throwsA(isA<ApiBundleFormatError>()));
    });

    test('前缀不认识', () {
      expect(() => ApiBundleCodec.open('XXXX.abcdef', secret: secret),
          throwsA(isA<ApiBundleFormatError>()));
    });

    test('没有分隔点', () {
      expect(() => ApiBundleCodec.open('BBK1abcdef', secret: secret),
          throwsA(isA<ApiBundleFormatError>()));
    });

    test('正文不是合法 base64', () {
      expect(() => ApiBundleCodec.open('$apiBundlePrefix.!!!not-base64!!!',
          secret: secret), throwsA(isA<ApiBundleFormatError>()));
    });

    test('长度不足（缺 salt/nonce/MAC）', () {
      final short = encodeBody(List<int>.filled(20, 0));
      expect(() => ApiBundleCodec.open('$apiBundlePrefix.$short', secret: secret),
          throwsA(isA<ApiBundleFormatError>()));
    });
  });

  group('ApiBundleCodec 不泄露输入', () {
    test('异常消息里不含授权码内容', () {
      final code = ApiBundleCodec.seal(samplePayload(), secret: secret);

      for (final attempt in <Object Function()>[
        () => ApiBundleCodec.open(code, secret: '错误口令'),
        () => ApiBundleCodec.open('$apiBundlePrefix.\$\$\$', secret: secret),
      ]) {
        try {
          attempt();
          fail('应当抛出异常');
        } on Object catch (error) {
          final text = error.toString();
          expect(text.contains(code), isFalse);
          expect(text.contains(code.substring(code.length - 24)), isFalse);
          expect(text.contains('sk-abcdefghijklmnop'), isFalse);
        }
      }
    });

    test('looksLikeBundle 只认前缀，不解读内容', () {
      expect(ApiBundleCodec.looksLikeBundle('BBK1.anything'), isTrue);
      expect(ApiBundleCodec.looksLikeBundle('  BBK1.x  '), isTrue);
      expect(ApiBundleCodec.looksLikeBundle('hello'), isFalse);
      expect(ApiBundleCodec.looksLikeBundle(''), isFalse);
    });
  });
}

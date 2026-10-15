/// 授权码（API 配置包）的加解密与线格式。
///
/// **本文件必须保持纯 Dart**：只允许 import `dart:*` 与 `package:crypto`，
/// 不得 import Flutter。生成工具 `scripts/generate_api_bundle.dart` 与 App
/// 共用这一份实现——两套实现必然漂移，而漂移的表现是「生成的码自己解不开」，
/// 只能靠人肉比对密钥串才能发现。
///
/// ## 威胁模型（务必如实告知使用者，不要让它看起来像端到端加密）
///
/// 解密口令是**编译进 App 的常量**（可用 `--dart-define=BUNDLE_KEY_SECRET=...`
/// 覆盖）。因此本方案防的是**明文裸奔与随手转发**，不是有动机的逆向：
/// 任何拿到 App 二进制的人都能解出里面的 API Key。这是刻意取舍——用一个内置
/// 口令换「用户只需粘贴一串、不需要额外记密码」的零摩擦分发。
///
/// ## 构造
///
/// HMAC-SHA256 作伪随机函数的 CTR 密钥流 + encrypt-then-MAC：
///
///     kEnc = HMAC(secret, "bbk/enc" || salt)          // 32B
///     kMac = HMAC(secret, "bbk/mac" || salt)          // 32B
///     keystream_i = HMAC(kEnc, nonce || be32(i))
///     ciphertext  = plaintext XOR keystream
///     mac = HMAC(kMac, version || salt || nonce || ciphertext)[0..16]
///
/// 只用了 `crypto` 已经提供的 `Hmac` / `sha256`，没有引入新的密码学依赖。
/// 选择这个而不是 AES-GCM 的原因是仓库对新增依赖极保守（见 `pubspec.yaml` 的
/// `dependency_overrides` 注释），而这里的保密目标用不着更强的原语。
///
/// **先验 MAC 再解密**：认证覆盖算法版本与整个头部，改版本号即失效；未经认证的
/// 密文一个字节都不会被解密，因此不存在填充预言一类的旁路。
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// 内置解密口令。用 `--dart-define=BUNDLE_KEY_SECRET=...` 可在构建时覆盖，
/// 生成工具必须用**同一个**口令（也读同一个 `--dart-define`）。
///
/// 改这个常量等于让所有已分发的授权码失效，除非同时重新生成。
const String _builtInBundleSecret =
    'bbk-v1-7f3a91c4e8b25d06a1f4c7e293b58d10';

/// 实际生效的解密口令。
const String defaultBundleSecret = String.fromEnvironment(
  'BUNDLE_KEY_SECRET',
  defaultValue: _builtInBundleSecret,
);

/// 线格式前缀。它管的是**信封**，与载荷里的 `"v"` 是两道独立闸门：前者管字节
/// 排布，后者管 JSON schema。任一不认识都直接拒绝，绝不做「尽力解析」。
const String apiBundlePrefix = 'BBK1';

/// 密钥指纹：`sha256(密钥)` 的前 8 位十六进制；空串返回空串。
///
/// 给用户一个能三方对照（生成端 ←→ 页面 ←→ 手上原值）又不泄露密钥的凭据。
/// **全仓库只此一份**：导入的预览、导出的清单、生成脚本都调它——各写一份的话，
/// 三处指纹对不上时用户会以为是密钥不同，而真正的原因是实现漂移。
String apiBundleKeyFingerprint(String secret) {
  if (secret.isEmpty) return '';
  return sha256.convert(utf8.encode(secret)).toString().substring(0, 8);
}

const int _saltLength = 16;
const int _nonceLength = 16;
const int _macLength = 16;
const int _headerLength = _saltLength + _nonceLength;
const int _minimumLength = _headerLength + _macLength;

/// 线格式不成立（空串、前缀不对、base64 损坏、长度不足）。
///
/// 消息**刻意不含输入内容**：授权码本身是凭据，绝不能顺着异常进日志或弹窗。
class ApiBundleFormatError implements Exception {
  const ApiBundleFormatError(this.message);

  final String message;

  @override
  String toString() => 'ApiBundleFormatError: $message';
}

/// 信封结构完整但认证失败：口令不对、被篡改、或不是本 App 生成的码。
///
/// 与 [ApiBundleFormatError] 分开是因为**给用户的处置完全不同**：格式错误是
/// 「你贴错了东西」，认证失败是「这串码不完整/不属于这个构建」。合成一个
/// 「解析失败」会让两种情况都没法排查。
class ApiBundleAuthError implements Exception {
  const ApiBundleAuthError([this.message = '授权码校验失败（内容不完整或不属于当前版本）']);

  final String message;

  @override
  String toString() => 'ApiBundleAuthError: $message';
}

/// 授权码编解码。
class ApiBundleCodec {
  const ApiBundleCodec._();

  /// 把配置包加密成授权码。同一份载荷每调用一次都会得到不同的字符串
  /// （salt 与 nonce 每次重新生成），因此相同配置在不同分发渠道里不会留下
  /// 一致的密文。
  ///
  /// [secret] 默认取 [defaultBundleSecret]。
  static String seal(
    Map<String, dynamic> payload, {
    String secret = defaultBundleSecret,
    Random? random,
  }) {
    final source = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
    final rng = random ?? Random.secure();
    final salt = _randomBytes(rng, _saltLength);
    final nonce = _randomBytes(rng, _nonceLength);

    final keyEnc = _deriveKey(secret, salt, 'bbk/enc');
    final keyMac = _deriveKey(secret, salt, 'bbk/mac');
    final ciphertext = _xorKeystream(source, keyEnc, nonce);
    final mac = _computeMac(keyMac, salt, nonce, ciphertext);

    final envelope = BytesBuilder(copy: false)
      ..add(salt)
      ..add(nonce)
      ..add(ciphertext)
      ..add(mac);
    final body = base64Url.encode(envelope.toBytes()).replaceAll('=', '');
    return '$apiBundlePrefix.$body';
  }

  /// 解出配置包。失败抛 [ApiBundleFormatError] 或 [ApiBundleAuthError]。
  ///
  /// 输入允许夹带任意空白与换行，因此授权码可以按 4/8 字符折行分发。
  static Map<String, dynamic> open(
    String code, {
    String secret = defaultBundleSecret,
  }) {
    final envelope = _decodeEnvelope(code);
    final salt = envelope.sublist(0, _saltLength);
    final nonce = envelope.sublist(_saltLength, _headerLength);
    final ciphertext = envelope.sublist(
      _headerLength,
      envelope.length - _macLength,
    );
    final mac = envelope.sublist(envelope.length - _macLength);

    final keyMac = _deriveKey(secret, salt, 'bbk/mac');
    final expected = _computeMac(keyMac, salt, nonce, ciphertext);
    if (!_constantTimeEquals(mac, expected)) {
      throw const ApiBundleAuthError();
    }

    final keyEnc = _deriveKey(secret, salt, 'bbk/enc');
    final plain = _xorKeystream(ciphertext, keyEnc, nonce);
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(plain));
    } on Object {
      // 认证已经过了，走到这里只可能是生成侧写坏了载荷；仍不把内容带进异常。
      throw const ApiBundleFormatError('授权码内容无法解析为配置包');
    }
    if (decoded is! Map) {
      throw const ApiBundleFormatError('授权码内容不是配置包对象');
    }
    return Map<String, dynamic>.from(decoded);
  }

  /// 判断一段文本看起来是不是授权码，用于区分「贴错了东西」和「格式对但解不开」。
  static bool looksLikeBundle(String code) =>
      code.replaceAll(_whitespace, '').startsWith('$apiBundlePrefix.');

  static Uint8List _decodeEnvelope(String code) {
    final compact = code.replaceAll(_whitespace, '');
    if (compact.isEmpty) {
      throw const ApiBundleFormatError('请先粘贴授权码');
    }
    final separator = compact.indexOf('.');
    if (separator < 0 || compact.substring(0, separator) != apiBundlePrefix) {
      throw const ApiBundleFormatError('无法识别的授权码格式');
    }
    final body = compact.substring(separator + 1);
    if (body.isEmpty) {
      throw const ApiBundleFormatError('授权码内容为空');
    }
    final Uint8List bytes;
    try {
      bytes = base64Url.decode(base64Url.normalize(body));
    } on Object {
      throw const ApiBundleFormatError('授权码内容已损坏，请重新复制完整的一串');
    }
    if (bytes.length < _minimumLength) {
      throw const ApiBundleFormatError('授权码不完整，请重新复制完整的一串');
    }
    return bytes;
  }

  static Uint8List _randomBytes(Random rng, int length) {
    final bytes = Uint8List(length);
    for (var i = 0; i < length; i++) {
      bytes[i] = rng.nextInt(256);
    }
    return bytes;
  }

  /// 单次 HMAC 派生。这里不需要迭代加盐（口令是内置的，抗暴力破解无从谈起），
  /// 但仍把 salt 与用途标签混进输入：既能区分加密钥与认证钥，又让格式在将来真要
  /// 改成用户口令时不必更换线格式。
  static List<int> _deriveKey(String secret, List<int> salt, String label) =>
      Hmac(sha256, utf8.encode(secret))
          .convert(<int>[...utf8.encode(label), ...salt])
          .bytes;

  static Uint8List _xorKeystream(
    List<int> data,
    List<int> keyEnc,
    List<int> nonce,
  ) {
    final out = Uint8List(data.length);
    final hmac = Hmac(sha256, keyEnc);
    final counterBlock = Uint8List(nonce.length + 4)..setRange(0, nonce.length, nonce);
    var offset = 0;
    var counter = 0;
    while (offset < data.length) {
      counterBlock[nonce.length] = (counter >> 24) & 0xff;
      counterBlock[nonce.length + 1] = (counter >> 16) & 0xff;
      counterBlock[nonce.length + 2] = (counter >> 8) & 0xff;
      counterBlock[nonce.length + 3] = counter & 0xff;
      final block = hmac.convert(counterBlock).bytes;
      final take = min(block.length, data.length - offset);
      for (var i = 0; i < take; i++) {
        out[offset + i] = data[offset + i] ^ block[i];
      }
      offset += take;
      counter++;
    }
    return out;
  }

  static List<int> _computeMac(
    List<int> keyMac,
    List<int> salt,
    List<int> nonce,
    List<int> ciphertext,
  ) {
    final builder = BytesBuilder(copy: false)
      ..add(utf8.encode(apiBundlePrefix))
      ..add(salt)
      ..add(nonce)
      ..add(ciphertext);
    return Hmac(sha256, keyMac).convert(builder.toBytes()).bytes.sublist(
          0,
          _macLength,
        );
  }

  /// 常量时间比较。用 `==` 会在第一个不同的字节处提前返回，把「差几个字节」
  /// 变成可测量的时间差。
  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}

final RegExp _whitespace = RegExp(r'\s');

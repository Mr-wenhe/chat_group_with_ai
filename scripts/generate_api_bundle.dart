// 把一份明文配置包加密成授权码。
//
//   dart run scripts/generate_api_bundle.dart --in payload.json
//   dart run scripts/generate_api_bundle.dart --in payload.json --out bundle.txt
//   dart run scripts/generate_api_bundle.dart --in payload.json --secret '自定义口令'
//   dart run scripts/generate_api_bundle.dart --decode bundle.txt
//
// 与 App 共用 `lib/core/bundle/` 下的同一份编解码实现——两套实现必然漂移，而漂移
// 的表现是「生成的码自己解不开」，只能靠人肉比对密钥串才能发现。
//
// **不打印明文密钥**：输出里只有服务清单、密钥指纹（sha256 前 8 位）和跳过原因。
// App 侧的预览显示同一套指纹，因此可以三方对照（生成端 ←→ 预览 ←→ 手上原值）。
//
// 口令来源，按优先级：
//   1. --secret
//   2. 环境变量 BUNDLE_KEY_SECRET
//   3. App 内置默认口令（见 `api_bundle_codec.dart` 的 defaultBundleSecret）
// 注意 App 侧用 `--dart-define=BUNDLE_KEY_SECRET=...` 覆盖，脚本侧用环境变量——
// 名字一样但机制不同，用自定义口令时两边都要设。
//
// 枚举值（provider / apiProtocol / 搜索 provider）由 App 侧校验；本脚本只做
// JSON 结构与必需字段的检查，把明显写错的包挡在分发之前。

import 'dart:convert';
import 'dart:io';

import 'package:chat_group/core/bundle/api_bundle.dart';
import 'package:chat_group/core/bundle/api_bundle_codec.dart';
import 'package:chat_group/core/models/api_provider.dart';

Future<void> main(List<String> args) async {
  final options = _parseArgs(args);
  if (options == null) exit(64);

  if (options.decode != null) {
    await _decode(options.decode!);
    return;
  }
  final input = options.input;
  if (input == null) {
    _usage('缺少 --in');
    exit(64);
  }
  await _seal(input, options);
}

Future<void> _seal(String inputPath, _Options options) async {
  final file = File(inputPath);
  if (!file.existsSync()) {
    stderr.writeln('找不到输入文件：$inputPath');
    exit(66);
  }

  final Map<String, dynamic> payload;
  try {
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) {
      stderr.writeln('输入必须是一个 JSON 对象');
      exit(65);
    }
    payload = Map<String, dynamic>.from(decoded);
  } on FormatException catch (error) {
    stderr.writeln('输入不是合法 JSON：${error.message}');
    exit(65);
  }

  final ApiBundle bundle;
  try {
    bundle = ApiBundle.parse(payload);
  } on ApiBundleFormatError catch (error) {
    stderr.writeln('配置包不被接受：${error.message}');
    exit(65);
  }

  final code = ApiBundleCodec.seal(payload, secret: options.secret);
  final output = options.output;
  if (output == null) {
    stdout.writeln(code);
  } else {
    await File(output).writeAsString('$code\n');
    stderr.writeln('已写入 $output');
    stderr.writeln('该文件等同于密钥，不要提交进 git、不要发到公开渠道。');
  }
  _printSummary(bundle);
}

Future<void> _decode(String path) async {
  final file = File(path);
  if (!file.existsSync()) {
    stderr.writeln('找不到授权码文件：$path');
    exit(66);
  }
  final Map<String, dynamic> payload;
  try {
    payload = ApiBundleCodec.open(
      await file.readAsString(),
      secret: _secretFromEnvironment(),
    );
  } on ApiBundleFormatError catch (error) {
    stderr.writeln('格式错误：${error.message}');
    exit(65);
  } on ApiBundleAuthError catch (error) {
    stderr.writeln('校验失败：${error.message}');
    exit(65);
  }
  final ApiBundle bundle;
  try {
    bundle = ApiBundle.parse(payload);
  } on ApiBundleFormatError catch (error) {
    stderr.writeln('配置包不被接受：${error.message}');
    exit(65);
  }
  stdout.writeln('解码成功，可供 App 解析。');
  _printSummary(bundle);
}

/// 只打印非机密摘要。
void _printSummary(ApiBundle bundle) {
  stderr.writeln('');
  stderr.writeln('配置包${bundle.label.isEmpty ? '' : '：${bundle.label}'}');

  for (final entry in bundle.chat) {
    final known = ApiProvider.values.any((p) => p.name == entry.provider);
    stderr.writeln(
      '  聊天  ${entry.name} · ${entry.provider}'
      '${known ? '' : '  ← 服务商名不在内置列表里，App 侧会跳过这条'}'
      '${entry.setDefault ? ' · 设为默认' : ''}'
      '  指纹 ${_fingerprint(entry.apiKey)}',
    );
  }
  if (bundle.voice != null) {
    stderr.writeln('  语音  火山引擎  指纹 ${_fingerprint(bundle.voice!.apiKey)}');
  }
  if (bundle.image != null) {
    stderr.writeln(
      '  图像  ${bundle.image!.model} · ${bundle.image!.baseUrl}'
      '  指纹 ${_fingerprint(bundle.image!.apiKey)}',
    );
  }
  for (final entry in bundle.search) {
    stderr.writeln(
      '  搜索  ${entry.name} · ${entry.provider}'
      '${entry.isDefault ? ' · 设为默认' : ''}'
      '${entry.apiKey.isEmpty ? '' : '  指纹 ${_fingerprint(entry.apiKey)}'}',
    );
  }

  for (final issue in bundle.issues) {
    stderr.writeln('  跳过  [${issue.section}] ${issue.title}：${issue.reason}');
  }

  if (bundle.hasNoEntries) {
    stderr.writeln('  （没有任何可导入的条目）');
  }
  stderr.writeln('');
  stderr.writeln('指纹为 sha256(密钥) 的前 8 位，App 预览页显示同一套值，可用于对照。');
  stderr.writeln('服务商 / 协议 / 搜索 provider 的取值由 App 侧校验，本脚本不做枚举检查。');
}

/// 指纹实现由 [apiBundleKeyFingerprint] 统一提供：App 的导入预览、导出清单与
/// 本脚本三处必须是同一套值，否则用户会把「实现漂移」误读成「密钥不同」。
String _fingerprint(String secret) =>
    secret.isEmpty ? '(无)' : apiBundleKeyFingerprint(secret);

String _secretFromEnvironment() =>
    Platform.environment['BUNDLE_KEY_SECRET']?.trim().isNotEmpty == true
        ? Platform.environment['BUNDLE_KEY_SECRET']!.trim()
        : defaultBundleSecret;

class _Options {
  const _Options({
    required this.input,
    required this.output,
    required this.secret,
    required this.decode,
  });

  final String? input;
  final String? output;
  final String secret;
  final String? decode;
}

_Options? _parseArgs(List<String> args) {
  String? input;
  String? output;
  String? secret;
  String? decode;

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    String? next() {
      if (i + 1 >= args.length) {
        stderr.writeln('$arg 后面缺少取值');
        return null;
      }
      return args[++i];
    }

    switch (arg) {
      case '--in':
        input = next();
        if (input == null) return null;
      case '--out':
        output = next();
        if (output == null) return null;
      case '--secret':
        secret = next();
        if (secret == null) return null;
      case '--decode':
        decode = next();
        if (decode == null) return null;
      case '--help':
      case '-h':
        _usage(null);
        return null;
      default:
        stderr.writeln('不认识的参数：$arg');
        _usage(null);
        return null;
    }
  }

  if (input == null && decode == null) {
    _usage('必须给出 --in 或 --decode');
    return null;
  }
  if (secret != null && decode != null) {
    stderr.writeln('--decode 使用环境变量 BUNDLE_KEY_SECRET，不接受 --secret');
    return null;
  }
  return _Options(
    input: input,
    output: output,
    secret: secret ?? _secretFromEnvironment(),
    decode: decode,
  );
}

void _usage(String? problem) {
  if (problem != null) stderr.writeln(problem);
  stderr.writeln('''
用法：
  dart run scripts/generate_api_bundle.dart --in <payload.json> [--out <bundle.txt>]
  dart run scripts/generate_api_bundle.dart --in <payload.json> --secret '<口令>'
  dart run scripts/generate_api_bundle.dart --decode <bundle.txt>

口令未指定时读环境变量 BUNDLE_KEY_SECRET，再缺省用 App 内置口令。
明文配置包格式见 docs/api_bundle_format.md。''');
}

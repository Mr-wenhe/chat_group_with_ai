import 'dart:convert';

import 'package:crypto/crypto.dart';

/// 被输出上限截断的响应里，可以救回来的那部分内容。
///
/// 截断发生在动作 JSON 中间：整条动作作废、一个字都没落盘，而模型已经烧掉
/// 整份输出预算。把这段前缀落盘成暂存分段、让模型只补写余下部分，是唯一能
/// 把那笔预算变成进度的做法。
class WorkTruncationSalvage {
  /// 模型本来要写的目标路径（原样保留，由调用方做路径解析与授权）。
  final String targetPath;

  /// 已成功解码出的内容前缀。
  final String content;

  const WorkTruncationSalvage({
    required this.targetPath,
    required this.content,
  });

  /// 从被截断的正文里取出「workspace.patch 动作的大字符串参数」。
  ///
  /// 只在能确定是这类前缀时返回结果：正文不是决策 JSON、动作不是
  /// `action=tool` 的 workspace.patch、或没有大字符串参数时一律返回 null，由调用方
  /// 退回话术路径。
  static WorkTruncationSalvage? extract(String body) {
    if (body.trim().isEmpty) return null;
    if (!body.contains('workspace.patch')) return null;
    final pathField = _firstStringField(body, 'path');
    if (pathField == null) return null;
    final (pathKeyAt, path) = pathField;
    if (path.trim().isEmpty) return null;
    // `action=tool` 必须**出现在 path 之前**（设计 §4.1）。这条判据不是形式主义：
    // 模型写文档时把工具调用当示例抄进正文是常见场景
    // （`{"name":"workspace.patch","arguments":{"path":"report.md","content":"…"}}`），
    // 这份文档一旦被截断，缺了它就等于把**文档片段**当成这次动作的内容落盘，
    // 再让模型把它合并进真实交付物——比不抢救更糟。
    if (!_declaresToolActionBefore(body, pathKeyAt)) return null;
    // 按列表优先级取第一个非空者：content（整文件写 / 追加的正文）优先于
    // replacement（精确补丁的正文）。这两者在解析器里是互斥形态，固定这个先后
    // 顺序即可与工具侧一致。
    for (final key in const ['content', 'replacement']) {
      final value = _readStringField(body, key);
      if (value != null && value.trim().isNotEmpty) {
        return WorkTruncationSalvage(targetPath: path, content: value);
      }
    }
    return null;
  }

  /// `action` 字段出现在 [before] 之前，且值为 `tool`。
  ///
  /// 超过 [before] 的 `action` 一律不看：动作自己的那个字段在 `path` 之前，再往后
  /// 出现的是正文里别的示例。
  static bool _declaresToolActionBefore(String body, int before) {
    for (final (keyAt, value) in _stringFields(body, 'action')) {
      if (keyAt > before) break;
      if (value.trim() == 'tool') return true;
    }
    return false;
  }

  /// 抢救内容的落盘路径。
  ///
  /// 内容哈希而不是序号：模型自己的分段文件也占用 `partN` 命名空间，撞名会把
  /// 两次尝试的内容拼进同一个文件；哈希后缀让同内容同名、不同内容不同名，
  /// 既不需要探测文件是否存在，任务恢复后也仍然幂等。
  static String rescuePath(String targetPath, String content) {
    final digest = sha256.convert(utf8.encode(content)).toString();
    final short = digest.substring(0, 8);
    final normalized = targetPath.replaceAll('\\', '/');
    final slash = normalized.lastIndexOf('/');
    final directory = slash < 0 ? '' : normalized.substring(0, slash + 1);
    final name = slash < 0 ? normalized : normalized.substring(slash + 1);
    final dot = name.lastIndexOf('.');
    if (dot <= 0) return '$directory$name.rescue-$short';
    return '$directory${name.substring(0, dot)}.rescue-$short'
        '${name.substring(dot)}';
  }

  /// 该路径是不是本模块产出的救援分段名（`<stem>.rescue-<8 位十六进制>[.ext]`）。
  ///
  /// 判据与 [rescuePath] 同源，所以留在这个模块里、而不是让调用点各写一份正则：
  /// 命名规则一变，识别规则必须跟着变。调用点用它把救援分段挡在**交付候选**之外
  /// ——它与目标同目录、同扩展名、内容非空，一旦登记，用户每次遭遇截断都会额外
  /// 收到一个残缺文件附件。
  ///
  /// 刻意只认**本模块自己的命名形状**（点名 `.rescue-`，哈希必须恰好 8 位十六进制，
  /// 之后要么是文件名结尾、要么是扩展名的点）。放宽（比如"名字里含 rescue"）会把
  /// 模型自己写的正常产物排除出交付候选——那比漏判更糟，所以宁可窄。
  static bool isRescuePath(String path) {
    final normalized = path.replaceAll('\\', '/');
    final slash = normalized.lastIndexOf('/');
    final name = slash < 0 ? normalized : normalized.substring(slash + 1);
    const marker = '.rescue-';
    var searchFrom = 0;
    while (true) {
      final markerAt = name.indexOf(marker, searchFrom);
      if (markerAt < 0) return false;
      searchFrom = markerAt + marker.length;
      if (searchFrom + 8 > name.length) continue;
      if (!_isHex8(name.substring(searchFrom, searchFrom + 8))) continue;
      final afterHash = searchFrom + 8;
      if (afterHash == name.length || name.codeUnitAt(afterHash) == 0x2E) {
        return true;
      }
    }
  }

  /// 严格匹配 8 位十六进制（救援命名里的内容哈希前缀）。
  ///
  /// 复用 [_isHex4]：与它一样"手写而非正则"，同样不抛异常。
  static bool _isHex8(String value) =>
      _isHex4(value.substring(0, 4)) && _isHex4(value.substring(4, 8));

  /// 从残缺 JSON 里读一个字符串字段：找到 `"key"` 后的冒号与开引号，按 JSON
  /// 字符串规则解码到闭合引号或正文结束。取**第一个**命中的字段。
  static String? _readStringField(String body, String key) {
    for (final field in _stringFields(body, key)) {
      return field.$2;
    }
    return null;
  }

  /// 同 [_readStringField]，但同时给出键标记（`"key"`）在正文里的起点，供调用方
  /// 判断字段之间的先后顺序。
  static (int, String)? _firstStringField(String body, String key) {
    for (final field in _stringFields(body, key)) {
      return field;
    }
    return null;
  }

  /// 按出现顺序枚举名为 [key] 的字符串字段：`(键标记起点, 解码后的值)`。
  ///
  /// 尾部的残缺转义（半个 `\`、半截 `\uXX`）一律丢弃——留下半个转义会让落盘
  /// 内容出现非法字符或反斜杠字面量。
  static Iterable<(int, String)> _stringFields(String body, String key) sync* {
    final marker = '"$key"';
    var searchFrom = 0;
    while (true) {
      final keyAt = body.indexOf(marker, searchFrom);
      if (keyAt < 0) return;
      searchFrom = keyAt + marker.length;
      var index = _skipWhitespace(body, searchFrom);
      if (index >= body.length || body[index] != ':') continue;
      index = _skipWhitespace(body, index + 1);
      if (index >= body.length || body[index] != '"') continue;
      yield (keyAt, _decodeJsonString(body, index + 1));
    }
  }

  static int _skipWhitespace(String body, int index) {
    var next = index;
    while (next < body.length && body[next].trim().isEmpty) {
      next++;
    }
    return next;
  }

  static String _decodeJsonString(String body, int start) {
    final buffer = StringBuffer();
    var index = start;
    while (index < body.length) {
      final char = body[index];
      if (char == '"') return buffer.toString();
      if (char != '\\') {
        buffer.write(char);
        index++;
        continue;
      }
      index++;
      if (index >= body.length) return buffer.toString();
      final escape = body[index];
      switch (escape) {
        case 'n':
          buffer.write('\n');
        case 't':
          buffer.write('\t');
        case 'r':
          buffer.write('\r');
        case 'b':
          buffer.write('\b');
        case 'f':
          buffer.write('\f');
        case '"':
          buffer.write('"');
        case '\\':
          buffer.write('\\');
        case '/':
          buffer.write('/');
        case 'u':
          final decoded = _decodeUnicodeEscape(body, index);
          // null 表示正文在半截 `\uXX` 处结束，到此为止。
          if (decoded == null) return buffer.toString();
          final (text, consumed) = decoded;
          if (text != null) buffer.write(text);
          index += consumed - 1; // 公共的 index++ 再补 1
        default:
          // 未知转义：抢救路径面对的本就是写坏的正文，忠实保留反斜杠 + 字符
          // 比丢掉反斜杠更接近模型的原文。
          buffer.write('\\');
          buffer.write(escape);
      }
      index++;
    }
    return buffer.toString();
  }

  /// 解码从 [uAt]（指向 `u`）开始的 `\uXXXX` 转义。
  ///
  /// 返回 `(text, consumed)`：`text` 是要写入的字符，null 表示这个转义被丢弃、
  /// 不写任何内容；`consumed` 是从 `uAt` 起消费的字符数。正文在半截转义处结束
  /// 时返回 null，由调用方结束解码。
  static (String?, int)? _decodeUnicodeEscape(String body, int uAt) {
    if (uAt + 4 >= body.length) return null; // 尾部半截 `\uXX`
    final hex = body.substring(uAt + 1, uAt + 5);
    // 必须是 4 位十六进制：`\u-123` 之类写坏的正文既不能静默解出错误码点，
    // 也不能抛异常——这条路径本就运行在截断失败路径上，抢救不能再变成新失败源。
    if (!_isHex4(hex)) return (null, 1); // 只丢弃 `\u` 这两个字符
    final unit = int.parse(hex, radix: 16);
    if (unit >= 0xD800 && unit <= 0xDFFF) {
      // 代理区码点必须成对出现。孤立的半个代理对会产出非法 UTF-16，下游
      // `utf8.encode` 不抛异常、静默写成 U+FFFD，等于凭空捏造一个字符。
      final low = unit <= 0xDBFF ? _lowSurrogateUnitAt(body, uAt + 5) : null;
      if (low == null) return (null, 5); // 孤立代理：整个转义丢弃
      final code = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00);
      return (String.fromCharCode(code), 11); // 高 + 低两个转义一起消费
    }
    return (String.fromCharCode(unit), 5);
  }

  /// `backslashAt` 指向一个候选转义的反斜杠：它是低代理 `\uDC00`–`\uDFFF`
  /// 时返回其码元，否则返回 null。
  static int? _lowSurrogateUnitAt(String body, int backslashAt) {
    if (backslashAt + 5 >= body.length) return null;
    if (body[backslashAt] != '\\' || body[backslashAt + 1] != 'u') return null;
    final hex = body.substring(backslashAt + 2, backslashAt + 6);
    if (!_isHex4(hex)) return null;
    final unit = int.parse(hex, radix: 16);
    if (unit < 0xDC00 || unit > 0xDFFF) return null;
    return unit;
  }

  /// 严格匹配 `^[0-9a-fA-F]{4}$`（手写而非正则：既要严格，也绝不抛异常）。
  static bool _isHex4(String value) {
    if (value.length != 4) return false;
    for (var i = 0; i < 4; i++) {
      final c = value.codeUnitAt(i);
      final isDigit = c >= 0x30 && c <= 0x39;
      final isLower = c >= 0x61 && c <= 0x66;
      final isUpper = c >= 0x41 && c <= 0x46;
      if (!isDigit && !isLower && !isUpper) return false;
    }
    return true;
  }
}

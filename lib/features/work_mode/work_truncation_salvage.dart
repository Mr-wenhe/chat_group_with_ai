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
  /// workspace.patch、或没有大字符串参数时一律返回 null，由调用方退回话术路径。
  static WorkTruncationSalvage? extract(String body) {
    if (body.trim().isEmpty) return null;
    if (!body.contains('workspace.patch')) return null;
    final path = _readStringField(body, 'path');
    if (path == null || path.trim().isEmpty) return null;
    // content 是整文件写/追加的正文，replacement 是精确补丁的正文；两者都可能
    // 长到撞上限，取先出现且非空的那个。
    for (final key in const ['content', 'replacement']) {
      final value = _readStringField(body, key);
      if (value != null && value.trim().isNotEmpty) {
        return WorkTruncationSalvage(targetPath: path, content: value);
      }
    }
    return null;
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

  /// 从残缺 JSON 里读一个字符串字段：找到 `"key"` 后的冒号与开引号，按 JSON
  /// 字符串规则解码到闭合引号或正文结束。
  ///
  /// 尾部的残缺转义（半个 `\`、半截 `\uXX`）一律丢弃——留下半个转义会让落盘
  /// 内容出现非法字符或反斜杠字面量。
  static String? _readStringField(String body, String key) {
    final marker = '"$key"';
    var searchFrom = 0;
    while (true) {
      final keyAt = body.indexOf(marker, searchFrom);
      if (keyAt < 0) return null;
      searchFrom = keyAt + marker.length;
      var index = searchFrom;
      while (index < body.length && body[index].trim().isEmpty) {
        index++;
      }
      if (index >= body.length || body[index] != ':') continue;
      index++;
      while (index < body.length && body[index].trim().isEmpty) {
        index++;
      }
      if (index >= body.length || body[index] != '"') continue;
      return _decodeJsonString(body, index + 1);
    }
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
          if (index + 4 >= body.length) return buffer.toString();
          final hex = body.substring(index + 1, index + 5);
          final code = int.tryParse(hex, radix: 16);
          if (code == null) return buffer.toString();
          buffer.writeCharCode(code);
          index += 4;
        default:
          // 未知转义：按字面量保留反斜杠后的字符，不猜测。
          buffer.write(escape);
      }
      index++;
    }
    return buffer.toString();
  }
}

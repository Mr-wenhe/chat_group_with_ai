/// 将不断到达的回复 token 切成“可朗读的句子”，用于流式逐句 TTS。
///
/// 切成句子的优先级：
/// 1. 遇到句末标点（。！？… 等）且长度 >= [minLen] 时立即成句（标点归属该句，
///    让 TTS 能在此处停顿）；
/// 2. 缓冲超过 [maxLen] 仍无标点时强行切分，避免一句话等太久；
/// 3. 其余保持在缓冲中，等 `finish()` 一次性输出。
library;

const String _terminalChars = '。！？!?…；;\n';

/// 追加式切句器。用法：
/// ```dart
/// final seg = SentenceSegmenter();
/// final a = seg.push('你');       // []
/// final b = seg.push('好。世界'); // ['你好。']
/// final tail = seg.finish();      // '世界'
/// ```
class SentenceSegmenter {
  SentenceSegmenter({this.maxLen = 50, this.minLen = 2})
      : assert(maxLen >= 1),
        assert(minLen >= 1);

  /// 无标点时强制切分的最大缓冲长度。
  final int maxLen;

  /// 遇到标点却短于该长度时暂不成句（避免把零碎语气词单独读出）。
  final int minLen;

  String _buf = '';

  int get pendingLength => _buf.length;

  /// 追加新到达的文本，返回本次新完成的句子（可能为 0..n 句）。
  List<String> push(String delta) {
    if (delta.isNotEmpty) _buf = _buf + delta;
    final flushed = <String>[];
    while (_buf.isNotEmpty) {
      final size = _buf.length;
      int? boundary; // 第一个句末标点之后的位置。
      for (var i = 0; i < size; i++) {
        if (_terminalChars.contains(_buf[i])) {
          boundary = i + 1;
          break;
        }
      }

      int end;
      if (boundary != null && boundary >= minLen) {
        end = boundary;
      } else if (size >= maxLen) {
        end = maxLen;
      } else {
        break;
      }
      // 避免在代理对（emoji）中间截断。
      if (end < _buf.length &&
          _buf.codeUnitAt(end - 1) >= 0xD800 &&
          _buf.codeUnitAt(end - 1) <= 0xDBFF) {
        end -= 1;
      }
      flushed.add(_buf.substring(0, end));
      _buf = _buf.substring(end);
    }
    return flushed;
  }

  /// 收尾：返回剩余缓冲（trim 后）；空/纯空白缓冲返回 null。
  String? finish() {
    final rest = _buf.trim();
    _buf = '';
    if (rest.isEmpty) return null;
    return rest;
  }
}

/// 轻量去掉常见 Markdown/装饰字符，避免朗读“**”“`#”等符号。
///
/// 只处理不会伤及中文正文的字符：代码围栏整行、行内反引号、成对的
/// 星号/下划线/波浪线/井号、行首标题符号与图片/链接语法。不做完整解析。
String stripMarkdownForSpeech(String text) {
  var out = text;
  // 去掉整行 ``` 围栏（连同行尾换行，避免留空行）。
  out = out.replaceAll(RegExp(r'^```.*\n?', multiLine: true), '');
  out = out.replaceAll('```', '');
  // 去掉行内代码反引号。
  out = out.replaceAll('`', '');
  // 图片 ![alt](url) 整体去掉；链接 [text](url) 保留文字。
  out = out.replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), '');
  out = out.replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]*\)'), (m) => m[1]!);
  // 行首标题 #。
  out = out.replaceAll(RegExp(r'^#+\s*', multiLine: true), '');
  // 成对的加粗/斜体/删除线标记。
  out = out.replaceAll('**', '').replaceAll('__', '').replaceAll('~~', '');
  // 剩余的孤立装饰符。
  out = out.replaceAll('*', '').replaceAll('_', '');
  out = out.replaceAll('#', '');
  out = out.replaceAll('~', '');
  return out.trim();
}

/// 从散文包裹的模型回复里取出**唯一**一个完整顶层 JSON object。
///
/// OpenAI 兼容网关（含各厂商的 flash/lite 档模型）常在协议正文前加一句口语
/// 解释，例如"先看看工作区现状，然后开始写材料。\n\n{...}"。协议本身要求裸
/// JSON，把整串直接交给 `jsonDecode` 会抛 `FormatException`，于是一次完全
/// 可用的决策被判成"响应不是单个合法 JSON object"。
///
/// 判据刻意收紧在"恰好一个"上：返回 null 表示没有 object、括号不闭合、或存
/// 在第二个顶层 object。第二条尤其重要——工具执行路径上，模型先吐草稿再吐修
/// 正版时，静默取第一个会照着草稿去执行。
///
/// 这是解析兜底，不是字段抽取器：取出的对象仍要过调用方全部字段与取值校验。
String? findSingleJsonObject(String source) {
  final first = _balancedObjectAt(source, source.indexOf('{'));
  if (first == null) return null;
  // 尾巴里再出现 `{` 就算不唯一，**不要求它是闭合的**：完整的第二个对象是
  // "先吐草稿再吐修正版"，而未闭合的第二个对象同样是"存在第二个顶层 object"
  // （括号不闭合）。两种情况下只取第一个都会照着草稿去执行。
  final tail = source.substring(first.end);
  if (tail.contains('{')) return null;
  return source.substring(first.start, first.end);
}

/// 从 [start] 处的 `{` 起找配对到深度 0 的 `}`。
///
/// 字符串与转义必须参与判定：`workspace.patch` 的 `content` 里大括号极常见
/// （CSS、模板、代码片段），不区分就会在第一个 `}` 处提前截断。
({int start, int end})? _balancedObjectAt(String source, int start) {
  if (start < 0) return null;
  var depth = 0;
  var quoted = false;
  var escaped = false;
  for (var index = start; index < source.length; index++) {
    final character = source[index];
    if (quoted) {
      if (escaped) {
        escaped = false;
      } else if (character == r'\') {
        escaped = true;
      } else if (character == '"') {
        quoted = false;
      }
      continue;
    }
    if (character == '"') {
      quoted = true;
    } else if (character == '{') {
      depth++;
    } else if (character == '}') {
      depth--;
      if (depth < 0) return null;
      if (depth == 0) return (start: start, end: index + 1);
    }
  }
  return null;
}

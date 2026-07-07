import 'dart:convert';

import 'package:chat_group/core/streaming/chat_stream_event.dart';

/// SSE（Server-Sent Events）行解析器：把 LLM 流式返回的字节流按行切分，
/// 提取 `data:` 行中的 `choices[0].delta.content` 增量 token，并累计完整内容。
///
/// 设计要点（与架构一致）：
/// 1. 纯函数式、无副作用、可单测，不依赖 Dio / Flutter。
/// 2. 处理跨 chunk 的不完整行：用 [_buffer] 暂存尚未遇到换行符的尾部，
///    因此即使 JSON 被网络分块切断也能正确拼接。
/// 3. 解析 / JSON 异常不抛出，统一产出 [ChatStreamEvent.error]，交由上层决定如何展示。
class SseParser {
  /// 暂存尚未凑齐整行（未遇到 `\n`）的尾部文本。
  String _buffer = '';

  /// 累计已成功解析的全部 token 内容，流结束时随 done 事件返回。
  String _fullContent = '';

  /// 处理一段（可能含多行、也可能只是半行）SSE 文本，返回本段产生的事件列表。
  ///
  /// [chunk] 可以是一整行、多行、或半行（跨网络分块边界）。
  /// 完整 `data:` 行才会尝试解析；`[DONE]` 行、注释行、空行及其它 SSE 字段行均被忽略。
  List<ChatStreamEvent> ingest(String chunk) {
    _buffer += chunk;
    final events = <ChatStreamEvent>[];

    // 按行切分，但保留最后一段不完整行在 _buffer 中等待后续 chunk。
    var searchFrom = 0;
    while (true) {
      final nl = _buffer.indexOf('\n', searchFrom);
      if (nl < 0) {
        // 没有更多完整行，剩余部分留待下次 ingest。
        _buffer = _buffer.substring(searchFrom);
        break;
      }
      final line = _buffer.substring(searchFrom, nl);
      final event = _parseLine(line);
      if (event != null) events.add(event);
      searchFrom = nl + 1;
    }
    return events;
  }

  /// 解析单行，返回对应事件；需要忽略的行返回 null。
  ChatStreamEvent? _parseLine(String rawLine) {
    var line = rawLine;
    // 去掉可能的回车符（HTTP 换行可能是 \r\n）。
    if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
    line = line.trim();

    // 空行：SSE 事件之间的分隔符，忽略。
    if (line.isEmpty) return null;

    // 以冒号开头的行是 SSE 注释（如心跳 keep-alive），忽略。
    if (line.startsWith(':')) return null;

    // 仅处理 data: 行（其它如 event:/id: 暂不需要）。
    if (!line.startsWith('data:')) return null;

    // 去掉 'data:' 前缀，允许 'data: ' 或 'data:' 两种写法。
    final payload =
        line.startsWith('data: ') ? line.substring(6) : line.substring(5);

    // 流结束标记，忽略。
    if (payload.trim() == '[DONE]') return null;

    // 尝试按 JSON 解析并提取增量内容。
    try {
      final json = jsonDecode(payload) as Map<String, dynamic>;
      final choices = json['choices'];
      if (choices is! List || choices.isEmpty) return null;
      final first = choices[0];
      if (first is! Map<String, dynamic>) return null;
      final delta = first['delta'];
      if (delta is! Map<String, dynamic>) return null;
      final content = delta['content'];
      // 增量内容为空（如仅携带 role 的行）忽略，不算错误。
      if (content == null || content is! String || content.isEmpty) return null;
      _fullContent += content;
      return ChatStreamEvent.token(content);
    } catch (e) {
      // JSON 解析失败的 data 行 → 产出 error 事件（不抛出，交由上层处理）。
      return ChatStreamEvent.error('SSE 数据解析失败: $e');
    }
  }

  /// 流结束时调用：返回携带累计完整内容的 done 事件。
  ChatStreamEvent doneEvent() => ChatStreamEvent.done(_fullContent);

  /// 重置内部状态，便于复用于下一次对话。
  void reset() {
    _buffer = '';
    _fullContent = '';
  }
}

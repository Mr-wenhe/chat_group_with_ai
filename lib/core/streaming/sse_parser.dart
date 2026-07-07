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
  String _buffer = '';
  String _fullContent = '';
  int _promptTokens = 0;
  int _completionTokens = 0;

  List<ChatStreamEvent> ingest(String chunk) {
    _buffer += chunk;
    final events = <ChatStreamEvent>[];

    var searchFrom = 0;
    while (true) {
      final nl = _buffer.indexOf('\n', searchFrom);
      if (nl < 0) {
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

  ChatStreamEvent? _parseLine(String rawLine) {
    var line = rawLine;
    if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
    line = line.trim();
    if (line.isEmpty) return null;
    if (line.startsWith(':')) return null;
    if (!line.startsWith('data:')) return null;

    final payload =
        line.startsWith('data: ') ? line.substring(6) : line.substring(5);
    if (payload.trim() == '[DONE]') return null;

    try {
      final json = jsonDecode(payload) as Map<String, dynamic>;
      // 提取 usage 字段（通常出现在最后一个 chunk）
      final usage = json['usage'];
      if (usage is Map<String, dynamic>) {
        _promptTokens += (usage['prompt_tokens'] as int? ?? 0);
        _completionTokens += (usage['completion_tokens'] as int? ?? 0);
      }
      // 有些 API 把 usage 放在 choices[0] 的 finish_reason 之后
      final choices = json['choices'];
      if (choices is List && choices.isNotEmpty) {
        final first = choices[0];
        if (first is Map<String, dynamic>) {
          final finishReason = first['finish_reason'];
          if (finishReason != null && finishReason is String && finishReason == 'stop') {
            // finish_reason 为 stop 时通常意味着生成了 completion_tokens
          }
        }
      }
      final firstChoice = choices is List && choices.isNotEmpty ? choices[0] : null;
      if (firstChoice is! Map<String, dynamic>) return null;
      final delta = firstChoice['delta'];
      if (delta is! Map<String, dynamic>) return null;
      final content = delta['content'];
      if (content == null || content is! String || content.isEmpty) return null;
      _fullContent += content;
      return ChatStreamEvent.token(content);
    } catch (e) {
      return ChatStreamEvent.error('SSE 数据解析失败: $e');
    }
  }

  ChatStreamEvent doneEvent() => ChatStreamEvent.done(
      _fullContent, null, _promptTokens, _completionTokens);

  int get promptTokens => _promptTokens;
  int get completionTokens => _completionTokens;

  /// 当前累计的完整内容长度（用于调试）。
  int get fullContentLength => _fullContent.length;

  void reset() {
    _buffer = '';
    _fullContent = '';
    _promptTokens = 0;
    _completionTokens = 0;
  }
}

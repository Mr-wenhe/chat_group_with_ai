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
  static const int _maxContentBytes = 2 * 1024 * 1024; // 2 MB
  String _buffer = '';
  String _fullContent = '';
  int _promptTokens = 0;
  int _completionTokens = 0;
  int _cachedTokens = 0;
  bool _terminated = false;
  int _fullContentBytes = 0;

  List<ChatStreamEvent> ingest(String chunk) {
    if (_terminated) return const [];
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

  ChatStreamEvent? ingestLine(String line) => _parseLine(line);

  ChatStreamEvent? _parseLine(String rawLine) {
    if (_terminated) return null;
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
      // Detect provider error responses that lack choices (e.g. {"error":{...}}).
      if (json['error'] != null && json['choices'] == null) {
        final errMsg = (json['error'] is Map)
            ? (json['error'] as Map)['message']?.toString() ?? 'API 错误'
            : json['error'].toString();
        _terminated = true;
        return ChatStreamEvent.error('API 返回错误: $errMsg');
      }
      // Extract usage fields (typically in the last chunk).
      final usage = json['usage'];
      if (usage is Map<String, dynamic>) {
        _promptTokens += (usage['prompt_tokens'] as int? ?? 0);
        _completionTokens += (usage['completion_tokens'] as int? ?? 0);
        _cachedTokens += _extractCachedTokens(usage);
      }
      final choices = json['choices'];
      if (choices is! List || choices.isEmpty) return null;
      final firstChoice = choices[0];
      if (firstChoice is! Map<String, dynamic>) return null;
      final delta = firstChoice['delta'];
      if (delta is! Map<String, dynamic>) return null;
      final content = delta['content'];
      if (content == null || content is! String || content.isEmpty) {
        if ((firstChoice['finish_reason'] ?? '').toString() == 'error') {
          final nestedErr = firstChoice['error'];
          final errMsg = (nestedErr is Map)
              ? (nestedErr['message']?.toString() ??
                  (json['error'] is Map
                      ? (json['error'] as Map)['message']?.toString()
                      : null))
              : null;
          _terminated = true;
          return ChatStreamEvent.error(errMsg ?? '模型生成失败');
        }
        return null;
      }
      final contentBytes = utf8.encode(content).length;
      _fullContentBytes += contentBytes;
      if (_fullContentBytes > _maxContentBytes) {
        _terminated = true;
        return ChatStreamEvent.error(
            '回复内容超过 ${_maxContentBytes ~/ 1024} KB 上限，已截断');
      }
      _fullContent += content;
      return ChatStreamEvent.token(content);
    } catch (_) {
      _terminated = true;
      // 解析失败不应中断流，也不应把模型正文或供应商错误原文写入日志。
      return ChatStreamEvent.error('SSE 数据解析失败');
    }
  }

  ChatStreamEvent doneEvent() => ChatStreamEvent.done(
      _fullContent, null, _promptTokens, _completionTokens, _cachedTokens);

  int get promptTokens => _promptTokens;
  int get completionTokens => _completionTokens;
  int get cachedTokens => _cachedTokens;

  /// 当前累计的完整内容长度（用于调试）。
  int get fullContentLength => _fullContent.length;

  /// 解析器是否已终止（遇到 [DONE]、错误或超限）。
  bool get terminated => _terminated;

  void reset() {
    _buffer = '';
    _fullContent = '';
    _fullContentBytes = 0;
    _promptTokens = 0;
    _completionTokens = 0;
    _cachedTokens = 0;
    _terminated = false;
  }

  int _extractCachedTokens(Map<String, dynamic> usage) {
    var total = 0;
    final promptDetails = usage['prompt_tokens_details'];
    if (promptDetails is Map) {
      total += (promptDetails['cached_tokens'] as int? ?? 0);
    }
    final inputDetails = usage['input_tokens_details'];
    if (inputDetails is Map) {
      total += (inputDetails['cached_tokens'] as int? ?? 0);
      total += (inputDetails['cache_read'] as int? ?? 0);
    }
    total += (usage['cached_tokens'] as int? ?? 0);
    total += (usage['prompt_cache_hit_tokens'] as int? ?? 0);
    total += (usage['cache_read_input_tokens'] as int? ?? 0);
    return total;
  }
}

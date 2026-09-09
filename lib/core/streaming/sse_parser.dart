import 'dart:async';
import 'dart:convert';

import 'package:chat_group/core/streaming/chat_stream_event.dart';

/// Raised when an SSE response exceeds a transport-level safety boundary.
class SseInputLimitException implements Exception {
  final String message;

  const SseInputLimitException(this.message);

  @override
  String toString() => message;
}

/// Splits an SSE byte stream into complete lines without retaining an
/// unbounded unterminated frame in memory.
///
/// The byte-level boundary is deliberately enforced before UTF-8 decoding and
/// JSON parsing. A remote endpoint can otherwise send an endless ASCII stream
/// without a newline and bypass a content-only limit.
class BoundedSseLineTransformer
    extends StreamTransformerBase<List<int>, List<int>> {
  final int maxLineBytes;
  final int maxWireBytes;

  const BoundedSseLineTransformer({
    required this.maxLineBytes,
    required this.maxWireBytes,
  })  : assert(maxLineBytes > 0),
        assert(maxWireBytes > 0);

  @override
  Stream<List<int>> bind(Stream<List<int>> stream) async* {
    final line = <int>[];
    var wireBytes = 0;
    var pendingCarriageReturn = false;
    await for (final chunk in stream) {
      if (chunk.length > maxWireBytes - wireBytes) {
        throw const SseInputLimitException('SSE 响应超过安全大小限制');
      }
      wireBytes += chunk.length;
      for (final byte in chunk) {
        if (pendingCarriageReturn) {
          // CRLF is one line ending; a lone CR is also a valid SSE delimiter.
          yield List<int>.from(line);
          line.clear();
          pendingCarriageReturn = false;
          if (byte == 0x0a) continue;
        }
        if (byte == 0x0d) {
          pendingCarriageReturn = true;
          continue;
        }
        if (byte == 0x0a) {
          yield List<int>.from(line);
          line.clear();
          continue;
        }
        if (line.length >= maxLineBytes) {
          throw const SseInputLimitException('SSE 数据帧超过安全大小限制');
        }
        line.add(byte);
      }
    }
    if (pendingCarriageReturn) {
      yield List<int>.from(line);
      line.clear();
    }
    if (line.isNotEmpty) yield List<int>.from(line);
  }
}

/// SSE（Server-Sent Events）行解析器：把 LLM 流式返回的字节流按行切分，
/// 提取 `data:` 行中的 `choices[0].delta.content` 增量 token，并累计完整内容。
/// 当标准 content 为空时，兼容使用 reasoning_content 作为完整响应回退。
///
/// 设计要点（与架构一致）：
/// 1. 纯函数式、无副作用、可单测，不依赖 Dio / Flutter。
/// 2. 处理跨 chunk 的不完整行：用 [_buffer] 暂存尚未遇到换行符的尾部，
///    因此即使 JSON 被网络分块切断也能正确拼接。
/// 3. 解析 / JSON 异常不抛出，统一产出 [ChatStreamEvent.error]，交由上层决定如何展示。
class SseParser {
  static const int _maxContentBytes = 2 * 1024 * 1024; // 2 MB
  static const int _maxLineBytes = 512 * 1024;
  static const int _maxWireBytes = 8 * 1024 * 1024;
  String _buffer = '';
  String _fullContent = '';
  String _fullReasoningContent = '';
  int _promptTokens = 0;
  int _completionTokens = 0;
  int _cachedTokens = 0;
  bool _terminated = false;
  int _fullContentBytes = 0;
  int _fullReasoningContentBytes = 0;
  int _bufferBytes = 0;
  int _wireBytes = 0;

  List<ChatStreamEvent> ingest(String chunk) {
    if (_terminated) return const [];
    final events = <ChatStreamEvent>[];
    var searchFrom = 0;
    while (searchFrom <= chunk.length) {
      final nl = chunk.indexOf('\n', searchFrom);
      final end = nl < 0 ? chunk.length : nl;
      final segment = chunk.substring(searchFrom, end);
      final segmentBytes = _utf8ByteLength(segment);
      final wireDelta = segmentBytes + (nl < 0 ? 0 : 1);
      if (!_acceptWireBytes(wireDelta) ||
          _bufferBytes + segmentBytes > _maxLineBytes) {
        return [_limitError()];
      }
      _buffer += segment;
      _bufferBytes += segmentBytes;
      if (nl < 0) break;
      final event = _parseLine(_buffer);
      if (event != null) events.add(event);
      _buffer = '';
      _bufferBytes = 0;
      if (_terminated) return events;
      searchFrom = nl + 1;
    }
    return events;
  }

  ChatStreamEvent? ingestLine(String line) {
    final lineBytes = _utf8ByteLength(line);
    if (!_acceptWireBytes(lineBytes) || lineBytes > _maxLineBytes) {
      return _limitError();
    }
    return _parseLine(line);
  }

  bool _acceptWireBytes(int additionalBytes) {
    if (additionalBytes < 0 || _wireBytes > _maxWireBytes - additionalBytes) {
      return false;
    }
    _wireBytes += additionalBytes;
    return true;
  }

  ChatStreamEvent _limitError() {
    _terminated = true;
    return ChatStreamEvent.error('SSE 数据超过安全大小限制');
  }

  int _utf8ByteLength(String value) {
    var bytes = 0;
    for (final rune in value.runes) {
      if (rune <= 0x7f) {
        bytes++;
      } else if (rune <= 0x7ff) {
        bytes += 2;
      } else if (rune <= 0xffff) {
        bytes += 3;
      } else {
        bytes += 4;
      }
    }
    return bytes;
  }

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
      if (content is String && content.isNotEmpty) {
        final contentBytes = utf8.encode(content).length;
        _fullContentBytes += contentBytes;
        if (_fullContentBytes > _maxContentBytes) {
          _terminated = true;
          return ChatStreamEvent.error(
              '回复内容超过 ${_maxContentBytes ~/ 1024} KB 上限，已截断');
        }
        _fullContent += content;
        return ChatStreamEvent.token(content);
      }
      final reasoningContent = delta['reasoning_content'];
      if (reasoningContent is String && reasoningContent.isNotEmpty) {
        final reasoningBytes = utf8.encode(reasoningContent).length;
        _fullReasoningContentBytes += reasoningBytes;
        if (_fullReasoningContentBytes > _maxContentBytes) {
          _terminated = true;
          return ChatStreamEvent.error(
              '回复内容超过 ${_maxContentBytes ~/ 1024} KB 上限，已截断');
        }
        _fullReasoningContent += reasoningContent;
      }
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
    } catch (_) {
      _terminated = true;
      // 解析失败不应中断流，也不应把模型正文或供应商错误原文写入日志。
      return ChatStreamEvent.error('SSE 数据解析失败');
    }
  }

  ChatStreamEvent doneEvent() => ChatStreamEvent.done(
      _fullContent.trim().isNotEmpty ? _fullContent : _fullReasoningContent,
      null,
      _promptTokens,
      _completionTokens,
      _cachedTokens);

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
    _fullReasoningContent = '';
    _fullContentBytes = 0;
    _fullReasoningContentBytes = 0;
    _bufferBytes = 0;
    _wireBytes = 0;
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

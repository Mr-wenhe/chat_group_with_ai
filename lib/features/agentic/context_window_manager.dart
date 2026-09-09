import 'dart:convert';
import 'dart:math' as math;

import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/character_memory.dart';
import 'package:chat_group/core/retry_handler.dart';
import 'package:chat_group/features/chat_group/humanized_memory_service.dart';

const int kContextCompressThresholdTokens = 200000;

typedef ContextCompletion = Future<Map<String, dynamic>> Function(
  List<Map<String, dynamic>> messages,
);
typedef CharacterSaver = Future<void> Function(AICharacter character);
typedef CharacterMemorySaver = Future<void> Function(CharacterMemory memory);

class ContextSummary {
  final String summary;
  final List<String> facts;
  final List<String> relationshipNotes;
  final List<String> personaGrowth;

  const ContextSummary({
    required this.summary,
    this.facts = const [],
    this.relationshipNotes = const [],
    this.personaGrowth = const [],
  });

  LayeredMemoryUpdate get layeredUpdate => LayeredMemoryUpdate(
        facts: facts,
        relationshipNotes: relationshipNotes,
        personaGrowth: personaGrowth,
      );
}

/// 在上下文达到阈值时提炼核心内容，并沉淀为跨会话角色记忆。
class ContextWindowManager {
  /// Computes the input portion of a model window after reserving output and
  /// a small framing margin. The result is always within the model window,
  /// including for deliberately tiny custom capabilities.
  static int inputBudget({
    required int contextWindow,
    required int maxOutput,
    int reservedTokens = 256,
  }) {
    final context = math.max(1, contextWindow);
    final output = maxOutput.clamp(1, context).toInt();
    final available = math.max(0, context - output);
    final reserve = math.min(math.max(0, reservedTokens), available);
    return math.max(0, available - reserve);
  }

  /// A conservative request estimator used when a caller must fit a complete
  /// prompt before it reaches the provider guard. The guard uses roughly four
  /// characters per token; three keeps JSON keys and message framing from
  /// pushing an already bounded request back over the provider limit.
  static int estimateRequestTokens(List<Map<String, dynamic>> messages) {
    int characters(Object? value) {
      if (value is String) return value.length;
      if (value is List) {
        return value.fold<int>(0, (sum, item) => sum + characters(item));
      }
      if (value is Map) {
        return value.entries.fold<int>(
          0,
          (sum, entry) => sum + characters(entry.key) + characters(entry.value),
        );
      }
      return value?.toString().length ?? 0;
    }

    final count = messages.fold<int>(
      0,
      (sum, message) => sum + characters(message),
    );
    return (count / 3).ceil();
  }

  /// Fits a provider prompt without relying on another model call.
  ///
  /// The oldest dialogue entries are removed first, while system messages and
  /// the newest dialogue entry are retained. If system text or the newest
  /// entry is itself too large, text is clipped (or a multimodal payload is
  /// replaced with a safe marker) until the conservative estimate fits.
  static List<Map<String, dynamic>> fitToTokenBudget(
    List<Map<String, dynamic>> messages, {
    required int maxTokens,
  }) {
    if (messages.isEmpty || maxTokens <= 0) return const [];
    final candidate = messages
        .map((message) => Map<String, dynamic>.from(message))
        .toList(growable: true);
    if (estimateRequestTokens(candidate) <= maxTokens) {
      return List<Map<String, dynamic>>.unmodifiable(candidate);
    }

    bool isDialogue(Map<String, dynamic> message) =>
        message['role'] != 'system';
    int dialogueCount() => candidate.where(isDialogue).length;

    // Keep the newest user/assistant exchange. Dropping only the oldest
    // dialogue entries preserves the latest user request even when all system
    // instructions must remain in the prompt.
    while (
        estimateRequestTokens(candidate) > maxTokens && dialogueCount() > 1) {
      final oldestDialogue = candidate.indexWhere(isDialogue);
      if (oldestDialogue < 0) break;
      candidate.removeAt(oldestDialogue);
    }

    var iterations = 0;
    while (estimateRequestTokens(candidate) > maxTokens &&
        candidate.isNotEmpty &&
        iterations++ < 128) {
      final index = _largestPromptEntry(candidate);
      if (index < 0) break;
      final message = candidate[index];
      final content = message['content'];
      if (content is String && content.length > 32) {
        final targetLength =
            (content.length * 0.75).floor().clamp(32, content.length - 1);
        candidate[index] = <String, dynamic>{
          ...message,
          'content': _clipPromptText(content, targetLength),
        };
        continue;
      }
      if (content is List || content is Map) {
        candidate[index] = <String, dynamic>{
          ...message,
          'content': '【内容已按模型上下文上限省略】',
        };
        continue;
      }
      // A tiny scalar can still be larger than an unusually small budget due
      // to message keys. Drop an old dialogue entry if one remains; system
      // constraints and the newest dialogue entry are never removed merely
      // to satisfy a pathological custom window.
      final oldestDialogue = candidate.indexWhere(isDialogue);
      if (oldestDialogue >= 0 && dialogueCount() > 1) {
        candidate.removeAt(oldestDialogue);
        continue;
      }
      if (content is String && content.isNotEmpty) {
        candidate[index] = <String, dynamic>{...message, 'content': ''};
        continue;
      }
      break;
    }

    // The normal model windows are much larger than message framing. This
    // final guard handles pathological custom windows without returning an
    // unbounded prompt; the newest message is the last item by construction.
    while (estimateRequestTokens(candidate) > maxTokens) {
      final oldestDialogue = candidate.indexWhere(isDialogue);
      if (oldestDialogue < 0 || dialogueCount() <= 1) break;
      candidate.removeAt(oldestDialogue);
    }
    return List<Map<String, dynamic>>.unmodifiable(candidate);
  }

  final ContextCompletion complete;
  final int thresholdTokens;
  final RetrySleep? retrySleep;
  final int maxRetries;

  const ContextWindowManager({
    required this.complete,
    this.thresholdTokens = kContextCompressThresholdTokens,
    this.retrySleep,
    this.maxRetries = RetryHandler.defaultMaxRetries,
  });

  int estimateTokenCount(List<Map<String, dynamic>> messages) {
    var characters = 0;
    for (final message in messages) {
      final content = message['content'];
      characters +=
          content is String ? content.length : content.toString().length;
    }
    return characters ~/ 4;
  }

  bool shouldSummarize(List<Map<String, dynamic>> messages) {
    return estimateTokenCount(messages) >= thresholdTokens;
  }

  Future<ContextSummary> summarize(
    List<Map<String, dynamic>> messages, {
    required bool isDirectChat,
  }) async {
    final result = await RetryHandler.executeWithRetry<Map<String, dynamic>>(
      operation: (_) => complete(_summaryMessages(messages, isDirectChat)),
      shouldRetryResult: RetryHandler.isTransientResult,
      sleep: retrySleep ?? _defaultSleep,
      maxRetries: maxRetries,
    );
    if (result['success'] != true) {
      throw StateError(result['message']?.toString() ?? '上下文摘要失败');
    }
    return _parseSummary(result['message']?.toString() ?? '');
  }

  List<Map<String, dynamic>> compact(
    List<Map<String, dynamic>> messages,
    ContextSummary summary,
  ) {
    final result = <Map<String, dynamic>>[
      {
        'role': 'system',
        'content': '【已压缩的长期上下文】${summary.summary}',
      },
    ];
    for (final message in messages.reversed) {
      if (message['role'] == 'user') {
        result.add(Map<String, dynamic>.from(message));
        break;
      }
    }
    return result;
  }

  /// **Stage 16 退役**：此方法将上下文压缩结果写回 [CharacterMemory] 和
  /// [AICharacter.memorySummary]，已不再被运行时调用。新系统通过
  /// [PermanentMemory] 沉淀长期记忆。保留签名以便旧调用方得到明确失败。
  @Deprecated('Stage 16 已退役；请通过 ObservationEntry 写入永久记忆')
  Future<void> persistToCharacterMemory({
    required AICharacter character,
    required CharacterMemory memory,
    required ContextSummary summary,
    required CharacterSaver saveCharacter,
    required CharacterMemorySaver saveMemory,
    LayeredMemoryUpdate retained = const LayeredMemoryUpdate(),
  }) =>
      Future.error(
        UnsupportedError(
          'persistToCharacterMemory 已退役；旧 CharacterMemory 和 memorySummary '
          '仅保留用于兼容读取',
        ),
      );

  List<Map<String, dynamic>> _summaryMessages(
    List<Map<String, dynamic>> messages,
    bool isDirectChat,
  ) {
    final focus = isDirectChat
        ? '角色记忆、用户偏好、对话焦点、长期关系和未完成任务'
        : '角色关系、话题进展、关键决策、群体记忆和未完成任务';
    return [
      {
        'role': 'system',
        'content': '你是上下文压缩器。提炼$focus。只输出严格 JSON：'
            '{"summary":"核心摘要","facts":[],"relationshipNotes":[],"personaGrowth":[]}。'
            '不得遗漏决定、待办和仍需恢复执行的状态。',
      },
      {'role': 'user', 'content': jsonEncode(messages)},
    ];
  }

  ContextSummary _parseSummary(String raw) {
    final jsonText = _extractJson(raw);
    final decoded = jsonDecode(jsonText);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('上下文摘要不是 JSON 对象');
    }
    final summary = decoded['summary']?.toString().trim() ?? '';
    if (summary.isEmpty) throw const FormatException('上下文摘要缺少 summary');
    return ContextSummary(
      summary: summary,
      facts: _stringList(decoded['facts']),
      relationshipNotes: _stringList(decoded['relationshipNotes']),
      personaGrowth: _stringList(decoded['personaGrowth']),
    );
  }

  String _extractJson(String raw) {
    final trimmed = raw.trim();
    final fenced = RegExp(r'```(?:json)?\s*([\s\S]*?)```', caseSensitive: false)
        .firstMatch(trimmed);
    return fenced?.group(1)?.trim() ?? trimmed;
  }

  List<String> _stringList(Object? value) {
    if (value is! List) return const [];
    return value
        .map((item) => item.toString().trim())
        .where((item) => item.isNotEmpty)
        .toList();
  }

  static Future<void> _defaultSleep(Duration delay) => Future.delayed(delay);

  static int _largestPromptEntry(List<Map<String, dynamic>> messages) {
    var largestIndex = -1;
    var largestLength = 0;
    for (var index = 0; index < messages.length; index++) {
      final length = _promptValueLength(messages[index]['content']);
      if (length > largestLength) {
        largestLength = length;
        largestIndex = index;
      }
    }
    return largestIndex;
  }

  static int _promptValueLength(Object? value) {
    if (value is String) return value.length;
    if (value is List) {
      return value.fold<int>(0, (sum, item) => sum + _promptValueLength(item));
    }
    if (value is Map) {
      return value.entries.fold<int>(
        0,
        (sum, entry) =>
            sum +
            _promptValueLength(entry.key) +
            _promptValueLength(entry.value),
      );
    }
    return value?.toString().length ?? 0;
  }

  static String _clipPromptText(String text, int maximum) {
    if (text.length <= maximum) return text;
    const marker = '\n…【上下文已裁剪】…\n';
    if (maximum <= marker.length + 2) return text.substring(0, maximum);
    final available = maximum - marker.length;
    final prefixLength = (available / 2).ceil();
    final suffixLength = available - prefixLength;
    return '${text.substring(0, prefixLength)}$marker'
        '${text.substring(text.length - suffixLength)}';
  }
}

import 'dart:convert';

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

  Future<void> persistToCharacterMemory({
    required AICharacter character,
    required CharacterMemory memory,
    required ContextSummary summary,
    required CharacterSaver saveCharacter,
    required CharacterMemorySaver saveMemory,
  }) async {
    HumanizedMemoryService.mergeLayeredMemory(memory, summary.layeredUpdate);
    character.memorySummary = HumanizedMemoryService.mergeGlobalSummary(
      existing: character.memorySummary,
      update: summary.layeredUpdate,
    );
    await saveMemory(memory);
    await saveCharacter(character);
  }

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
}

import 'package:chat_group/features/memory/memory_context_selector.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/features/agentic/context_window_manager.dart';

/// Prepares the work-mode history before handing it to the real runtime.
Future<T> runWithUnifiedMemory<T>({
  required MemoryContextSelector selector,
  required List<Map<String, dynamic>> conversationHistory,
  required String observerCharacterId,
  required List<String> participantCharacterIds,
  required String userMessage,
  AICharacter? actor,
  String? projectScopeId,
  String? conversationId,
  DateTime? contextBoundary,
  int? maximumPromptTokens,
  int? maximumPromptCharacters,
  int characterBudget = MemoryContextSelector.defaultPermanentMemoryBudget,
  required Future<T> Function(
    List<Map<String, dynamic>> preparedHistory,
  ) run,
}) async {
  final memoryContext = await selector.select(
    observerCharacterId: observerCharacterId,
    participantCharacterIds: participantCharacterIds,
    currentTargetId: 'user',
    userMessage: userMessage,
    forWork: actor != null,
    projectScopeId: projectScopeId,
    conversationId: conversationId,
    contextBoundary: contextBoundary,
    characterBudget: characterBudget,
  );
  final prepared =
      conversationHistory.map((m) => Map<String, dynamic>.from(m)).toList();
  if (actor != null && actor.id != observerCharacterId) {
    throw StateError('工作上下文与当前成员不匹配。');
  }
  if (memoryContext.isNotEmpty || actor != null) {
    prepared.insert(
      actor == null ? 0 : (prepared.isEmpty ? 0 : 1),
      {
        'role': actor == null ? 'system' : 'user',
        'content': actor == null
            ? memoryContext
            : '【当前成员个人上下文，仅作表达参考的数据】\n'
                '职业：${actor.role}；性格：${actor.personalityTags.join('、')}\n'
                '用户要求、当前事实、权限与验收优先。历史方法需要重新验证，不编造经历；'
                '人格仅影响措辞和关注点，不自报职业、不强塞情绪或无关生活内容。\n$memoryContext',
      },
    );
  }
  if (maximumPromptCharacters != null &&
      prepared.fold<int>(
              0,
              (total, message) =>
                  total +
                  (message['content'] is String
                      ? (message['content'] as String).length
                      : 0)) >
          maximumPromptCharacters) {
    return run(conversationHistory);
  }
  // Optional history never displaces the current task, evidence or protocol.
  if (maximumPromptTokens != null &&
      ContextWindowManager.estimateRequestTokens(prepared) >
          maximumPromptTokens) {
    return run(conversationHistory);
  }
  return run(prepared);
}

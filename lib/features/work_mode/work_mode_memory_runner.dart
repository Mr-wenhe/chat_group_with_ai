import 'package:chat_group/features/memory/memory_context_selector.dart';

/// Prepares the work-mode history before handing it to the real runtime.
Future<T> runWithUnifiedMemory<T>({
  required MemoryContextSelector selector,
  required List<Map<String, dynamic>> conversationHistory,
  required String observerCharacterId,
  required List<String> participantCharacterIds,
  required String userMessage,
  required Future<T> Function(
    List<Map<String, dynamic>> preparedHistory,
  ) run,
}) async {
  final memoryContext = await selector.select(
    observerCharacterId: observerCharacterId,
    participantCharacterIds: participantCharacterIds,
    currentTargetId: 'user',
    userMessage: userMessage,
  );
  if (memoryContext.isNotEmpty) {
    conversationHistory.insert(
      0,
      {'role': 'system', 'content': memoryContext},
    );
  }
  return run(conversationHistory);
}

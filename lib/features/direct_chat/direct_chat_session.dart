import 'package:chat_group/core/models/ai_character.dart';

class DirectChatSession {
  static const String prefix = 'dm:';

  static String conversationIdFor(String characterId) => '$prefix$characterId';

  static bool isDirectConversationId(String conversationId) {
    return conversationId.startsWith(prefix) &&
        conversationId.length > prefix.length;
  }

  static String? characterIdFrom(String conversationId) {
    if (!isDirectConversationId(conversationId)) return null;
    return conversationId.substring(prefix.length);
  }

  static List<AICharacter> selectReplyCharacters({
    required List<AICharacter> characters,
    required String directCharacterId,
    required bool Function(AICharacter character) isEligible,
  }) {
    final target =
        characters.where((c) => c.id == directCharacterId).firstOrNull;
    if (target == null || !isEligible(target)) return const [];
    return [target];
  }

  static String buildPromptContext({
    required String ownerName,
  }) {
    return '【一对一私聊上下文】\n'
        '你正在和真人用户叫「$ownerName」的人一对一私聊。'
        '请自然回应对方当前消息，像真实私信一样有来有回。'
        '不要替别人发言，不要说自己是 AI，不要带自己的名字前缀。';
  }

  /// **Stage 16 退役**：此方法读取 [AICharacter.memorySummary] 注入 Prompt，
  /// 已不再被运行时调用。永久记忆由 [MemoryContextSelector] 统一注入。
  /// 保留供兼容测试使用，不得在新生成入口恢复调用。
  static String persistentMemoryPrompt(AICharacter character) {
    final memory = character.memorySummary.trim();
    if (memory.isEmpty) return '';
    return '【跨聊天长期记忆】\n'
        '以下是你在其他私聊或群聊中已经了解的用户信息，'
        '请自然延续，不要宣称在读取记忆：\n$memory';
  }
}

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
    required AICharacter character,
    required String ownerName,
  }) {
    return '【一对一私聊上下文】\n'
        '你正在和真人用户叫「$ownerName」的人一对一私聊。'
        '你是${character.name}，${character.age}岁，身份是${character.role}。'
        '请自然回应对方当前消息，像真实私信一样有来有回。'
        '不要替别人发言，不要说自己是 AI，不要带自己的名字前缀。';
  }
}

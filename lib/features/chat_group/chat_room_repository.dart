import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/message.dart';

/// Persistence facade for the chat page's high-frequency message operations.
class ChatRoomRepository {
  final DatabaseService db;
  final String conversationId;
  final bool isDirectChat;

  const ChatRoomRepository({
    required this.db,
    required this.conversationId,
    required this.isDirectChat,
  });

  Future<void> markRead(DateTime readAt) {
    return isDirectChat
        ? db.markDirectChatRead(conversationId, readAt: readAt)
        : db.markGroupChatRead(conversationId, readAt: readAt);
  }

  Future<void> persistNewMessage(Message message) async {
    await db.messageBox.put(message.id, message);
    await db.addMessageToGroupIndex(message);
  }

  Future<void> updateMessage(Message message) {
    return db.messageBox.put(message.id, message);
  }

  Future<void> deleteMessage(String messageId) {
    return db.deleteMessage(messageId, groupId: conversationId);
  }

  Future<void> persistReplyUsage(AICharacter character) {
    return db.aiCharacterBox.put(character.id, character);
  }

  Future<void> recordTokenUsage({
    required String characterId,
    required int inputTokens,
    required int outputTokens,
    int cachedTokens = 0,
  }) {
    return db.recordTokenUsage(
      characterId: characterId,
      groupId: conversationId,
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      cachedTokens: cachedTokens,
    );
  }
}

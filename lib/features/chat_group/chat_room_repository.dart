import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/database/data_lifecycle_service.dart';
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
    await db.persistMessage(message);
  }

  Future<MessagePage> loadLatest({int limit = 80}) =>
      db.loadLatestMessages(conversationId, limit: limit);

  Future<MessagePage> loadOlder(String beforeMessageId, {int limit = 80}) =>
      db.loadMessagesBefore(
        conversationId,
        beforeMessageId: beforeMessageId,
        limit: limit,
      );

  Future<MessagePage> loadAround(String messageId, {int limit = 80}) =>
      db.loadMessagesAround(conversationId, messageId, limit: limit);

  Future<List<Message>> search(String query) =>
      db.searchMessages(conversationId, query);

  Future<void> updateMessage(Message message) {
    return db.updateMessage(message);
  }

  Future<void> deleteMessage(String messageId) async {
    await DataLifecycleService(db: db)
        .deleteMessage(messageId, groupId: conversationId);
  }

  /// 删除该会话的所有消息（清空对话），不影响记忆和关系数据。
  Future<int> deleteAllMessages() async {
    final box = db.messageBox;
    final toDelete = <String>[];
    for (final key in box.keys) {
      final message = box.get(key);
      if (message == null) continue;
      if (message.groupId == conversationId) {
        toDelete.add(key.toString());
      }
    }
    for (final key in toDelete) {
      await box.delete(key);
    }
    return toDelete.length;
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

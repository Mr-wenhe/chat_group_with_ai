import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/database/data_lifecycle_models.dart';
import 'package:chat_group/core/database/data_lifecycle_service.dart';
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

  Future<DataLifecycleResult> deleteMessage(
    String messageId, {
    bool invalidateGroupMemory = true,
    bool keepReplyReferences = false,
  }) {
    return DataLifecycleService(db: db).deleteMessage(
      messageId,
      groupId: conversationId,
      invalidateGroupMemory: invalidateGroupMemory,
      keepReplyReferences: keepReplyReferences,
    );
  }

  /// 批量删除这一次勾选的消息，语义与 [deleteMessage] 一致。
  Future<DataLifecycleResult> deleteMessages(Iterable<String> messageIds) {
    return DataLifecycleService(db: db).deleteMessages(
      messageIds,
      groupId: conversationId,
    );
  }

  /// 只清空这个会话的消息，记忆、关系与任务都保留。
  Future<DataLifecycleResult> clearConversationMessages() {
    return DataLifecycleService(db: db)
        .clearConversationMessages(conversationId);
  }

  /// Clears this exact group or DM conversation through the lifecycle service.
  Future<DataLifecycleResult> clearConversation({
    bool deleteAssociatedPermanentData = false,
  }) {
    return DataLifecycleService(db: db).clearConversation(
      conversationId,
      deleteAssociatedPermanentData: deleteAssociatedPermanentData,
    );
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

import 'package:hive/hive.dart';

/// Device-local dispatch state, deliberately excluded from portable backups.
/// Only message IDs are stored; content and attachments stay in their message.
class PendingChatReplyStore {
  static const storageKeyPrefix = 'pending_chat_replies:';
  final Box<dynamic> settings;
  final String conversationId;

  const PendingChatReplyStore(this.settings, this.conversationId);

  String get storageKey => '$storageKeyPrefix$conversationId';

  List<String> get messageIds {
    final raw = settings.get(storageKey);
    return raw is List ? raw.whereType<String>().toSet().toList() : [];
  }

  Future<void> add(String messageId) =>
      settings.put(storageKey, {...messageIds, messageId}.toList());

  Future<void> remove(String messageId) {
    if (!messageIds.contains(messageId)) return Future.value();
    final remaining = messageIds..remove(messageId);
    return remaining.isEmpty
        ? settings.delete(storageKey)
        : settings.put(storageKey, remaining);
  }
}

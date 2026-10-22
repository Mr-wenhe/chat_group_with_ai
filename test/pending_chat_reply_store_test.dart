import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/database/data_lifecycle_models.dart';
import 'package:chat_group/core/database/data_lifecycle_service.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/features/backup/backup_setting_keys.dart';
import 'package:chat_group/features/chat_group/pending_chat_reply_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/lifecycle_hive.dart';

void main() {
  late Directory directory;
  late DatabaseService db;
  late PendingChatReplyStore store;
  setUpAll(() async {
    directory = await openLifecycleHive();
    db = DatabaseService();
    store = PendingChatReplyStore(db.appSettingsBox, 'dm:va');
  });
  tearDownAll(() => closeLifecycleHive(directory, db));

  test('待回复队列保留顺序和会话边界，不携带到备份', () async {
    final other = PendingChatReplyStore(db.appSettingsBox, 'dm:vb');
    await store.add('u1');
    await store.add('u2');
    await store.add('u1');
    await other.add('u3');
    expect(store.messageIds, ['u1', 'u2']);
    expect(other.messageIds, ['u3']);
    expect(isBackupCarriedSettingKey(store.storageKey), isFalse);
    await store.remove('u1');
    expect(store.messageIds, ['u2']);
    await store.remove('u2');
    expect(db.appSettingsBox.containsKey(store.storageKey), isFalse);
  });

  test('删消息、清聊天记录、删会话和清聊天数据同步清理待回复', () async {
    final lifecycle = DataLifecycleService(db: db);
    final message = Message(
        id: 'pending-delete',
        groupId: 'dm:va',
        senderId: 'user',
        senderType: 'user',
        content: '在吗');
    await db.messageBox.put(message.id, message);
    await store.add(message.id);
    await lifecycle.deleteMessage(message.id, groupId: 'dm:va');
    expect(store.messageIds, isEmpty);
    await store.add('clear-messages');
    await lifecycle.clearConversationMessages('dm:va');
    expect(db.appSettingsBox.containsKey(store.storageKey), isFalse);
    await store.add('clear-conversation');
    await lifecycle.clearConversation('dm:va');
    expect(db.appSettingsBox.containsKey(store.storageKey), isFalse);
    await store.add('clear-all');
    await lifecycle.clear(DataClearScope.chatContent);
    expect(db.appSettingsBox.containsKey(store.storageKey), isFalse);
  });
}

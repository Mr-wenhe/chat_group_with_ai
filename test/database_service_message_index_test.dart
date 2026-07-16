import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/media_attachment.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/features/direct_chat/direct_chat_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('chat_group_hive_test_');
    Hive.init(tempDir.path);
    if (!Hive.isAdapterRegistered(2)) {
      Hive.registerAdapter(MessageAdapter());
    }
    if (!Hive.isAdapterRegistered(9)) {
      Hive.registerAdapter(MediaAttachmentAdapter());
    }
    await Hive.openBox<Message>('messages');
    await Hive.openBox<dynamic>('app_settings');
  });

  tearDown(() async {
    await Hive.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('messagesForGroup recovers group history from stale empty index',
      () async {
    final messages = Hive.box<Message>('messages');
    final settings = Hive.box<dynamic>('app_settings');
    final oldMessage = Message(
      id: 'm1',
      groupId: 'group_1',
      senderId: 'user',
      senderType: 'user',
      content: '重启前说过的话',
      timestamp: DateTime(2026, 7, 9, 10),
    );
    await messages.put(oldMessage.id, oldMessage);
    await settings.put('message_ids_by_group', {
      'group_1': <String>[],
    });

    final loaded = await DatabaseService().messagesForGroup('group_1');

    expect(loaded.map((message) => message.content), ['重启前说过的话']);
    expect(settings.get('message_ids_by_group'), {
      'group_1': ['m1'],
    });
  });

  test('messagesForGroup recovers direct chat history from stale empty index',
      () async {
    final messages = Hive.box<Message>('messages');
    final settings = Hive.box<dynamic>('app_settings');
    final conversationId = DirectChatSession.conversationIdFor('char_1');
    final oldMessage = Message(
      id: 'dm1',
      groupId: conversationId,
      senderId: 'char_1',
      senderType: 'ai',
      content: '私聊里重启前的回复',
      timestamp: DateTime(2026, 7, 9, 11),
    );
    await messages.put(oldMessage.id, oldMessage);
    await settings.put('message_ids_by_group', {
      conversationId: <String>[],
    });

    final loaded = await DatabaseService().messagesForGroup(conversationId);

    expect(loaded.map((message) => message.content), ['私聊里重启前的回复']);
    expect(settings.get('message_ids_by_group'), {
      conversationId: ['dm1'],
    });
  });

  test('deleteMessage removes a temporary message and its group index entry',
      () async {
    final db = DatabaseService();
    final progress = Message(
      id: 'agent-progress:task-1',
      groupId: 'group_1',
      senderId: 'worker',
      senderType: 'ai',
      content: '正在规划',
    );
    await db.messageBox.put(progress.id, progress);
    await db.addMessageToGroupIndex(progress);

    await db.deleteMessageRecordAndIndex(
      progress.id,
      groupId: progress.groupId,
    );

    expect(db.messageBox.containsKey(progress.id), isFalse);
    expect(await db.messagesForGroup(progress.groupId), isEmpty);
    expect(Hive.box<dynamic>('app_settings').get('message_ids_by_group'), {
      progress.groupId: <String>[],
    });
  });
}

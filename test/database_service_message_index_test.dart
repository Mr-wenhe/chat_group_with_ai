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

  test('loads a 10000-message conversation by latest, before and around pages',
      () async {
    final db = DatabaseService();
    final base = DateTime(2026, 1, 1);
    final messages = <String, Message>{
      for (var i = 0; i < 10000; i++)
        'm$i': Message(
          id: 'm$i',
          groupId: 'large',
          senderId: i.isEven ? 'user' : 'ai',
          senderType: i.isEven ? 'user' : 'ai',
          content: 'message $i',
          timestamp: base.add(Duration(seconds: i)),
        ),
    };
    await db.messageBox.putAll(messages);
    await db.rebuildMessageIndex();

    final latest = await db.loadLatestMessages('large', limit: 80);
    expect(latest.messages, hasLength(80));
    expect(latest.messages.first.id, 'm9920');
    expect(latest.hasOlder, isTrue);

    final older = await db.loadMessagesBefore(
      'large',
      beforeMessageId: latest.messages.first.id,
      limit: 80,
    );
    expect(older.messages.first.id, 'm9840');
    expect(older.messages.last.id, 'm9919');

    final around = await db.loadMessagesAround('large', 'm5000', limit: 51);
    expect(around.messages.map((message) => message.id), contains('m5000'));
    expect(around.messages, hasLength(51));
  });

  test('summary index updates incrementally and search covers unloaded history',
      () async {
    final db = DatabaseService();
    final first = Message(
      id: 'first',
      groupId: 'g1',
      senderId: 'ai',
      senderType: 'ai',
      content: 'old searchable needle',
      timestamp: DateTime(2026, 1, 1),
    );
    final last = Message(
      id: 'last',
      groupId: 'g1',
      senderId: 'user',
      senderType: 'user',
      content: 'latest',
      timestamp: DateTime(2026, 1, 2),
    );

    await db.persistMessage(first);
    await db.persistMessage(last);

    final summary = db.conversationSummaries()['g1']!;
    expect(summary.lastMessageId, 'last');
    expect(summary.preview, 'latest');
    expect(summary.messageCount, 2);
    expect(
      (await db.searchMessages('g1', 'needle')).single.id,
      'first',
    );
  });

  test('marking group and direct conversations read clears cached unread',
      () async {
    final db = DatabaseService();
    for (final conversationId in ['group-read', 'dm:character-read']) {
      for (var index = 0; index < 3; index++) {
        await db.persistMessage(Message(
          id: '$conversationId-$index',
          groupId: conversationId,
          senderId: 'ai',
          senderType: 'ai',
          content: '@我 unread $index',
          timestamp: DateTime(2026, 1, 1, 0, index),
        ));
      }
      expect(db.conversationSummaries()[conversationId]?.unreadCount, 3);

      if (conversationId.startsWith('dm:')) {
        await db.markDirectChatRead(
          conversationId,
          readAt: DateTime(2026, 1, 1, 1),
        );
      } else {
        await db.markGroupChatRead(
          conversationId,
          readAt: DateTime(2026, 1, 1, 1),
        );
      }

      final readSummary = db.conversationSummaries()[conversationId]!;
      expect(readSummary.unreadCount, 0);
      expect(readSummary.mentionCount, 0);

      await db.persistMessage(Message(
        id: '$conversationId-next',
        groupId: conversationId,
        senderId: 'ai',
        senderType: 'ai',
        content: 'new unread',
        timestamp: DateTime(2026, 1, 2),
      ));
      expect(db.conversationSummaries()[conversationId]?.unreadCount, 1);
    }
  });

  test('50000-message fixture rebuilds 100 conversation summaries', () async {
    final db = DatabaseService();
    final base = DateTime(2026, 1, 1);
    final messages = <String, Message>{};
    for (var index = 0; index < 50000; index++) {
      final id = 'fixture-$index';
      messages[id] = Message(
        id: id,
        groupId: 'group-${index % 100}',
        senderId: index.isEven ? 'user' : 'ai',
        senderType: index.isEven ? 'user' : 'ai',
        content: 'fixture message $index',
        timestamp: base.add(Duration(seconds: index)),
      );
    }
    await db.messageBox.putAll(messages);
    await db.rebuildMessageIndex();

    final stopwatch = Stopwatch()..start();
    final summaries = db.conversationSummaries();
    stopwatch.stop();

    expect(summaries, hasLength(100));
    expect(summaries['group-0']?.messageCount, 500);
    expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 100)));
  });
}

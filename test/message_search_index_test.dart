import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/media_attachment.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/features/search/message_search_index.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/lifecycle_hive.dart';

void main() {
  late Directory directory;
  late DatabaseService db;

  setUp(() async {
    directory = await openLifecycleHive();
    db = DatabaseService();
    await db.chatGroupBox.put(
      'g1',
      ChatGroup(
        id: 'g1',
        name: '产品讨论',
        theme: '工作',
        aiCharacterIds: const ['c1'],
      ),
    );
    await db.aiCharacterBox.put('c1', testCharacter('c1')..name = '小薇');
  });

  tearDown(() => closeLifecycleHive(directory));

  test('searches Chinese, sender names and attachment names with filters',
      () async {
    await db.messageBox.putAll({
      'm1': Message(
        id: 'm1',
        groupId: 'g1',
        senderId: 'c1',
        senderType: 'ai',
        content: '发布计划在星期五确认',
        timestamp: DateTime(2026, 7, 1),
        isMention: true,
      ),
      'm2': Message(
        id: 'm2',
        groupId: 'g1',
        senderId: 'user',
        senderType: 'user',
        content: '请看附件',
        timestamp: DateTime(2026, 7, 2),
        media: [
          MediaAttachment(
            id: 'f1',
            type: 'file',
            localPath: '/tmp/quarterly_report.csv',
            fileName: 'quarterly_report.csv',
          ),
        ],
      ),
    });
    final index = MessageSearchIndex(db);
    await index.rebuild();

    expect((await index.query('星期五')).single.messageId, 'm1');
    expect((await index.query('小薇')).single.messageId, 'm1');
    expect((await index.query('quarterly_report')).single.messageId, 'm2');
    expect(
      (await index.query(
        '附件',
        filters: MessageSearchFilters(
          senderId: 'user',
          from: DateTime(2026, 7, 2),
          to: DateTime(2026, 7, 2, 23, 59),
          attachmentType: 'file',
        ),
      ))
          .single
          .messageId,
      'm2',
    );
    expect(
      (await index.query(
        '发布',
        filters: const MessageSearchFilters(mentionsOnly: true),
      ))
          .single
          .messageId,
      'm1',
    );
  });

  test('deleted source messages never become ghost results', () async {
    final message = Message(
      id: 'gone',
      groupId: 'g1',
      senderId: 'user',
      senderType: 'user',
      content: '幽灵关键词',
    );
    await db.messageBox.put(message.id, message);
    final index = MessageSearchIndex(db);
    await index.rebuild();
    await db.messageBox.delete(message.id);

    expect(await index.query('幽灵关键词'), isEmpty);
  });

  test('a cleared index rebuilds from source messages on the next query',
      () async {
    final message = Message(
      id: 'rebuild',
      groupId: 'g1',
      senderId: 'user',
      senderType: 'user',
      content: '重启后仍可检索',
    );
    await db.messageBox.put(message.id, message);
    final index = MessageSearchIndex(db);
    await index.rebuild();
    await index.clear();

    expect(index.status.indexedMessages, 0);
    expect((await index.query('仍可检索')).single.messageId, message.id);
  });

  test('50000-message keyword query stays below the phase baseline', () async {
    final messages = <String, Message>{};
    for (var i = 0; i < 50000; i++) {
      messages['m$i'] = Message(
        id: 'm$i',
        groupId: 'g1',
        senderId: 'user',
        senderType: 'user',
        content: i == 43210 ? '唯一性能针 needle-43210' : '普通消息 $i',
        timestamp: DateTime(2026, 1, 1).add(Duration(seconds: i)),
      );
    }
    await db.messageBox.putAll(messages);
    final index = MessageSearchIndex(db);
    await index.rebuild();

    final stopwatch = Stopwatch()..start();
    final result = await index.query('needle-43210');
    stopwatch.stop();

    expect(result.single.messageId, 'm43210');
    expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 500)));
  });

  test(
      'ensureReady rebuilds when a message is deleted and another added '
      '(same total count)', () async {
    // 初始：一条旧消息，构建索引。
    await db.messageBox.put(
      'old',
      Message(
        id: 'old',
        groupId: 'g1',
        senderId: 'user',
        senderType: 'user',
        content: '旧话题收尾',
      ),
    );
    final index = MessageSearchIndex(db);
    await index.rebuild();
    expect((await index.query('旧话题')).single.messageId, 'old');

    // 删旧 + 加新：消息总数仍为 1，索引长度也为 1。
    // 修复前 ensureReady 仅比较长度，不会重建，新消息搜不到。
    await db.messageBox.delete('old');
    await db.messageBox.put(
      'fresh',
      Message(
        id: 'fresh',
        groupId: 'g1',
        senderId: 'user',
        senderType: 'user',
        content: '全新话题开始',
      ),
    );

    // 修复后应能搜到新消息，且搜不到已删除的旧消息。
    expect((await index.query('全新话题')).single.messageId, 'fresh');
    expect(await index.query('旧话题'), isEmpty);
  });
}

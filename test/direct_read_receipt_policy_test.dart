import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/features/chat_group/direct_read_receipt_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('空流式占位消息不能把用户消息标成已读', () {
    final user = Message(
        groupId: 'dm:c1', senderId: 'user', senderType: 'user', content: '在吗');
    final draft = Message(
        groupId: 'dm:c1', senderId: 'c1', senderType: 'ai', content: '');
    expect(directReadUserMessageIds([user, draft]), isEmpty);
    draft.content = '正在生成的正文';
    expect(
        directReadUserMessageIds([user, draft], streamingMessageId: draft.id),
        isEmpty);
    expect(directReadUserMessageIds([user, draft]), {user.id});
  });

  test('only user messages before a later AI reply are marked read', () {
    final first = Message(
      id: 'u1',
      groupId: 'dm:c1',
      senderId: 'user',
      senderType: 'user',
      content: '第一条',
    );
    final reply = Message(
      id: 'a1',
      groupId: 'dm:c1',
      senderId: 'c1',
      senderType: 'ai',
      content: '回复',
    );
    final latest = Message(
      id: 'u2',
      groupId: 'dm:c1',
      senderId: 'user',
      senderType: 'user',
      content: '最新一条',
    );

    expect(directReadUserMessageIds([first, reply, latest]), {'u1'});
  });
}

import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/features/chat_group/direct_read_receipt_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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

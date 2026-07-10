import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/features/chat_group/chat_room_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('suppresses an identical AI answer in the same recent exchange', () {
    final recent = [
      Message(
        groupId: 'g',
        senderId: 'user',
        senderType: 'user',
        content: '你们怎么看？',
      ),
      Message(
        groupId: 'g',
        senderId: 'a',
        senderType: 'ai',
        content: '我觉得这个方案可以。',
      ),
    ];

    expect(
      isDuplicateAiReply('我觉得这个方案   可以。', recent),
      isTrue,
    );
  });

  test('keeps a genuinely different answer', () {
    final recent = [
      Message(
        groupId: 'g',
        senderId: 'a',
        senderType: 'ai',
        content: '我赞成。',
      ),
    ];

    expect(isDuplicateAiReply('我不赞成，风险太高。', recent), isFalse);
  });

  test('does not compare against user messages', () {
    final recent = [
      Message(
        groupId: 'g',
        senderId: 'user',
        senderType: 'user',
        content: '原样返回',
      ),
    ];

    expect(isDuplicateAiReply('原样返回', recent), isFalse);
  });
}

import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/text/entity_labels.dart';
import 'package:chat_group/features/chat_group/widgets/chat_message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _memberId = 'e1f80660-581f-488b-b8e6-94cb63192ec1';

Message _systemMessage(String content) => Message(
      id: 'm-1',
      groupId: 'group-1',
      senderId: '',
      senderType: Message.senderTypeSystem,
      content: content,
      timestamp: DateTime(2026, 10, 15, 19, 59),
    );

Future<void> _pumpBubble(
  WidgetTester tester,
  Message message, {
  EntityLabels? labels,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: ChatMessageBubble(
        message: message,
        characters: const <AICharacter>[],
        cs: const ColorScheme.light(),
        senderColor: (_) => Colors.blue,
        ownerName: '文和先生',
        entityLabels: labels,
      ),
    ),
  ));
  await tester.pump();
}

void main() {
  testWidgets('系统提醒里的成员 id 显示为角色名', (tester) async {
    await _pumpBubble(
      tester,
      _systemMessage('成员 $_memberId：成员当前资格或配置不可用。'),
      labels: EntityLabels.fixed(const {_memberId: '产品经理'}),
    );

    expect(
      find.textContaining('成员 产品经理：成员当前资格或配置不可用。'),
      findsOneWidget,
    );
    expect(find.textContaining(_memberId), findsNothing);
  });

  testWidgets('用户自己打的 UUID 原样显示（真人原话不改写）', (tester) async {
    final message = Message(
      id: 'm-2',
      groupId: 'group-1',
      senderId: 'user',
      senderType: Message.senderTypeUser,
      content: '看看 $_memberId 这条',
      timestamp: DateTime(2026, 10, 15, 20, 0),
    );
    await _pumpBubble(
      tester,
      message,
      labels: EntityLabels.fixed(const {_memberId: '产品经理'}),
    );

    expect(find.textContaining(_memberId), findsOneWidget);
  });

  testWidgets('labels 为空时不崩、文本原样', (tester) async {
    await _pumpBubble(tester, _systemMessage('成员 $_memberId：不可用。'));
    expect(find.textContaining('未知对象（e1f80660）'), findsNothing);
    expect(find.textContaining(_memberId), findsOneWidget);
  });
}

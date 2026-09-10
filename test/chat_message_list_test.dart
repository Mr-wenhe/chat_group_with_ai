import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/features/chat_group/widgets/chat_message_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('unknown sender placeholder cannot open character settings',
      (tester) async {
    var tappedSender = false;
    final unknownCharacter = AICharacter(
      name: '已删除角色',
      avatar: '?',
      age: 0,
      role: '',
      personalityTags: const [],
      systemPrompt: '',
      apiKey: '',
      apiProvider: 'deepseek',
    );
    final message = Message(
      id: 'system-message',
      groupId: 'group-1',
      senderId: 'system',
      senderType: 'ai',
      content: '工作模式未启动',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatMessageList(
            messages: [message],
            characters: const [],
            messageIndex: {message.id: message},
            characterIndex: const {},
            scrollController: ScrollController(),
            controller: ChatMessageListController(),
            streamingMessageId: null,
            regeneratingMessageId: null,
            highlightedMentionMessageId: null,
            isDirectChat: false,
            readUserMessageIds: const {},
            ownerName: '我',
            unknownCharacter: unknownCharacter,
            senderColor: (_) => Colors.blue,
            senderNameById: (_) => '未知发送者',
            onLongPress: (_, __) {},
            onSenderTap: (_) => tappedSender = true,
            onMentionSender: (_) {},
            onQuotedTap: (_) {},
          ),
        ),
      ),
    );

    await tester.tap(find.text('已删除角色'));

    expect(tappedSender, isFalse);
  });

  testWidgets('current sender remains able to open character settings',
      (tester) async {
    var tappedSender = false;
    final character = AICharacter(
      id: 'character-1',
      name: '程序媛',
      avatar: '程',
      age: 28,
      role: '工程师',
      personalityTags: const [],
      systemPrompt: '帮助用户完成工作。',
      apiKey: '',
      apiProvider: 'deepseek',
    );
    final message = Message(
      id: 'character-message',
      groupId: 'group-1',
      senderId: character.id,
      senderType: 'ai',
      content: '我来帮你处理。',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatMessageList(
            messages: [message],
            characters: [character],
            messageIndex: {message.id: message},
            characterIndex: {character.id: character},
            scrollController: ScrollController(),
            controller: ChatMessageListController(),
            streamingMessageId: null,
            regeneratingMessageId: null,
            highlightedMentionMessageId: null,
            isDirectChat: false,
            readUserMessageIds: const {},
            ownerName: '我',
            unknownCharacter: character,
            editableSenderIds: {character.id},
            senderColor: (_) => Colors.blue,
            senderNameById: (_) => character.name,
            onLongPress: (_, __) {},
            onSenderTap: (_) => tappedSender = true,
            onMentionSender: (_) {},
            onQuotedTap: (_) {},
          ),
        ),
      ),
    );

    await tester.tap(find.text('程序媛'));

    expect(tappedSender, isTrue);
  });
}

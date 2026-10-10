import 'dart:typed_data';

import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/widgets/character_avatar.dart';
import 'package:chat_group/features/chat_group/widgets/chat_message_list.dart';
import 'package:chat_group/features/work_mode/work_task_user_action.dart';
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
            avatarImageOf: (_) => null,
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
            avatarImageOf: (_) => null,
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

  testWidgets('task reminder button invokes the exact task action',
      (tester) async {
    WorkTaskUserAction? received;
    const action = WorkTaskUserAction(
      taskId: 'task-old',
      blockerId: 'commandApproval',
      version: 42,
      kind: WorkTaskUserActionKind.approveCommand,
    );
    final message = Message(
      id: action.messageId,
      groupId: 'group-1',
      senderId: 'system',
      senderType: 'system',
      content: '@我 系统任务提醒：请处理任务。',
      isMention: true,
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
            unknownCharacter: AICharacter(
              name: '未知角色',
              avatar: '?',
              age: 0,
              role: '',
              personalityTags: const [],
              systemPrompt: '',
              apiKey: '',
              apiProvider: 'deepseek',
            ),
            senderColor: (_) => Colors.blue,
            avatarImageOf: (_) => null,
            senderNameById: (_) => '系统',
            onLongPress: (_, __) {},
            onSenderTap: (_) {},
            onMentionSender: (_) {},
            onQuotedTap: (_) {},
            onTaskAction: (value) => received = value,
          ),
        ),
      ),
    );

    final button = find.byKey(ValueKey<String>(action.messageId));
    expect(button, findsOneWidget);
    expect(tester.getSemantics(button).label, contains(action.semanticLabel));
    await tester.tap(button);
    expect(received?.taskId, 'task-old');
    expect(received?.blockerId, 'commandApproval');
    expect(received?.version, 42);
  });

  testWidgets('task reminder button stays actionable in a direct chat',
      (tester) async {
    WorkTaskUserAction? received;
    const action = WorkTaskUserAction(
      taskId: 'task-dm',
      blockerId: 'commandApproval',
      version: 7,
      kind: WorkTaskUserActionKind.approveCommand,
    );
    final message = Message(
      id: action.messageId,
      groupId: 'dm:worker',
      senderId: 'system',
      senderType: 'system',
      content: '@我 系统任务提醒：请处理任务。',
      isMention: true,
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
            isDirectChat: true,
            readUserMessageIds: const {},
            ownerName: '我',
            unknownCharacter: AICharacter(
              name: '未知角色',
              avatar: '?',
              age: 0,
              role: '',
              personalityTags: const [],
              systemPrompt: '',
              apiKey: '',
              apiProvider: 'deepseek',
            ),
            senderColor: (_) => Colors.blue,
            avatarImageOf: (_) => null,
            senderNameById: (_) => '系统',
            onLongPress: (_, __) {},
            onSenderTap: (_) {},
            onMentionSender: (_) {},
            onQuotedTap: (_) {},
            onTaskAction: (value) => received = value,
          ),
        ),
      ),
    );

    // 私聊同样会收到任务卡住时的提醒。文案写着"请点击打开对应任务"，按钮就
    // 必须可点，否则私聊里唯一的处理入口是灰的。
    final button = find.byKey(ValueKey<String>(action.messageId));
    expect(button, findsOneWidget);
    expect(tester.widget<OutlinedButton>(button).onPressed, isNotNull);
    await tester.tap(button);
    expect(received?.taskId, 'task-dm');
  });

  group('我的头像落在气泡右侧', () {
    AICharacter fallbackCharacter() => AICharacter(
          name: '已删除角色',
          avatar: '?',
          age: 0,
          role: '',
          personalityTags: const [],
          systemPrompt: '',
          apiKey: '',
          apiProvider: 'deepseek',
        );

    Future<void> pumpUserBubble(
      WidgetTester tester, {
      required ImageProvider? userAvatarImage,
      String userAvatarText = '',
    }) async {
      final message = Message(
        id: 'user-message',
        groupId: 'group-1',
        senderId: 'user',
        senderType: 'user',
        content: '你好',
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
              unknownCharacter: fallbackCharacter(),
              userAvatarImage: userAvatarImage,
              userAvatarText: userAvatarText,
              senderColor: (_) => Colors.blue,
              avatarImageOf: (_) => null,
              senderNameById: (_) => '我',
              onLongPress: (_, __) {},
              onSenderTap: (_) {},
              onMentionSender: (_) {},
              onQuotedTap: (_) {},
            ),
          ),
        ),
      );
    }

    testWidgets('「设为头像」开着：出图且落在气泡右侧', (tester) async {
      // 注入 MemoryImage 而非 FileImage：`testWidgets` 的 FakeAsync 区里
      // 真实文件解码永不完成，会让整个用例 hang 死。
      await pumpUserBubble(
        tester,
        userAvatarImage: MemoryImage(Uint8List.fromList(_kTransparentPng)),
      );

      expect(find.byType(CharacterAvatar), findsOneWidget);
      // 有图就不再叠 fallback 文本，避免图上压字。
      expect(find.text('我'), findsNothing);
      final decoration = tester
          .widget<Container>(
            find.descendant(
              of: find.byType(CharacterAvatar),
              matching: find.byType(Container),
            ).first,
          )
          .decoration! as BoxDecoration;
      expect(decoration.image, isNotNull);

      // 头像必须在气泡内容右侧（微信/企微风格），不能因为复用 AI 分支跑到左边。
      expect(
        tester.getCenter(find.byType(CharacterAvatar)).dx,
        greaterThan(tester.getCenter(find.text('你好')).dx),
      );
    });

    testWidgets('开关关 / 无图：回落 emoji 头像，而不是名字首字', (tester) async {
      // 回归锁：资料页与气泡必须同一条回落。这里曾漏读 UserProfile.avatar，
      // 结果资料页显示 emoji、气泡里只剩「我」。
      await pumpUserBubble(tester, userAvatarImage: null, userAvatarText: '🐱');

      expect(find.text('🐱'), findsOneWidget);
      expect(find.text('我'), findsNothing);
    });

    testWidgets('emoji 也没填时才退回名字首字', (tester) async {
      await pumpUserBubble(tester, userAvatarImage: null, userAvatarText: '   ');

      expect(find.text('我'), findsOneWidget);
      expect(
        tester.getCenter(find.byType(CharacterAvatar)).dx,
        greaterThan(tester.getCenter(find.text('你好')).dx),
      );
    });
  });
}

/// 1×1 透明 PNG，用于喂 [MemoryImage]。
const List<int> _kTransparentPng = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
];

import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/permanent_memory.dart';
import 'package:chat_group/features/chat_group/chat_room_page.dart';
import 'package:chat_group/features/chat_group/widgets/chat_message_list.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/lifecycle_hive.dart';

void main() {
  late Directory directory;
  late DatabaseService db;
  const ttsChannel = MethodChannel('flutter_tts');

  setUpAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ttsChannel, (call) async => 1);
    directory = await openLifecycleHive();
    db = DatabaseService();
  });

  setUp(() async {
    await db.aiCharacterBox.clear();
    await db.chatGroupBox.clear();
    await db.messageBox.clear();
    await db.permanentMemoryBox.clear();
    await db.chatGroupBox.put(
      'g1',
      ChatGroup(
        id: 'g1',
        name: '测试群',
        theme: '测试',
        aiCharacterIds: const [],
      ),
    );
  });

  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ttsChannel, null);
    await closeLifecycleHive(directory, db);
  });

  Future<void> pumpUntilMemoryEntry(WidgetTester tester) async {
    final entry = find.byTooltip('查看记忆');
    for (var attempt = 0; attempt < 20 && entry.evaluate().isEmpty; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(entry, findsOneWidget);
  }

  Future<void> pumpUntilTextField(WidgetTester tester) async {
    final textField = find.byType(TextField);
    for (var attempt = 0;
        attempt < 20 && textField.evaluate().isEmpty;
        attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(textField, findsOneWidget);
  }

  Future<void> disposeChatRoomTree(WidgetTester tester) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      if (find.text('记忆详情').evaluate().isEmpty &&
          find.text('永久记忆').evaluate().isEmpty) {
        break;
      }
      await tester.pageBack();
      await tester.pump();
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump();
  }

  testWidgets('reactivated chat room accepts UI state updates', (tester) async {
    addTearDown(() async {
      // Dispose the room before tearDownAll closes the shared Hive fixture.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });

    final hostKey = GlobalKey<_RelocatingHostState>();
    await tester.runAsync(() async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [databaseServiceProvider.overrideWithValue(db)],
          child: MaterialApp(
            home: _RelocatingHost(
              key: hostKey,
              roomKey: GlobalKey(),
            ),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump(const Duration(milliseconds: 100));

    await pumpUntilTextField(tester);

    hostKey.currentState!.moveRoom();
    await tester.pump();
    await tester.enterText(find.byType(TextField), '重新激活');
    await tester.pump();

    final send = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.send_rounded),
        matching: find.byType(IconButton),
      ),
    );
    expect(send.onPressed, isNotNull);
  });

  testWidgets(
      'external updates outside the visible message page do not add a duplicate',
      (tester) async {
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
    const conversationId = 'g1';
    final messageTime = DateTime(2026, 8, 13, 13);
    await tester.runAsync(() async {
      for (var index = 0; index < 100; index++) {
        await db.messageBox.put(
          'page-message-$index',
          Message(
            id: 'page-message-$index',
            groupId: conversationId,
            senderId: 'user',
            senderType: 'user',
            content: '历史消息 $index',
            timestamp: messageTime.add(Duration(minutes: index)),
          ),
        );
      }
    });

    await tester.runAsync(() async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [databaseServiceProvider.overrideWithValue(db)],
          child: const MaterialApp(
            home: ChatRoomPage(groupId: conversationId),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump(const Duration(milliseconds: 100));
    await pumpUntilTextField(tester);

    final messageList = find.byType(ChatMessageList);
    final before = tester.widget<ChatMessageList>(messageList).messages.length;
    expect(before, 80);

    await tester.runAsync(() async {
      await db.messageBox.put(
        'page-message-0',
        Message(
          id: 'page-message-0',
          groupId: conversationId,
          senderId: 'user',
          senderType: 'user',
          content: '窗口外消息被更新',
          timestamp: messageTime,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();

    final afterUpdate =
        tester.widget<ChatMessageList>(messageList).messages.length;
    expect(afterUpdate, before);
    expect(find.text('窗口外消息被更新'), findsNothing);

    await tester.runAsync(() async {
      await db.messageBox.delete('page-message-1');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    expect(
      tester.widget<ChatMessageList>(messageList).messages.length,
      before,
    );
  });

  testWidgets('group memory entry opens a read-only scoped detail page',
      (tester) async {
    addTearDown(() async {
      await disposeChatRoomTree(tester);
    });
    final member = testCharacter('memory-entry-member', apiConfigId: 'cfg')
      ..name = '群内 AI';
    await tester.runAsync(() async {
      await db.aiCharacterBox.put(member.id, member);
      await db.chatGroupBox.put(
        'memory-entry-group',
        ChatGroup(
          id: 'memory-entry-group',
          name: '记忆测试群',
          theme: '测试',
          aiCharacterIds: [member.id],
        ),
      );
      await db.permanentMemoryBox.put(
        'memory-entry-group-memory',
        PermanentMemory(
          id: 'memory-entry-group-memory',
          observerCharacterId: member.id,
          kind: MemoryKind.fact,
          content: '群聊入口记忆',
          subjectIds: const ['user'],
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: '记忆测试群',
        ),
      );
    });

    await tester.runAsync(() async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [databaseServiceProvider.overrideWithValue(db)],
          child: const MaterialApp(
            home: ChatRoomPage(groupId: 'memory-entry-group'),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump(const Duration(milliseconds: 100));
    await pumpUntilMemoryEntry(tester);
    await tester.tap(find.byTooltip('查看记忆'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('群聊入口记忆'), findsOneWidget);
    expect(find.byKey(const ValueKey('memory-detail-pin')), findsNothing);
    expect(find.byKey(const ValueKey('memory-detail-correct')), findsNothing);
    expect(find.byKey(const ValueKey('memory-detail-delete')), findsNothing);
  });

  testWidgets(
      'group memory entry scopes current members and preserves chat position',
      (tester) async {
    addTearDown(() async {
      await disposeChatRoomTree(tester);
    });
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final member = testCharacter('memory-scope-member', apiConfigId: 'cfg')
      ..name = '当前群观察 AI';
    final secondMember =
        testCharacter('memory-scope-second-member', apiConfigId: 'cfg')
          ..name = '当前群另一位 AI';
    final historicalOutside =
        testCharacter('memory-scope-historical-outside', apiConfigId: 'cfg')
          ..name = '历史群外 AI';
    const conversationId = 'memory-entry-group-state';
    final messageTime = DateTime(2026, 8, 13, 13);

    await tester.runAsync(() async {
      await db.aiCharacterBox.putAll({
        member.id: member,
        secondMember.id: secondMember,
        historicalOutside.id: historicalOutside,
      });
      await db.chatGroupBox.put(
        conversationId,
        ChatGroup(
          id: conversationId,
          name: '群聊状态测试群',
          theme: '测试',
          aiCharacterIds: [member.id, secondMember.id],
        ),
      );
      await db.permanentMemoryBox.putAll({
        'memory-entry-group-state-visible': PermanentMemory(
          id: 'memory-entry-group-state-visible',
          observerCharacterId: member.id,
          kind: MemoryKind.fact,
          content: '当前群观察者可见记忆',
          subjectIds: const ['user'],
          status: MemoryStatus.active,
          originType: MemoryOriginType.direct,
          originConversationId: 'dm:historical-source',
          originNameSnapshot: '另一处私聊',
        ),
        'memory-entry-group-state-outside-observer': PermanentMemory(
          id: 'memory-entry-group-state-outside-observer',
          observerCharacterId: historicalOutside.id,
          kind: MemoryKind.fact,
          content: '群外观察者不可见记忆',
          subjectIds: const ['user'],
          status: MemoryStatus.active,
          originType: MemoryOriginType.group,
          originNameSnapshot: '历史群聊',
        ),
      });
      for (var index = 0; index < 40; index++) {
        await db.messageBox.put(
          'memory-entry-group-message-$index',
          Message(
            id: 'memory-entry-group-message-$index',
            groupId: conversationId,
            senderId: 'user',
            senderType: 'user',
            content: '群聊历史消息 $index',
            timestamp: messageTime.add(Duration(minutes: index)),
          ),
        );
      }
      await db.messageBox.put(
        'memory-entry-group-historical-outside-message',
        Message(
          id: 'memory-entry-group-historical-outside-message',
          groupId: conversationId,
          senderId: historicalOutside.id,
          senderType: 'ai',
          content: '历史群外发言',
          timestamp: messageTime.add(const Duration(minutes: 40)),
        ),
      );
    });

    await tester.runAsync(() async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [databaseServiceProvider.overrideWithValue(db)],
          child: const MaterialApp(
            home: ChatRoomPage(groupId: conversationId),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump(const Duration(milliseconds: 100));
    await pumpUntilMemoryEntry(tester);

    final messageList = find.byType(ChatMessageList);
    final scrollable = find
        .descendant(
          of: messageList,
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.drag(scrollable, const Offset(0, 320));
    await tester.pump();
    final before = tester.state<ScrollableState>(scrollable).position.pixels;
    expect(before, greaterThan(0));
    expect(find.text('群聊历史消息 35'), findsOneWidget);

    await tester.tap(find.byTooltip('查看记忆'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('当前群观察 AI 的记忆'), findsOneWidget);
    expect(find.byKey(const ValueKey('memory-observer-all')), findsNothing);
    expect(find.byKey(const ValueKey('memory-observer-memory-scope-member')),
        findsOneWidget);
    expect(
        find.byKey(
            const ValueKey('memory-observer-memory-scope-second-member')),
        findsOneWidget);
    expect(
        find.byKey(
            const ValueKey('memory-observer-memory-scope-historical-outside')),
        findsNothing);
    expect(find.text('当前群观察者可见记忆'), findsOneWidget);
    expect(find.text('群外观察者不可见记忆'), findsNothing);
    expect(find.byKey(const ValueKey('memory-detail-pin')), findsNothing);
    expect(find.byKey(const ValueKey('memory-detail-correct')), findsNothing);
    expect(find.byKey(const ValueKey('memory-detail-delete')), findsNothing);

    await tester.pageBack();
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();

    final after = tester.state<ScrollableState>(scrollable).position.pixels;
    expect(find.text('群聊历史消息 35'), findsOneWidget);
    expect(after, closeTo(before, 1.0));
  });

  testWidgets('direct memory entry opens a read-only scoped detail page',
      (tester) async {
    addTearDown(() async {
      await disposeChatRoomTree(tester);
    });
    final target =
        testCharacter('memory-entry-direct-target', apiConfigId: 'cfg')
          ..name = '私聊 AI';
    await tester.runAsync(() async {
      await db.aiCharacterBox.put(target.id, target);
      await db.permanentMemoryBox.put(
        'memory-entry-direct-memory',
        PermanentMemory(
          id: 'memory-entry-direct-memory',
          observerCharacterId: target.id,
          kind: MemoryKind.preference,
          content: '私聊入口记忆',
          subjectIds: const ['user'],
          status: MemoryStatus.active,
          originType: MemoryOriginType.direct,
          originNameSnapshot: '私聊 AI',
        ),
      );
    });

    await tester.runAsync(() async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [databaseServiceProvider.overrideWithValue(db)],
          child: MaterialApp(
            home: ChatRoomPage(groupId: 'dm:${target.id}'),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump(const Duration(milliseconds: 100));
    await pumpUntilMemoryEntry(tester);
    await tester.tap(find.byTooltip('查看记忆'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('私聊入口记忆'), findsOneWidget);
    expect(find.byKey(const ValueKey('memory-detail-pin')), findsNothing);
    expect(find.byKey(const ValueKey('memory-detail-correct')), findsNothing);
    expect(find.byKey(const ValueKey('memory-detail-delete')), findsNothing);
  });

  testWidgets('returning from direct memory keeps messages and scroll position',
      (tester) async {
    addTearDown(() async {
      await disposeChatRoomTree(tester);
    });
    final target = testCharacter('memory-return-direct-target', apiConfigId: '')
      ..name = '状态保留 AI';
    final conversationId = 'dm:${target.id}';
    final messageTime = DateTime(2026, 8, 13, 12);

    await tester.runAsync(() async {
      await db.aiCharacterBox.put(target.id, target);
      await db.permanentMemoryBox.put(
        'memory-return-direct-memory',
        PermanentMemory(
          id: 'memory-return-direct-memory',
          observerCharacterId: target.id,
          kind: MemoryKind.fact,
          content: '返回状态记忆',
          subjectIds: const ['user'],
          status: MemoryStatus.active,
          originType: MemoryOriginType.direct,
          originConversationId: conversationId,
          originNameSnapshot: target.name,
        ),
      );
      for (var index = 0; index < 40; index++) {
        await db.messageBox.put(
          'memory-return-message-$index',
          Message(
            id: 'memory-return-message-$index',
            groupId: conversationId,
            senderId: 'user',
            senderType: 'user',
            content: '私聊历史消息 $index',
            timestamp: messageTime.add(Duration(minutes: index)),
          ),
        );
      }
    });

    await tester.runAsync(() async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [databaseServiceProvider.overrideWithValue(db)],
          child: MaterialApp(
            home: ChatRoomPage(groupId: conversationId),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump(const Duration(milliseconds: 100));
    await pumpUntilMemoryEntry(tester);

    final messageList = find.byType(ChatMessageList);
    final scrollable = find
        .descendant(
          of: messageList,
          matching: find.byType(Scrollable),
        )
        .first;
    expect(scrollable, findsOneWidget);
    await tester.drag(scrollable, const Offset(0, 320));
    await tester.pump();
    final before = tester.state<ScrollableState>(scrollable).position.pixels;
    expect(before, greaterThan(0));
    expect(find.text('私聊历史消息 35'), findsOneWidget);

    await tester.tap(find.byTooltip('查看记忆'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('返回状态记忆'), findsOneWidget);

    await tester.pageBack();
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();

    final after = tester.state<ScrollableState>(scrollable).position.pixels;
    expect(find.text('私聊历史消息 35'), findsOneWidget);
    expect(after, closeTo(before, 1.0));
  });
}

class _RelocatingHost extends StatefulWidget {
  final GlobalKey roomKey;

  const _RelocatingHost({
    super.key,
    required this.roomKey,
  });

  @override
  State<_RelocatingHost> createState() => _RelocatingHostState();
}

class _RelocatingHostState extends State<_RelocatingHost> {
  bool _moved = false;

  void moveRoom() => setState(() => _moved = true);

  Widget _room() => ChatRoomPage(
        key: widget.roomKey,
        groupId: 'g1',
      );

  @override
  Widget build(BuildContext context) {
    return _moved
        ? Padding(padding: const EdgeInsets.all(1), child: _room())
        : Align(alignment: Alignment.topLeft, child: _room());
  }
}

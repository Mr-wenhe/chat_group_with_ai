import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/features/chat_group/chat_room_page.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/lifecycle_hive.dart';

void main() {
  late Directory directory;
  late DatabaseService db;
  const pasteboardChannel = MethodChannel('pasteboard');
  const platformChannel = SystemChannels.platform;
  var clipboardText = '';

  setUpAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pasteboardChannel, (call) async {
      if (call.method == 'files') return <String>[];
      if (call.method == 'image') return null;
      return null;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(platformChannel, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboardText = (call.arguments as Map)['text'] as String? ?? '';
      }
      if (call.method == 'Clipboard.getData') {
        return <String, dynamic>{'text': clipboardText};
      }
      return null;
    });
    directory = await openLifecycleHive();
    db = DatabaseService();
  });

  setUp(() async {
    await db.aiCharacterBox.clear();
    await db.chatGroupBox.clear();
    await db.messageBox.clear();
    await db.chatGroupBox.put(
      'clipboard-paste-group',
      ChatGroup(
        id: 'clipboard-paste-group',
        name: '剪贴板测试群',
        theme: '测试',
        aiCharacterIds: const [],
      ),
    );
  });

  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pasteboardChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(platformChannel, null);
    await closeLifecycleHive(directory, db);
  });

  testWidgets('keyboard paste inserts copied chat text only once',
      (tester) async {
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });

    await tester.runAsync(() async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [databaseServiceProvider.overrideWithValue(db)],
          child: const MaterialApp(
            home: ChatRoomPage(groupId: 'clipboard-paste-group'),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump(const Duration(milliseconds: 100));

    final textField = find.byType(TextField);
    expect(textField, findsOneWidget);

    await tester.tap(textField);
    await tester.pump();
    await Clipboard.setData(const ClipboardData(text: '复制的聊天文案'));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // flutter_test does not synthesize the platform text-input paste that
    // follows Cmd+V on macOS. Invoke the same EditableText action explicitly
    // so the test covers both sides of the real shortcut flow.
    final editableText = tester.state<EditableTextState>(
      find.byType(EditableText),
    );
    await editableText.pasteText(SelectionChangedCause.keyboard);
    await tester.pump();

    expect(
      tester.widget<TextField>(textField).controller!.text,
      '复制的聊天文案',
    );
  });
}

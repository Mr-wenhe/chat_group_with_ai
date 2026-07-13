import 'package:chat_group/core/models/media_attachment.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/features/chat_group/widgets/chat_room_composer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('allows attachment-only messages and forwards send intent',
      (tester) async {
    var sent = false;
    final attachment = MediaAttachment(
      id: 'file',
      type: 'file',
      localPath: '/tmp/report.md',
      fileName: 'report.md',
      fileSize: 100,
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ChatRoomComposer(
          textController: TextEditingController(),
          focusNode: FocusNode(),
          inputFieldKey: GlobalKey(),
          quotedMessage: null,
          quotedSenderName: '',
          attachments: [attachment],
          isDraggingFiles: false,
          isStreaming: false,
          canSend: true,
          isDirectChat: false,
          isDesktop: false,
          onKeyEvent: (_) => KeyEventResult.ignored,
          onTextChanged: (_) {},
          onDragStateChanged: (_) {},
          onDroppedPaths: (_) {},
          onShowAttachmentMenu: () {},
          onPasteAttachments: () {},
          onShowEmojiPanel: () {},
          onCancelQuote: () {},
          onRemoveAttachment: (_) {},
          onStopStreaming: () {},
          onSend: () => sent = true,
        ),
      ),
    ));

    expect(find.text('report.md'), findsOneWidget);
    await tester.tap(find.byTooltip('发送'));
    expect(sent, isTrue);
  });

  testWidgets('shows quoted sender and exposes cancel intent', (tester) async {
    var cancelled = false;
    final quoted = MessageFixture.quoted;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ChatRoomComposer(
          textController: TextEditingController(),
          focusNode: FocusNode(),
          inputFieldKey: GlobalKey(),
          quotedMessage: quoted,
          quotedSenderName: 'Alice',
          attachments: const [],
          isDraggingFiles: false,
          isStreaming: false,
          canSend: false,
          isDirectChat: false,
          isDesktop: false,
          onKeyEvent: (_) => KeyEventResult.ignored,
          onTextChanged: (_) {},
          onDragStateChanged: (_) {},
          onDroppedPaths: (_) {},
          onShowAttachmentMenu: () {},
          onPasteAttachments: () {},
          onShowEmojiPanel: () {},
          onCancelQuote: () => cancelled = true,
          onRemoveAttachment: (_) {},
          onStopStreaming: () {},
          onSend: () {},
        ),
      ),
    ));

    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('quoted content'), findsOneWidget);
    await tester.tap(find.byTooltip('取消引用').first);
    expect(cancelled, isTrue);
  });
}

class MessageFixture {
  static final quoted = Message(
    id: 'quoted',
    groupId: 'group',
    senderId: 'alice',
    senderType: 'ai',
    content: 'quoted content',
  );
}

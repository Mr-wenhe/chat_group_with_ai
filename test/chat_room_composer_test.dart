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

  testWidgets('voice input mic hidden when not enabled for platform',
      (tester) async {
    await tester.pumpWidget(_composer());
    expect(find.byKey(const Key('voice-input-toggle')), findsNothing);
  });

  testWidgets('voice input mic shown when ASR usable and forwards toggle',
      (tester) async {
    var toggles = 0;
    await tester.pumpWidget(_composer(
      showVoiceInput: true,
      voiceInputUsable: true,
      onToggleVoiceInput: () => toggles++,
    ));

    expect(find.byKey(const Key('voice-input-toggle')), findsOneWidget);
    expect(find.byTooltip('语音输入（点击开始，说完再点结束）'), findsOneWidget);
    await tester.tap(find.byKey(const Key('voice-input-toggle')));
    expect(toggles, 1);
  });

  testWidgets('while listening the field is read-only and mic becomes stop',
      (tester) async {
    var toggles = 0;
    await tester.pumpWidget(_composer(
      showVoiceInput: true,
      voiceInputUsable: false,
      voiceInputActive: true,
      onToggleVoiceInput: () => toggles++,
    ));

    // 聆听中即使 ASR 不可用（配置中途被移除）也保持可用：用于结束聆听。
    expect(find.byTooltip('结束语音输入'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isTrue);
    await tester.tap(find.byKey(const Key('voice-input-toggle')));
    expect(toggles, 1);
  });
}

/// 用默认值构造一个可局部覆盖的 [ChatRoomComposer] 测试宿主。
Widget _composer({
  bool showVoiceInput = false,
  bool voiceInputUsable = false,
  bool voiceInputActive = false,
  VoidCallback? onToggleVoiceInput,
  VoidCallback? onSend,
}) {
  return MaterialApp(
    home: Scaffold(
      body: ChatRoomComposer(
        textController: TextEditingController(),
        focusNode: FocusNode(),
        inputFieldKey: GlobalKey(),
        quotedMessage: null,
        quotedSenderName: '',
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
        onCancelQuote: () {},
        onRemoveAttachment: (_) {},
        onStopStreaming: () {},
        onSend: onSend ?? () {},
        showVoiceInput: showVoiceInput,
        voiceInputUsable: voiceInputUsable,
        voiceInputActive: voiceInputActive,
        onToggleVoiceInput: onToggleVoiceInput,
      ),
    ),
  );
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

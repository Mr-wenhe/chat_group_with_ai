import 'package:chat_group/features/chat_group/widgets/compact_conversation_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('group chat renders exactly two compact toggle buttons',
      (tester) async {
    var autoEnabled = false;
    var workModeEnabled = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CompactConversationControls(
          showAutoChat: true,
          autoChatEnabled: false,
          workModeEnabled: false,
          autoChatAvailable: true,
          autoChatTooltip: '自动发言已关闭',
          workModeTooltip: '工作模式已关闭',
          onAutoChatChanged: (value) => autoEnabled = value,
          onWorkModeChanged: (value) => workModeEnabled = value,
        ),
      ),
    ));

    expect(find.byType(Switch), findsNothing);
    expect(find.byType(IconButton), findsNWidgets(2));
    expect(tester.getSize(find.byKey(const Key('auto-chat-toggle'))).width,
        lessThanOrEqualTo(40));
    expect(tester.getSize(find.byKey(const Key('work-mode-toggle'))).width,
        lessThanOrEqualTo(40));

    await tester.tap(find.byKey(const Key('auto-chat-toggle')));
    await tester.tap(find.byKey(const Key('work-mode-toggle')));
    expect(autoEnabled, isTrue);
    expect(workModeEnabled, isTrue);
  });

  testWidgets('direct chat hides the auto-chat button', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CompactConversationControls(
          showAutoChat: false,
          autoChatEnabled: true,
          workModeEnabled: false,
          autoChatAvailable: true,
          autoChatTooltip: '自动发言',
          workModeTooltip: '工作模式',
          onAutoChatChanged: (_) {},
          onWorkModeChanged: (_) {},
        ),
      ),
    ));

    expect(find.byKey(const Key('auto-chat-toggle')), findsNothing);
    expect(find.byKey(const Key('work-mode-toggle')), findsOneWidget);
  });

  testWidgets('例外态提示只在 statusAlert 非空时出现', (tester) async {
    Future<void> pump({ConversationStatusAlert? alert}) => tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: CompactConversationControls(
                showAutoChat: true,
                autoChatEnabled: true,
                workModeEnabled: false,
                autoChatAvailable: true,
                autoChatTooltip: '自动发言等待中',
                workModeTooltip: '工作模式',
                onAutoChatChanged: (_) {},
                onWorkModeChanged: (_) {},
                statusAlert: alert,
              ),
            ),
          ),
        );

    // 正常态：只有两个按钮，不占额外空间。
    await pump();
    expect(find.textContaining('已暂停'), findsNothing);
    expect(find.byType(IconButton), findsNWidgets(2));

    var tapped = 0;
    await pump(
      alert: ConversationStatusAlert(
        message: '角色未配置 API Key，AI 无法回复',
        actionLabel: '去设置',
        onAction: () => tapped++,
      ),
    );
    expect(find.text('角色未配置 API Key，AI 无法回复'), findsOneWidget);

    await tester.tap(find.text('去设置'));
    expect(tapped, 1);
  });

  testWidgets('私聊即使有自动发言状态也不显示自动发言提示', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CompactConversationControls(
            showAutoChat: false,
            autoChatEnabled: false,
            workModeEnabled: false,
            autoChatAvailable: false,
            autoChatTooltip: '自动发言',
            workModeTooltip: '工作模式',
            onAutoChatChanged: (_) {},
            onWorkModeChanged: (_) {},
            statusAlert: const ConversationStatusAlert(message: '自动发言异常'),
          ),
        ),
      ),
    );

    expect(find.text('自动发言异常'), findsNothing);
    expect(find.byKey(const Key('work-mode-toggle')), findsOneWidget);
  });
}

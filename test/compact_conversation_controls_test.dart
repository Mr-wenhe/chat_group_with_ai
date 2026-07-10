import 'package:chat_group/features/chat_group/widgets/compact_conversation_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('group chat renders exactly two compact toggle buttons',
      (tester) async {
    var autoEnabled = false;
    var autonomyEnabled = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CompactConversationControls(
          showAutoChat: true,
          autoChatEnabled: false,
          autonomousEnabled: false,
          autoChatAvailable: true,
          autoChatTooltip: '自动发言已关闭',
          autonomousTooltip: '自治执行已关闭',
          onAutoChatChanged: (value) => autoEnabled = value,
          onAutonomousChanged: (value) => autonomyEnabled = value,
        ),
      ),
    ));

    expect(find.byType(Switch), findsNothing);
    expect(find.byType(IconButton), findsNWidgets(2));
    expect(tester.getSize(find.byKey(const Key('auto-chat-toggle'))).width,
        lessThanOrEqualTo(40));
    expect(tester.getSize(find.byKey(const Key('autonomy-toggle'))).width,
        lessThanOrEqualTo(40));

    await tester.tap(find.byKey(const Key('auto-chat-toggle')));
    await tester.tap(find.byKey(const Key('autonomy-toggle')));
    expect(autoEnabled, isTrue);
    expect(autonomyEnabled, isTrue);
  });

  testWidgets('direct chat hides the auto-chat button', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CompactConversationControls(
          showAutoChat: false,
          autoChatEnabled: true,
          autonomousEnabled: false,
          autoChatAvailable: true,
          autoChatTooltip: '自动发言',
          autonomousTooltip: '自治执行',
          onAutoChatChanged: (_) {},
          onAutonomousChanged: (_) {},
        ),
      ),
    ));

    expect(find.byKey(const Key('auto-chat-toggle')), findsNothing);
    expect(find.byKey(const Key('autonomy-toggle')), findsOneWidget);
  });
}

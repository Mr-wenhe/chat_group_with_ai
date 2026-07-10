import 'package:chat_group/features/chat_group/widgets/message_selectable_text.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget app({VoidCallback? onSecondaryTap, VoidCallback? onLongPress}) {
    return MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 320,
          child: MessageSelectableText(
            content: 'hello world',
            style: const TextStyle(fontSize: 15),
            onSecondaryTap: onSecondaryTap,
            onLongPress: onLongPress,
          ),
        ),
      ),
    );
  }

  testWidgets('double click selects the entire message', (tester) async {
    await tester.pumpWidget(app());

    await tester.tap(find.byType(TextField));
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tap(find.byType(TextField));
    await tester.pump(const Duration(milliseconds: 40));

    final editable = tester.widget<EditableText>(find.byType(EditableText));
    expect(
      editable.controller.selection,
      const TextSelection(baseOffset: 0, extentOffset: 11),
    );
  });

  testWidgets('secondary mouse click opens message actions', (tester) async {
    var invoked = false;
    await tester.pumpWidget(app(onSecondaryTap: () => invoked = true));

    await tester.tap(
      find.byType(MessageSelectableText),
      buttons: kSecondaryMouseButton,
    );
    await tester.pump();

    expect(invoked, isTrue);
  });

  testWidgets('touch long press remains available', (tester) async {
    var invoked = false;
    await tester.pumpWidget(app(onLongPress: () => invoked = true));

    await tester.longPress(find.byType(MessageSelectableText));
    await tester.pump();

    expect(invoked, isTrue);
  });
}

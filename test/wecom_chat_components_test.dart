import 'package:chat_group/features/chat_group/widgets/wecom_chat_components.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('WeCom light tokens match the documented palette', () {
    expect(WeComChatTokens.lightChatBackground, const Color(0xFFEDEDED));
    expect(WeComChatTokens.lightSelfBubble, const Color(0xFF95EC69));
    expect(WeComChatTokens.lightPeerBubble, const Color(0xFFFFFFFF));
    expect(WeComChatTokens.lightText, const Color(0xFF181818));
    expect(WeComChatTokens.mention, const Color(0xFF576B95));
  });

  test('time divider appears for a new day or a five minute gap', () {
    final morning = DateTime(2026, 7, 11, 9);

    expect(shouldShowWeComTimeDivider(morning, null), isTrue);
    expect(
      shouldShowWeComTimeDivider(
        morning.add(const Duration(minutes: 4, seconds: 59)),
        morning,
      ),
      isFalse,
    );
    expect(
      shouldShowWeComTimeDivider(
        morning.add(const Duration(minutes: 5)),
        morning,
      ),
      isTrue,
    );
    expect(
      shouldShowWeComTimeDivider(DateTime(2026, 7, 12), morning),
      isTrue,
    );
  });

  test('mention spans preserve text and color known mentions', () {
    final spans = buildWeComMentionSpans(
      '请 @Alice 和 @小王 看一下',
      mentionNames: const ['Alice', '小王'],
      baseStyle: const TextStyle(color: Colors.black),
    );

    expect(
        spans.map((span) => span.toPlainText()).join(), '请 @Alice 和 @小王 看一下');
    final textSpans = spans.cast<TextSpan>();
    expect(
      textSpans.where((span) => span.text == '@Alice').single.style?.color,
      WeComChatTokens.mention,
    );
    expect(
      textSpans.where((span) => span.text == '@小王').single.style?.color,
      WeComChatTokens.mention,
    );
  });

  test('mention spans do not highlight matching email domains', () {
    final spans = buildWeComMentionSpans(
      '邮箱 alice@host，请 @host 查看',
      mentionNames: const ['host'],
      baseStyle: const TextStyle(color: Colors.black),
    ).cast<TextSpan>();

    expect(spans.map((span) => span.toPlainText()).join(),
        '邮箱 alice@host，请 @host 查看');
    expect(
      spans.where((span) =>
          span.text == '@host' && span.style?.color == WeComChatTokens.mention),
      hasLength(1),
    );
  });

  testWidgets('bubble surface uses green self and white peer bubbles',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              WeComBubbleSurface(
                key: Key('self'),
                isUser: true,
                child: Text('self'),
              ),
              WeComBubbleSurface(
                key: Key('peer'),
                isUser: false,
                child: Text('peer'),
              ),
            ],
          ),
        ),
      ),
    );

    final self = tester.widget<DecoratedBox>(
      find
          .descendant(
            of: find.byKey(const Key('self')),
            matching: find.byType(DecoratedBox),
          )
          .first,
    );
    final peer = tester.widget<DecoratedBox>(
      find
          .descendant(
            of: find.byKey(const Key('peer')),
            matching: find.byType(DecoratedBox),
          )
          .first,
    );

    expect((self.decoration as BoxDecoration).color,
        WeComChatTokens.lightSelfBubble);
    expect((peer.decoration as BoxDecoration).color,
        WeComChatTokens.lightPeerBubble);
    expect((self.decoration as BoxDecoration).border, isNull);
    expect((peer.decoration as BoxDecoration).border, isNull);
  });
}

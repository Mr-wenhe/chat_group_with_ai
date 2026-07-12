import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Visual tokens shared by the WeCom-like conversation surface.
///
/// The light palette intentionally follows the reference values in
/// `docs/wecom_workbuddy_prompt.md`. Dark colors are equivalent semantic
/// surfaces so the existing app-level dark mode remains readable.
abstract final class WeComChatTokens {
  static const lightChatBackground = Color(0xFFEDEDED);
  static const lightSelfBubble = Color(0xFF95EC69);
  static const lightPeerBubble = Color(0xFFFFFFFF);
  static const lightText = Color(0xFF181818);
  static const mention = Color(0xFF576B95);
  static const lightNickname = Color(0xFF888888);
  static const lightTimePill = Color(0xFFD8D8D8);
  static const lightInputSurface = Color(0xFFF7F7F7);
  static const lightInputField = Color(0xFFFFFFFF);
  static const lightDivider = Color(0xFFE5E5E5);

  static const darkChatBackground = Color(0xFF111315);
  static const darkSelfBubble = Color(0xFF3F7F39);
  static const darkPeerBubble = Color(0xFF25282B);
  static const darkText = Color(0xFFF2F2F2);
  static const darkNickname = Color(0xFFA6A6A6);
  static const darkTimePill = Color(0xFF4B4D50);
  static const darkInputSurface = Color(0xFF1B1D1F);
  static const darkInputField = Color(0xFF292B2E);
  static const darkDivider = Color(0xFF34373A);

  static bool _isDark(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark;

  static Color chatBackground(BuildContext context) =>
      _isDark(context) ? darkChatBackground : lightChatBackground;

  static Color bubble(BuildContext context, {required bool isUser}) {
    if (_isDark(context)) return isUser ? darkSelfBubble : darkPeerBubble;
    return isUser ? lightSelfBubble : lightPeerBubble;
  }

  static Color text(BuildContext context) =>
      _isDark(context) ? darkText : lightText;

  static Color nickname(BuildContext context) =>
      _isDark(context) ? darkNickname : lightNickname;

  static Color timePill(BuildContext context) =>
      _isDark(context) ? darkTimePill : lightTimePill;

  static Color inputSurface(BuildContext context) =>
      _isDark(context) ? darkInputSurface : lightInputSurface;

  static Color inputField(BuildContext context) =>
      _isDark(context) ? darkInputField : lightInputField;

  static Color divider(BuildContext context) =>
      _isDark(context) ? darkDivider : lightDivider;
}

bool shouldShowWeComTimeDivider(DateTime current, DateTime? previous) {
  if (previous == null) return true;
  if (current.year != previous.year ||
      current.month != previous.month ||
      current.day != previous.day) {
    return true;
  }
  return current.difference(previous) >= const Duration(minutes: 5);
}

List<InlineSpan> buildWeComMentionSpans(
  String text, {
  required Iterable<String> mentionNames,
  required TextStyle baseStyle,
}) {
  final names = mentionNames
      .map((name) => name.trim())
      .where((name) => name.isNotEmpty)
      .toSet()
      .toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  if (names.isEmpty || !text.contains('@')) {
    return [TextSpan(text: text, style: baseStyle)];
  }

  final pattern = RegExp('@(?:${names.map(RegExp.escape).join('|')})');
  final spans = <InlineSpan>[];
  var cursor = 0;
  for (final match in pattern.allMatches(text)) {
    if (match.start > 0 &&
        RegExp(r'[A-Za-z0-9._%+\-]').hasMatch(text[match.start - 1])) {
      continue;
    }
    if (match.start > cursor) {
      spans.add(TextSpan(
          text: text.substring(cursor, match.start), style: baseStyle));
    }
    spans.add(TextSpan(
      text: match.group(0),
      style: baseStyle.copyWith(
        color: WeComChatTokens.mention,
        fontWeight: FontWeight.w500,
      ),
    ));
    cursor = match.end;
  }
  if (cursor < text.length) {
    spans.add(TextSpan(text: text.substring(cursor), style: baseStyle));
  }
  return spans;
}

/// A borderless WeCom message surface with a compact four-pixel corner and
/// a small tail. Width is capped for readable long messages on large screens.
class WeComBubbleSurface extends StatelessWidget {
  const WeComBubbleSurface({
    super.key,
    required this.isUser,
    required this.child,
    this.isHighlighted = false,
    this.maxWidth,
  });

  final bool isUser;
  final Widget child;
  final bool isHighlighted;
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    final bubbleColor = isHighlighted
        ? Color.alphaBlend(
            Theme.of(context).colorScheme.primary.withOpacity(0.12),
            WeComChatTokens.bubble(context, isUser: isUser),
          )
        : WeComChatTokens.bubble(context, isUser: isUser);
    final available = MediaQuery.sizeOf(context).width;
    final readableWidth = maxWidth ?? math.min(640, available * 0.72);
    final radius = BorderRadius.circular(4);
    final shadow = isUser
        ? const <BoxShadow>[]
        : const [
            BoxShadow(
              color: Color(0x10000000),
              blurRadius: 1,
              offset: Offset(0, 1),
            ),
          ];

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: readableWidth),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: bubbleColor,
              borderRadius: radius,
              boxShadow: shadow,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: child,
            ),
          ),
          Positioned(
            top: 13,
            left: isUser ? null : -4,
            right: isUser ? -4 : null,
            child: Transform.rotate(
              angle: math.pi / 4,
              child: DecoratedBox(
                decoration: BoxDecoration(color: bubbleColor),
                child: const SizedBox.square(dimension: 8),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

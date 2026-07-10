import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// 聊天气泡里的可选择文本。
///
/// 使用只读 [SelectableText] 而非 [TextField]：避免 macOS 桌面端给聚焦的
/// [TextField] 绘制系统级聚焦光环（表现为一圈金色「虚框」）。[SelectableText]
/// 天然不画聚焦框，同时仍支持拖选 / 双击选词 / 右键复制菜单 / 触屏长按。
///
/// 右键 / 长按的「消息操作菜单」由外层 [_MessageBubble] 的 [GestureDetector]
/// 处理；本控件额外透传 [onSecondaryTap] / [onLongPress]，用 [Listener]（原始
/// 指针监听，不参与手势竞技场）承接，避免与 [SelectableText] 的选择手势冲突。
class MessageSelectableText extends StatefulWidget {
  const MessageSelectableText({
    super.key,
    required this.content,
    required this.style,
    this.onSecondaryTap,
    this.onLongPress,
  });

  final String content;
  final TextStyle style;
  final VoidCallback? onSecondaryTap;
  final VoidCallback? onLongPress;

  @override
  State<MessageSelectableText> createState() =>
      _MessageSelectableTextState();
}

class _MessageSelectableTextState extends State<MessageSelectableText> {
  Timer? _longPressTimer;

  @override
  void dispose() {
    _longPressTimer?.cancel();
    super.dispose();
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (event.buttons & kSecondaryMouseButton != 0) {
      widget.onSecondaryTap?.call();
      return;
    }
    if (event.buttons & kPrimaryMouseButton != 0) {
      // 仅触屏 / 手写笔走长按计时；鼠标左键交给 SelectableText 处理选区。
      if (event.kind != PointerDeviceKind.touch &&
          event.kind != PointerDeviceKind.stylus &&
          event.kind != PointerDeviceKind.invertedStylus) {
        return;
      }
      _longPressTimer?.cancel();
      _longPressTimer = Timer(kLongPressTimeout, widget.onLongPress ?? () {});
    }
  }

  void _cancelLongPress(PointerEvent _) => _longPressTimer?.cancel();

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _handlePointerDown,
      onPointerUp: _cancelLongPress,
      onPointerCancel: _cancelLongPress,
      child: SelectableText(
        widget.content,
        style: widget.style,
        contextMenuBuilder: (context, editableTextState) {
          return AdaptiveTextSelectionToolbar.buttonItems(
            anchors: editableTextState.contextMenuAnchors,
            buttonItems: editableTextState.contextMenuButtonItems,
          );
        },
      ),
    );
  }
}

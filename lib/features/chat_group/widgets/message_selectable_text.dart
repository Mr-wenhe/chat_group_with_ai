import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// 聊天气泡里的可选择文本。
///
/// 桌面端双击会选中整条消息，右键打开消息操作；触屏端继续支持长按。
/// 使用只读 [TextField] 是为了能可靠地以编程方式设置完整选区，同时保留
/// Flutter 原生的复制/全选工具栏，行为在 macOS 与 Windows 上一致。
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
  late final TextEditingController _controller =
      TextEditingController(text: widget.content);
  DateTime? _lastPrimaryTapAt;
  Timer? _longPressTimer;
  Timer? _selectAllTimer;

  @override
  void didUpdateWidget(covariant MessageSelectableText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.content == widget.content) return;
    final selection = _controller.selection;
    _controller.value = TextEditingValue(
      text: widget.content,
      selection: selection.isValid && selection.end <= widget.content.length
          ? selection
          : TextSelection.collapsed(offset: widget.content.length),
    );
  }

  @override
  void dispose() {
    _longPressTimer?.cancel();
    _selectAllTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _handlePrimaryTap() {
    final now = DateTime.now();
    final previous = _lastPrimaryTapAt;
    _lastPrimaryTapAt = now;
    if (previous == null ||
        now.difference(previous) > const Duration(milliseconds: 500)) {
      return;
    }
    _selectAllTimer?.cancel();
    _selectAllTimer = Timer(const Duration(milliseconds: 20), () {
      if (!mounted) return;
      _controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _controller.text.length,
      );
    });
    _lastPrimaryTapAt = null;
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (event.buttons & kSecondaryMouseButton != 0) {
      widget.onSecondaryTap?.call();
      return;
    }
    if (event.buttons & kPrimaryMouseButton != 0) {
      _handlePrimaryTap();
    }
    if (event.kind != PointerDeviceKind.touch &&
        event.kind != PointerDeviceKind.stylus &&
        event.kind != PointerDeviceKind.invertedStylus) {
      return;
    }
    _longPressTimer?.cancel();
    _longPressTimer = Timer(kLongPressTimeout, widget.onLongPress ?? () {});
  }

  void _cancelLongPress(PointerEvent _) {
    _longPressTimer?.cancel();
    _longPressTimer = null;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _handlePointerDown,
      onPointerUp: _cancelLongPress,
      onPointerCancel: _cancelLongPress,
      child: TextField(
        controller: _controller,
        readOnly: true,
        showCursor: false,
        maxLines: null,
        enableInteractiveSelection: true,
        style: widget.style,
        decoration: const InputDecoration.collapsed(hintText: ''),
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

import 'dart:async';

import 'package:chat_group/features/chat_group/message_action_item.dart';
import 'package:chat_group/features/chat_group/widgets/message_action_menu.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// 聊天气泡里的可选择文本。
///
/// 使用只读 [SelectableText] 而非 [TextField]：避免 macOS 桌面端给聚焦的
/// [TextField] 绘制系统级聚焦光环（表现为一圈金色「虚框」）。[SelectableText]
/// 天然不画聚焦框，同时仍支持拖选 / 双击选词 / 右键复制菜单 / 触屏长按。
///
/// 长按的「消息操作菜单」由外层 [_MessageBubble] 的 [GestureDetector] 处理；
/// 本控件额外透传 [onLongPress]，用 [Listener]（原始指针监听，不参与手势竞技场）
/// 承接，避免与 [SelectableText] 的选择手势冲突。
class MessageSelectableText extends StatefulWidget {
  const MessageSelectableText({
    super.key,
    required this.content,
    required this.style,
    this.spans,
    this.messageActions,
    this.onLongPress,
    this.onTap,
    this.enableSelection = true,
  });

  final String content;
  final TextStyle style;
  final List<InlineSpan>? spans;

  /// 点击正文。
  ///
  /// 必须由 [SelectableText] 自己给出：多选模式下 [enableSelection] 关掉的只是
  /// 选择手势，点击仍被它消费（实测确认），祖先的 [GestureDetector] 收不到。
  final VoidCallback? onTap;

  /// 为 false 时这段正文不再是可选文本，而是整块可点的区域（[onTap]）。
  ///
  /// 多选模式下用：那时点正文的意图是"勾选这一条"。这里刻意**不**用
  /// `enableInteractiveSelection: false` + `onTap` 的组合——SDK 的
  /// `_SelectableTextSelectionGestureDetectorBuilder.onSingleTapUp` 在
  /// `selectionEnabled == false` 时直接 return，`onTap` 永远不会触发；而那个
  /// 手势识别器仍然参与竞技场，祖先的 `GestureDetector` 也抢不到这次点击
  /// （2026-10-12 实测：两种写法都点不动）。
  final bool enableSelection;

  /// 鼠标右键 / 拖选文字后弹出的操作项。
  ///
  /// 延迟求值：菜单打开时才计算，否则列表里每条消息每次重建都要算一遍，
  /// 其中几项还要查搜索回合缓存。为 null 表示这条消息没有操作菜单，
  /// 右键退回平台原生的选择工具栏。
  final List<MessageActionItem> Function()? messageActions;

  /// 触屏长按回调（外层据此弹出底部操作弹窗）。
  final VoidCallback? onLongPress;

  @override
  State<MessageSelectableText> createState() => _MessageSelectableTextState();
}

class _MessageSelectableTextState extends State<MessageSelectableText> {
  Timer? _longPressTimer;

  /// 最近一次按下的指针类型。
  ///
  /// [SelectableText.contextMenuBuilder] 对「鼠标右键」和「触屏长按选词」是同
  /// 一次调用，分不出触发来源，只能靠指针类型分流：鼠标 / 手写笔换成消息操作
  /// 菜单；触屏保持平台原生的选择工具栏——移动端长按已经由外层弹出底部弹窗，
  /// 再叠一个原生工具栏就是两层菜单。
  PointerDeviceKind? _lastPointerKind;

  @override
  void dispose() {
    _longPressTimer?.cancel();
    super.dispose();
  }

  bool get _prefersMessageMenu =>
      widget.messageActions != null &&
      (_lastPointerKind == PointerDeviceKind.mouse ||
          _lastPointerKind == PointerDeviceKind.stylus ||
          _lastPointerKind == PointerDeviceKind.invertedStylus);

  void _handlePointerDown(PointerDownEvent event) {
    _lastPointerKind = event.kind;
    if (event.buttons & kSecondaryMouseButton != 0) {
      // 右键不在这里回调：菜单改由 contextMenuBuilder 在落点处渲染，
      // 此处再开一个就是两层菜单。
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
    final span = TextSpan(
      text: widget.spans == null ? widget.content : null,
      children: widget.spans,
      style: widget.style,
    );
    if (!widget.enableSelection) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Text.rich(span),
      );
    }
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _handlePointerDown,
      onPointerUp: _cancelLongPress,
      onPointerCancel: _cancelLongPress,
      child: SelectableText.rich(
        span,
        onTap: widget.onTap,
        contextMenuBuilder: (context, editableTextState) {
          if (_prefersMessageMenu) {
            return MessageActionContextMenu(
              anchor: editableTextState.contextMenuAnchors.primaryAnchor,
              items: widget.messageActions!(),
              onDismiss: editableTextState.hideToolbar,
            );
          }
          return AdaptiveTextSelectionToolbar.buttonItems(
            anchors: editableTextState.contextMenuAnchors,
            buttonItems: editableTextState.contextMenuButtonItems,
          );
        },
      ),
    );
  }
}

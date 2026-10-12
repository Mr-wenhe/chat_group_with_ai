import 'dart:math' as math;

import 'package:chat_group/features/chat_group/message_action_item.dart';
import 'package:chat_group/features/chat_group/widgets/sheet_button.dart';
import 'package:flutter/material.dart';

/// 菜单项的名义行高，用于给右键菜单算高度上限。
const double _menuRowHeight = 44;

/// 菜单上下各留出的最小余量，避免贴到屏幕边缘。
const double _menuViewportInset = 120;

/// 长按消息弹出的底部弹窗内容。
///
/// 只负责渲染与"点完先关自己"；清单由 [MessageActionItemBuilder] 提供，
/// 与右键菜单 [MessageActionContextMenu] 共用同一份，两边不会各长一套入口。
class MessageActionSheet extends StatelessWidget {
  const MessageActionSheet({
    super.key,
    required this.title,
    required this.items,
  });

  final String title;
  final List<MessageActionItem> items;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: cs.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Text(
            title,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 14),
          // 操作项从 6 项长到 8 项，矮屏上会顶出可视区，这里收个上限并允许滚动。
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var index = 0; index < items.length; index++) ...[
                    SheetButton(
                      context,
                      cs,
                      items[index].icon,
                      items[index].label,
                      () {
                        Navigator.pop(context);
                        items[index].onSelected();
                      },
                      destructive: items[index].destructive,
                    ),
                    if (index != items.length - 1) const SizedBox(height: 8),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 鼠标右键 / 拖选文字时的消息操作菜单。
///
/// 用 Material 的 [DesktopTextSelectionToolbar] 而不是平台自适应的
/// [AdaptiveTextSelectionToolbar]：后者在 macOS 上挑的是横排 Cupertino 版本，
/// 八个操作项会被压成一行；桌面版是竖向 card，形状与底部弹窗一致，并且自带
/// 锚点定位与屏幕边界避让——正是原生那个只有「Copy」的小框所在的位置。
class MessageActionContextMenu extends StatelessWidget {
  const MessageActionContextMenu({
    super.key,
    required this.anchor,
    required this.items,
    required this.onDismiss,
  });

  /// 菜单贴靠的坐标（右键落点或选区中点）。
  final Offset anchor;

  final List<MessageActionItem> items;

  /// 收起本浮层。菜单由 `contextMenuBuilder` 建在 Overlay 里、不是路由，
  /// `Navigator.pop` 对它无效，只能由持有 `EditableTextState` 的一方收掉。
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    final maxHeight = math.min(
      items.length * _menuRowHeight + 8,
      math.max(_menuRowHeight, MediaQuery.sizeOf(context).height - _menuViewportInset),
    );
    return DesktopTextSelectionToolbar(
      anchor: anchor,
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final item in items) _buildRow(cs, item),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRow(ColorScheme cs, MessageActionItem item) {
    final foreground = item.destructive ? cs.error : cs.onSurface;
    return InkWell(
      onTap: () {
        onDismiss();
        item.onSelected();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Icon(item.icon, size: 19, color: foreground),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                item.label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 14, color: foreground),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

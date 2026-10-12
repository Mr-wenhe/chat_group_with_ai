import 'package:flutter/material.dart';

/// 多选模式下每条消息左侧的勾选框。
///
/// 不可选的消息（工作模式进度气泡、正在流式输出的那条）**仍然渲染**这个占位，
/// 只是点不动：整行位移保持一致，气泡不会忽左忽右；而"看着能点、点下去没反应"
/// 比不显示更难理解，所以用更浅的描边明确表示它不可选。
class MessageSelectionCheckbox extends StatelessWidget {
  const MessageSelectionCheckbox({
    super.key,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final Color color;
    if (!enabled) {
      color = cs.onSurfaceVariant.withValues(alpha: 0.28);
    } else if (selected) {
      color = cs.primary;
    } else {
      color = cs.onSurfaceVariant;
    }
    return Semantics(
      checked: selected,
      enabled: enabled,
      child: InkResponse(
        onTap: enabled ? onTap : null,
        radius: 22,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Icon(
            selected
                ? Icons.check_circle_rounded
                : Icons.radio_button_unchecked_rounded,
            size: 22,
            color: color,
          ),
        ),
      ),
    );
  }
}

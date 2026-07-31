import 'package:flutter/material.dart';

/// 聊天页顶部的紧凑控制按钮。
///
/// 群聊显示“自动发言”和“工作模式”两个 36×36 按钮；私聊只显示工作模式。
/// 状态说明放在 Tooltip 中，避免两条全宽状态栏挤占消息空间。
class CompactConversationControls extends StatelessWidget {
  const CompactConversationControls({
    super.key,
    required this.showAutoChat,
    required this.autoChatEnabled,
    required this.workModeEnabled,
    required this.autoChatAvailable,
    required this.autoChatTooltip,
    required this.workModeTooltip,
    required this.onAutoChatChanged,
    required this.onWorkModeChanged,
  });

  final bool showAutoChat;
  final bool autoChatEnabled;
  final bool workModeEnabled;
  final bool autoChatAvailable;
  final String autoChatTooltip;
  final String workModeTooltip;
  final ValueChanged<bool> onAutoChatChanged;
  final ValueChanged<bool> onWorkModeChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
      child: Align(
        alignment: Alignment.centerRight,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest.withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.5)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(3),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (showAutoChat)
                  _toggle(
                    key: const Key('auto-chat-toggle'),
                    tooltip: autoChatTooltip,
                    enabled: autoChatEnabled,
                    available: autoChatAvailable,
                    icon: autoChatEnabled
                        ? Icons.forum_rounded
                        : Icons.forum_outlined,
                    onPressed: () => onAutoChatChanged(!autoChatEnabled),
                    cs: cs,
                  ),
                if (showAutoChat) const SizedBox(width: 2),
                _toggle(
                  key: const Key('work-mode-toggle'),
                  tooltip: workModeTooltip,
                  enabled: workModeEnabled,
                  available: true,
                  icon: workModeEnabled
                      ? Icons.work_rounded
                      : Icons.work_outline_rounded,
                  onPressed: () => onWorkModeChanged(!workModeEnabled),
                  cs: cs,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _toggle({
    required Key key,
    required String tooltip,
    required bool enabled,
    required bool available,
    required IconData icon,
    required VoidCallback onPressed,
    required ColorScheme cs,
  }) {
    return IconButton(
      key: key,
      tooltip: tooltip,
      onPressed: available ? onPressed : null,
      icon: Icon(icon, size: 18),
      color: enabled ? cs.primary : cs.onSurfaceVariant,
      style: IconButton.styleFrom(
        fixedSize: const Size(36, 36),
        minimumSize: const Size(36, 36),
        maximumSize: const Size(36, 36),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        backgroundColor: enabled ? cs.primaryContainer : Colors.transparent,
        disabledForegroundColor: cs.onSurface.withValues(alpha: 0.28),
      ),
    );
  }
}

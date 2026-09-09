import 'package:flutter/material.dart';

/// 聊天页顶部的紧凑控制按钮。
///
/// 群聊显示“自动发言”“语音播报”和“工作模式”三个 36×36 按钮；私聊只显示
/// 工作模式（语音播报属于群聊流式 TTS 播报）。状态说明放在 Tooltip 中，
/// 避免多条全宽状态栏挤占消息空间。
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
    this.showVoiceBroadcast = false,
    this.voiceBroadcastEnabled = false,
    this.voiceBroadcastAvailable = false,
    this.voiceBroadcastTooltip = '',
    this.onVoiceBroadcastChanged,
  });

  final bool showAutoChat;
  final bool autoChatEnabled;
  final bool workModeEnabled;
  final bool autoChatAvailable;
  final String autoChatTooltip;
  final String workModeTooltip;
  final ValueChanged<bool> onAutoChatChanged;
  final ValueChanged<bool> onWorkModeChanged;

  /// 是否显示“流式语音播报”开关（群聊且非 Web）。
  final bool showVoiceBroadcast;
  final bool voiceBroadcastEnabled;

  /// 语音服务是否已配置可用；为 false 时按钮置灰不可点。
  final bool voiceBroadcastAvailable;
  final String voiceBroadcastTooltip;
  final ValueChanged<bool>? onVoiceBroadcastChanged;

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
                if (showVoiceBroadcast) ...[
                  _toggle(
                    key: const Key('voice-broadcast-toggle'),
                    tooltip: voiceBroadcastTooltip,
                    enabled: voiceBroadcastEnabled,
                    available: voiceBroadcastAvailable,
                    icon: voiceBroadcastEnabled
                        ? Icons.record_voice_over_rounded
                        : Icons.record_voice_over_outlined,
                    onPressed: () =>
                        onVoiceBroadcastChanged?.call(!voiceBroadcastEnabled),
                    cs: cs,
                  ),
                  const SizedBox(width: 2),
                ],
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

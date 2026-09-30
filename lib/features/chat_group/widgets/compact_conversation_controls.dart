import 'package:flutter/material.dart';

/// 控制条下方**只在例外态**出现的提示。
///
/// 正常态（空闲/等待中/生成中）不显示：Tooltip 已承载完整状态，多一条常驻整行
/// 状态栏会挤占消息空间。这里只暴露需要用户知道或介入的情况。
class ConversationStatusAlert {
  final String message;

  /// 是否需要用户介入：true 用警示色，false 用中性色（如被工作模式暂停）。
  final bool isWarning;
  final String? actionLabel;
  final VoidCallback? onAction;

  const ConversationStatusAlert({
    required this.message,
    this.isWarning = true,
    this.actionLabel,
    this.onAction,
  });
}

/// 聊天页顶部的紧凑控制按钮。
///
/// 群聊显示“自动发言”“语音播报”“工作模式”和“圆桌会议模式”按钮；私聊只显示
/// 工作模式（语音播报和圆桌会议属于群聊特性）。正常态的状态说明放在 Tooltip 中，
/// 避免常驻状态栏挤占消息空间；只有 [statusAlert] 非空（例外态）时才多出一行。
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
    this.showWorkMode = true,
    required this.onWorkModeChanged,
    this.showRoundtableMode = false,
    this.roundtableModeEnabled = false,
    this.roundtableModeAvailable = true,
    this.roundtableModeTooltip = '',
    this.onRoundtableModeChanged,
    this.statusAlert,
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

  /// 是否显示“工作模式”开关。客人端为 false：工作模式会把输入送进会调用
  /// LLM 的任务链路，而客人端一律不调 LLM。
  final bool showWorkMode;

  final ValueChanged<bool> onWorkModeChanged;
  final bool showRoundtableMode;
  final bool roundtableModeEnabled;
  final bool roundtableModeAvailable;
  final String roundtableModeTooltip;
  final ValueChanged<bool>? onRoundtableModeChanged;

  /// 例外态提示；为 null 时完全不占空间。
  final ConversationStatusAlert? statusAlert;

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
    final alert = showAutoChat ? statusAlert : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (alert != null) ...[
            _alertBanner(context, alert),
            const SizedBox(height: 4),
          ],
          Align(
            alignment: Alignment.centerRight,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest.withValues(alpha: 0.72),
                borderRadius: BorderRadius.circular(10),
                border:
                    Border.all(color: cs.outlineVariant.withValues(alpha: 0.5)),
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
                        onPressed: () => onVoiceBroadcastChanged
                            ?.call(!voiceBroadcastEnabled),
                        cs: cs,
                      ),
                      const SizedBox(width: 2),
                    ],
                    if (showWorkMode)
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
                    if (showRoundtableMode) ...[
                      const SizedBox(width: 2),
                      _toggle(
                        key: const Key('roundtable-mode-toggle'),
                        tooltip: roundtableModeTooltip,
                        enabled: roundtableModeEnabled,
                        available: roundtableModeAvailable,
                        icon: roundtableModeEnabled
                            ? Icons.table_restaurant_rounded
                            : Icons.table_restaurant_outlined,
                        onPressed: () => onRoundtableModeChanged
                            ?.call(!roundtableModeEnabled),
                        cs: cs,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 例外态提示条。用警示色表示需要介入，中性色表示"被你自己暂停了"。
  Widget _alertBanner(BuildContext context, ConversationStatusAlert alert) {
    final cs = Theme.of(context).colorScheme;
    final accent = alert.isWarning ? cs.error : cs.onSurfaceVariant;
    return DecoratedBox(
      decoration: BoxDecoration(
        color:
            (alert.isWarning ? cs.errorContainer : cs.surfaceContainerHighest)
                .withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: accent.withValues(alpha: 0.35)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              alert.isWarning
                  ? Icons.error_outline_rounded
                  : Icons.info_outline_rounded,
              size: 14,
              color: accent,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                alert.message,
                style: TextStyle(
                  fontSize: 12,
                  color: alert.isWarning
                      ? cs.onErrorContainer
                      : cs.onSurfaceVariant,
                ),
              ),
            ),
            if (alert.actionLabel != null) ...[
              const SizedBox(width: 8),
              TextButton(
                onPressed: alert.onAction,
                child: Text(
                  alert.actionLabel!,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: accent,
                  ),
                ),
              ),
            ],
          ],
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

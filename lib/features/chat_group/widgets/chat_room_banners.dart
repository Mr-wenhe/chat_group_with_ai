import 'package:flutter/material.dart';

class SearchStatusBanner extends StatelessWidget {
  final String message;
  final bool busy;
  final VoidCallback? onTap;

  const SearchStatusBanner({
    super.key,
    required this.message,
    required this.busy,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
      child: Material(
        color: colors.tertiaryContainer.withValues(alpha: 0.48),
        borderRadius: BorderRadius.circular(10),
        child: ListTile(
          dense: true,
          minLeadingWidth: 20,
          leading: busy
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(Icons.public_rounded, size: 18, color: colors.tertiary),
          title: Text(message, maxLines: 2, overflow: TextOverflow.ellipsis),
          trailing: onTap == null
              ? null
              : const Icon(Icons.chevron_right_rounded, size: 18),
          onTap: onTap,
        ),
      ),
    );
  }
}

class ApiWarningBanner extends StatelessWidget {
  final String message;
  final VoidCallback onConfigure;

  const ApiWarningBanner({
    super.key,
    required this.message,
    required this.onConfigure,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: colorScheme.errorContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colorScheme.error.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, size: 20, color: colorScheme.error),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(fontSize: 13, color: colorScheme.onSurface),
            ),
          ),
          TextButton(
            onPressed: onConfigure,
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
            ),
            child: Text(
              '去配置',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: colorScheme.error,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 客人端的说明条：本群的 AI 回复不在本机生成。
///
/// 客人端按设计不持有、也不该持有该群角色的 API 凭据，所以这里绝不能复用
/// [ApiWarningBanner] 那套「未配置 API Key，去配置」的措辞——那会把客人引去
/// 做一件对他设备毫无意义的事（就算配了自己的 Key，AI 也仍由主人端生成）。
/// 这条只负责说清回复的来源，免得客人把「等了一会儿没人说话」误判成自己的
/// 网络或配置问题。
///
/// 样式刻意做成细条而非带边框的告警块：对客人而言这是长期成立的事实，
/// 不是需要处理的异常，常驻的告警块只会持续挤占消息空间。
class GuestAiNoticeBanner extends StatelessWidget {
  final String message;

  const GuestAiNoticeBanner({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 0),
      child: Row(
        children: [
          Icon(Icons.smart_toy_outlined, size: 13, color: colorScheme.outline),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              message,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: colorScheme.outline),
            ),
          ),
        ],
      ),
    );
  }
}

/// 多人实时群聊的连接状态条。
///
/// [notice] 非空表示有需要用户处理的问题（未配置 / 连不上 / 协议不一致），
/// 用醒目样式并给出「去设置」出口；否则退化成一条细状态条，只报告当前连没连上。
/// 连接正常时也保留细条：多人协作里"我这句别人到底收到没有"是刚需，
/// 不能只在出问题时才告诉用户。
class RealtimeStatusBanner extends StatelessWidget {
  /// 当前连接状态的中文描述，如「已连接（3 人在线）」。
  final String label;

  /// 需要用户关注的问题描述；为 null 表示连接正常。
  final String? notice;

  /// 是否为故障态（用于决定细条的颜色），正常连接时为 false。
  final bool offline;

  final VoidCallback onOpenSettings;

  const RealtimeStatusBanner({
    super.key,
    required this.label,
    required this.notice,
    required this.offline,
    required this.onOpenSettings,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final problem = notice;
    if (problem != null) {
      return Container(
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: colorScheme.errorContainer.withValues(alpha: 0.42),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: colorScheme.error.withValues(alpha: 0.32)),
        ),
        child: Row(
          children: [
            Icon(Icons.wifi_off_rounded, size: 18, color: colorScheme.error),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                problem,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: colorScheme.onSurface),
              ),
            ),
            TextButton(
              onPressed: onOpenSettings,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
              ),
              child: Text(
                '去设置',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: colorScheme.error,
                ),
              ),
            ),
          ],
        ),
      );
    }

    final accent =
        offline ? colorScheme.outline : const Color(0xFF07C160); // 微信绿
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 0),
      child: Row(
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: colorScheme.outline),
            ),
          ),
          GestureDetector(
            onTap: onOpenSettings,
            child: Text(
              '联机设置',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: colorScheme.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class AnnouncementBanner extends StatelessWidget {
  final String announcement;
  final VoidCallback onEdit;

  const AnnouncementBanner({
    super.key,
    required this.announcement,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colorScheme.secondaryContainer.withValues(alpha: 0.32),
        borderRadius: BorderRadius.circular(12),
        border:
            Border.all(color: colorScheme.secondary.withValues(alpha: 0.28)),
      ),
      child: Row(
        children: [
          Icon(Icons.campaign_rounded, size: 18, color: colorScheme.secondary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              announcement,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: colorScheme.onSurface),
            ),
          ),
          IconButton(
            onPressed: onEdit,
            icon: const Icon(Icons.edit_rounded, size: 16),
            tooltip: '编辑公告',
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
        ],
      ),
    );
  }
}

class UserMentionBanner extends StatelessWidget {
  final int count;
  final VoidCallback onTap;
  final VoidCallback onClear;

  const UserMentionBanner({
    super.key,
    required this.count,
    required this.onTap,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Material(
        color: colorScheme.primaryContainer.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: colorScheme.primary.withValues(alpha: 0.32)),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.alternate_email_rounded,
                  size: 18,
                  color: colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    count == 1 ? '有人 @ 你' : '$count 条 @ 你的消息',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
                Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: 20,
                  color: colorScheme.primary,
                ),
                IconButton(
                  onPressed: onClear,
                  icon: Icon(
                    Icons.close_rounded,
                    size: 16,
                    color: colorScheme.onPrimaryContainer,
                  ),
                  tooltip: '忽略提醒',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

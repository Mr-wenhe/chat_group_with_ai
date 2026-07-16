import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:chat_group/core/theme/app_theme.dart';
import 'package:chat_group/features/chat_group/group_chat_inbox.dart';
import 'package:chat_group/features/direct_chat/direct_chat_inbox.dart';
import 'package:chat_group/providers/providers.dart';
import 'package:chat_group/services/conversation_presence_service.dart';

/// 通用卡片装饰：细描边 + 柔和投影（暗色高级感）。
class AppCard extends StatelessWidget {
  final ColorScheme cs;
  final List<Widget> children;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;

  const AppCard({
    super.key,
    required this.cs,
    required this.children,
    this.padding = const EdgeInsets.all(16),
    this.margin,
  });

  /// 复用于任意 Container / Card 的统一样式。
  static BoxDecoration decoration(ColorScheme cs) {
    final isDark = cs.brightness == Brightness.dark;
    return BoxDecoration(
      color: cs.surfaceContainer,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(
        color: isDark
            ? Colors.white.withOpacity(0.06)
            : Colors.black.withOpacity(0.05),
      ),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withOpacity(isDark ? 0.28 : 0.06),
          blurRadius: isDark ? 18 : 14,
          offset: Offset(0, isDark ? 8 : 4),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin,
      padding: padding,
      decoration: decoration(cs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }
}

/// 分区标题：小号字 + 强调色分隔线。
class AppSectionHeader extends StatelessWidget {
  final String title;
  final IconData? icon;
  final ColorScheme cs;

  const AppSectionHeader(
      {super.key, required this.title, this.icon, required this.cs});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (icon != null) ...[
          Icon(icon, size: 16, color: cs.primary),
          const SizedBox(width: 8),
        ],
        Text(
          title,
          style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: cs.primary,
              letterSpacing: 0.8),
        ),
        const SizedBox(width: 12),
        Expanded(
            child:
                Divider(color: cs.primary.withOpacity(0.15), thickness: 0.5)),
      ],
    );
  }
}

/// 统一的输入框装饰。
InputDecoration appInputDecoration(
    String label, String? hint, IconData icon, ColorScheme cs) {
  final isDark = cs.brightness == Brightness.dark;
  return InputDecoration(
    labelText: label,
    hintText: hint,
    prefixIcon: Icon(icon, size: 18, color: cs.onSurfaceVariant),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: cs.outlineVariant),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: cs.outlineVariant),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: cs.primary, width: 1.5),
    ),
    filled: true,
    fillColor: isDark
        ? cs.surfaceContainerHighest.withOpacity(0.6)
        : cs.surfaceContainerLowest,
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    labelStyle: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
    hintStyle:
        TextStyle(fontSize: 13, color: cs.onSurfaceVariant.withOpacity(0.5)),
  );
}

/// 浮动胶囊底栏：角色 / 群聊 / 私聊 / 设置。
class AppBottomNav extends ConsumerWidget {
  final int currentIndex;
  final ColorScheme cs;

  const AppBottomNav({super.key, required this.currentIndex, required this.cs});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = cs.brightness == Brightness.dark;
    final db = ref.watch(databaseServiceProvider);
    final activeConversationId =
        ConversationPresenceService.instance.activeConversationId;
    final records = db.conversationSummaries();
    final directSummaries = DirectChatInbox.buildIndexedSummaries(
      characters: db.aiCharacterBox.values.toList(),
      records: records,
      messageById: db.messageBox.get,
      sourceByConversation: db.directChatSourceByConversation(),
      activeConversationId: activeConversationId,
    );
    final directUnread = DirectChatInbox.totalUnread(directSummaries);
    final groupSummaries = GroupChatInbox.buildIndexedSummaries(
      groups: db.chatGroupBox.values.toList(),
      records: records,
      messageById: db.messageBox.get,
      pinnedIds: db.pinnedGroupIds(),
      activeGroupId: activeConversationId,
    );
    final groupUnread = GroupChatInbox.totalUnread(groupSummaries);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      child: Container(
        decoration: BoxDecoration(
          color: isDark ? cs.surfaceContainerHighest : cs.surfaceContainer,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: isDark
                ? Colors.white.withOpacity(0.06)
                : Colors.black.withOpacity(0.05),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(isDark ? 0.35 : 0.1),
              blurRadius: 24,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: NavigationBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          height: 64,
          selectedIndex: currentIndex,
          indicatorColor: cs.primary.withOpacity(0.18),
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          onDestinationSelected: (i) {
            if (i == currentIndex) return;
            if (i == 0) {
              Navigator.of(context).pushReplacementNamed('/');
            } else if (i == 1) {
              Navigator.of(context).pushReplacementNamed('/groups');
            } else if (i == 2) {
              Navigator.of(context).pushReplacementNamed('/direct-chats');
            } else {
              Navigator.of(context).pushReplacementNamed('/settings');
            }
          },
          destinations: [
            const NavigationDestination(
              icon: Icon(Icons.smart_toy_outlined, size: 22),
              selectedIcon: Icon(Icons.smart_toy_rounded, size: 22),
              label: '角色',
            ),
            NavigationDestination(
              icon: _badgeIcon(Icons.group_outlined, groupUnread),
              selectedIcon: _badgeIcon(Icons.group_rounded, groupUnread),
              label: '群聊',
            ),
            NavigationDestination(
              icon: _badgeIcon(Icons.chat_bubble_outline_rounded, directUnread),
              selectedIcon: _badgeIcon(Icons.chat_bubble_rounded, directUnread),
              label: '私聊',
            ),
            const NavigationDestination(
              icon: Icon(Icons.settings_outlined, size: 22),
              selectedIcon: Icon(Icons.settings_rounded, size: 22),
              label: '设置',
            ),
          ],
        ),
      ),
    );
  }

  Widget _badgeIcon(IconData icon, int count) {
    final base = Icon(icon, size: 22);
    if (count <= 0) return base;
    return Badge(
      label: Text(count > 99 ? '99+' : '$count'),
      child: base,
    );
  }
}

/// 渐变悬浮按钮。
class AppFab extends StatelessWidget {
  final VoidCallback onPressed;
  final IconData icon;
  final String label;

  const AppFab(
      {super.key,
      required this.onPressed,
      required this.icon,
      required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: AppTheme.primaryGradient,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: AppTheme.dark.primary.withOpacity(0.4),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 22, color: Colors.white),
                const SizedBox(width: 8),
                Text(label,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                        fontSize: 15)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 渐变主按钮（提交 / 保存）。
class AppPrimaryButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final IconData icon;
  final String label;
  final double height;

  const AppPrimaryButton({
    super.key,
    required this.onPressed,
    required this.icon,
    required this.label,
    this.height = 52,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: height,
      child: Container(
        decoration: BoxDecoration(
          gradient: AppTheme.primaryGradient,
          borderRadius: BorderRadius.circular(14),
          boxShadow: onPressed == null
              ? []
              : [
                  BoxShadow(
                    color: AppTheme.dark.primary.withOpacity(0.35),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                  ),
                ],
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onPressed,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 20, color: Colors.white),
                const SizedBox(width: 8),
                Text(label,
                    style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Colors.white)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

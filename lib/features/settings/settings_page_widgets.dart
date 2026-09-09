part of 'settings_page.dart';

class _SectionHeader extends StatelessWidget {
  final String title;
  final ColorScheme cs;
  final Widget? action;
  const _SectionHeader({required this.title, required this.cs, this.action});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(title,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: cs.primary,
                letterSpacing: 0.3)),
        const SizedBox(width: 12),
        Expanded(child: Divider(color: cs.outlineVariant, thickness: 0.5)),
        if (action != null) ...[
          const SizedBox(width: 10),
          action!,
        ],
      ],
    );
  }
}

class _ApiConfigCard extends StatelessWidget {
  final ApiConfig config;
  final ColorScheme cs;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onTest;

  const _ApiConfigCard(
      {required this.config,
      required this.cs,
      required this.onEdit,
      required this.onDelete,
      required this.onTest});

  @override
  Widget build(BuildContext context) {
    final pColor = providerColor(config.provider);
    final label = providerLabel(config.provider);
    final maskedKey =
        config.hasCredential ? 'API Key 已保存 ••••••••' : '未设置 API Key';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: AppCard.decoration(cs),
      child: Row(
        children: [
          _buildAvatar(pColor),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(config.name,
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: cs.onSurface)),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: pColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(label,
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                              color: pColor)),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  '${config.modelName} · ${config.protocol.label}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 2),
                Text(maskedKey,
                    style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurfaceVariant,
                        fontFamily: 'monospace')),
              ],
            ),
          ),
          Wrap(
            spacing: 4,
            children: [
              _actionButton(
                icon: Icons.bolt_rounded,
                label: '测试',
                color: cs.primary,
                onPressed: onTest,
              ),
              _actionButton(
                icon: Icons.edit_outlined,
                label: '编辑',
                color: cs.onSurfaceVariant,
                onPressed: onEdit,
              ),
              _actionButton(
                icon: Icons.delete_outline_rounded,
                label: '删除',
                color: cs.error,
                onPressed: onDelete,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _actionButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onPressed,
  }) {
    return TextButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 16),
      label: Text(label),
      style: TextButton.styleFrom(
        foregroundColor: color,
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _buildAvatar(Color pColor) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: pColor.withValues(alpha: 0.14),
        border: Border.all(color: pColor.withValues(alpha: 0.3), width: 1.5),
      ),
      child: Center(
          child: Text(config.name.isNotEmpty ? config.name[0] : '?',
              style: TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w600, color: pColor))),
    );
  }
}

class _SettingTile extends StatelessWidget {
  final ColorScheme cs;
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;

  const _SettingTile({
    required this.cs,
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(icon, size: 22, color: iconColor),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: cs.onSurface)),
                  Text(subtitle,
                      style:
                          TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
                ],
              ),
            ),
            if (trailing != null)
              trailing!
            else if (onTap != null)
              Icon(Icons.chevron_right_rounded,
                  size: 20, color: cs.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

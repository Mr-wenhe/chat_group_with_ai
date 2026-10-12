import 'package:flutter/material.dart';

/// 一条凭据在「API KEY 设置」页上的状态：决定徽章文案与配色。
enum ApiKeyEntryState {
  /// 已具备可用前提。
  ready,

  /// 还没配，且不配就用不了该能力。
  missing,

  /// 不配也能用（有本地兜底），只是表现不同 —— 用中性色，避免误报成"缺东西"。
  optional,
}

/// 「API KEY 设置」页里的一条凭据入口。
///
/// 比通用的设置行多两样东西：一个状态徽章，和一行给新手的引导说明。
class ApiKeyEntryTile extends StatelessWidget {
  const ApiKeyEntryTile({
    super.key,
    required this.cs,
    required this.icon,
    required this.title,
    required this.status,
    required this.state,
    this.hint,
    this.onTap,
  });

  final ColorScheme cs;
  final IconData icon;
  final String title;

  /// 一行状态摘要，由 `api_key_settings_status.dart` 的纯函数产出。
  final String status;
  final ApiKeyEntryState state;

  /// 详细提示：这块是干什么的、不配会怎样、去哪里申请。可省略。
  final String? hint;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: _accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, size: 20, color: _accent),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(title,
                            style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w500,
                                color: cs.onSurface)),
                      ),
                      const SizedBox(width: 8),
                      _badge(),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(status,
                      style:
                          TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
                  if (hint != null && hint!.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(hint!,
                        style: TextStyle(
                            fontSize: 12,
                            height: 1.45,
                            color:
                                cs.onSurfaceVariant.withValues(alpha: 0.75))),
                  ],
                ],
              ),
            ),
            if (onTap != null) ...[
              const SizedBox(width: 8),
              Icon(Icons.chevron_right_rounded,
                  size: 20, color: cs.onSurfaceVariant),
            ],
          ],
        ),
      ),
    );
  }

  Color get _accent => switch (state) {
        ApiKeyEntryState.ready => cs.primary,
        ApiKeyEntryState.missing => cs.error,
        ApiKeyEntryState.optional => cs.onSurfaceVariant,
      };

  String get _badgeLabel => switch (state) {
        ApiKeyEntryState.ready => '已配置',
        ApiKeyEntryState.missing => '未配置',
        ApiKeyEntryState.optional => '可选',
      };

  Widget _badge() {
    final accent = _accent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(_badgeLabel,
          style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w600, color: accent)),
    );
  }
}

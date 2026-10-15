import 'package:flutter/material.dart';

import 'package:chat_group/core/widgets/app_widgets.dart';

/// 授权码的加密强度说明。
///
/// 导入页与导出页共用同一句话，是因为它讲的是**同一件事的两面**：口令内置 ⇒
/// 拿到 App 就能解开。只写「已加密」会让人以为拿到这串码也没用，事实正相反；
/// 而两页各写一句措辞不同的话，用户会以为两边的强度不一样。
const String apiBundleThreatModelNotice =
    '授权码经过加密，防的是「密钥明文外流」和「随手转发」，不是防拿到本应用的人。'
    '解密口令随应用一起分发，因此请像对待密钥本身一样对待这串码：'
    '不要发到公开渠道。';

/// 一条带图标的提示卡。
class ApiBundleNoticeCard extends StatelessWidget {
  const ApiBundleNoticeCard({
    super.key,
    required this.cs,
    required this.message,
    this.icon = Icons.info_outline_rounded,
    this.emphasized = false,
  });

  final ColorScheme cs;
  final String message;
  final IconData icon;

  /// 用于「这串码就是你的密钥」这类需要更重的视觉分量、而不是中性说明的场合。
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final accent = emphasized ? cs.error : cs.primary;
    return AppCard(
      cs: cs,
      margin: EdgeInsets.zero,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: accent),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: emphasized ? cs.error : cs.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

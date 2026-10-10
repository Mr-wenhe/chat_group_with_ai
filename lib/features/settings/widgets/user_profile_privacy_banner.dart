import 'package:flutter/material.dart';

/// 「我的资料」页顶部的隐私提示原文。常量跟横幅放一起：文案只此一处使用，
/// 拆去别的文件只会让「这句提示在哪儿改」多一次跳转。
const String kUserProfilePrivacyNotice = '这些资料可能随聊天上下文发送给你配置的第三方 LLM 服务。';

/// 隐私提示横幅。
///
/// 从 `user_profile_page.dart` 拆出：资料表单页在加入 IP 形象组后已逼近
/// 500 行红线，而这条横幅是纯展示组件，与表单状态无关。
class UserProfilePrivacyBanner extends StatelessWidget {
  final ColorScheme cs;
  const UserProfilePrivacyBanner({super.key, required this.cs});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: cs.tertiaryContainer.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: cs.tertiary.withValues(alpha: 0.25),
          width: 0.5,
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.shield_outlined, size: 18, color: cs.tertiary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              kUserProfilePrivacyNotice,
              style: TextStyle(
                fontSize: 13,
                color: cs.onTertiaryContainer,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

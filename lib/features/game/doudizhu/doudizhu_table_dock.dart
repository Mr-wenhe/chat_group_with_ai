part of 'doudizhu_table_view.dart';

/// 深绿毡布主题：让操作面板内的卡片、按钮、文字统一成浅字深绿的配色，
/// 与牌桌色系一致。保留原 ColorScheme 的 primary 系以免按钮失去辨识度。
ThemeData _darkFeltTheme(BuildContext context) {
  final base = Theme.of(context);
  const feltSurface = Color(0xff104830);
  const feltSurfaceLow = Color(0xff0d3c29);
  const feltSurfaceHigh = Color(0xff1a5b40);
  return base.copyWith(
    colorScheme: const ColorScheme.dark(
      primary: Color(0xffffd877),
      onPrimary: Color(0xff263222),
      secondary: Color(0xff9ccc9c),
      onSecondary: Color(0xff12261b),
      tertiary: Color(0xffffd877),
      onTertiary: Color(0xff263222),
      surface: feltSurface,
      onSurface: Color(0xfff2f7f2),
      // 容器类颜色必须显式给深绿系：ColorScheme.dark 的默认 container 是
      // 紫灰调，套在绿桌上会露出浅色块（状态横幅、倍数角标曾因此发白发黄）。
      primaryContainer: Color(0xff14563c),
      onPrimaryContainer: Color(0xffffe9b5),
      secondaryContainer: Color(0xff1c6247),
      onSecondaryContainer: Color(0xffd7f0dd),
      tertiaryContainer: Color(0xffffd877),
      onTertiaryContainer: Color(0xff263222),
      surfaceContainerLowest: Color(0xff0a3222),
      surfaceContainerLow: feltSurfaceLow,
      surfaceContainer: feltSurface,
      surfaceContainerHigh: feltSurfaceHigh,
      surfaceContainerHighest: Color(0xff21694b),
      onSurfaceVariant: Color(0xffc2d6c6),
      outline: Color(0x66ffffff),
      outlineVariant: Color(0x33ffffff),
      error: Color(0xffff9a8a),
    ),
    cardColor: feltSurfaceLow,
    dividerColor: const Color(0x33ffffff),
  );
}

/// 绿毡木框容器：把操作面板包成与牌桌一致的木质边框 + 深绿底，
/// 让状态/按钮/记牌器/动态/结算视觉上从属于同一块绿色游戏面板。
class _ActionDock extends StatelessWidget {
  const _ActionDock({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xffb5814b), Color(0xff6b4524), Color(0xffb5814b)],
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [
          BoxShadow(
              color: Color(0x55000000), blurRadius: 14, offset: Offset(0, 6)),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(2.5),
        child: Container(
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xff0e5339), Color(0xff093626)],
            ),
            borderRadius: BorderRadius.circular(14),
          ),
          clipBehavior: Clip.antiAlias,
          // 套深绿主题，让状态条/记牌器/按钮/文字统一融入绿桌，
          // 不再是浮在绿底上的浅色卡片。仅改配色，不改 key / 文案 / 组件类型。
          child: Theme(
            data: _darkFeltTheme(context),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

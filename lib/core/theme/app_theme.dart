import 'package:flutter/material.dart';

enum AppSkinMode { light, system, dark, golden }

/// 全局设计系统：暗色高级感（Linear / Arc 风格）。
///
/// 设计令牌（Design Tokens）：
/// - 分层深色表面：surface(应用底) → surfaceContainerLow → surfaceContainer(卡片) → surfaceContainerHighest(浮层)
/// - 主色 indigo-violet，主操作使用三色渐变
/// - 细描边 + 柔和投影营造质感，而非生硬阴影
class AppTheme {
  static const Color primarySeed = Color(0xFF6E7BFF);

  /// 主操作渐变（按钮、FAB、用户气泡）。
  static const Gradient primaryGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF8B5CF6), Color(0xFF6366F1), Color(0xFF3B82F6)],
  );

  static final ColorScheme dark = ColorScheme.fromSeed(
    seedColor: primarySeed,
    brightness: Brightness.dark,
  ).copyWith(
    surface: const Color(0xFF0A0C12),
    surfaceContainerLowest: const Color(0xFF06080D),
    surfaceContainerLow: const Color(0xFF0F121A),
    surfaceContainer: const Color(0xFF141A26),
    surfaceContainerHighest: const Color(0xFF1B2230),
    onSurface: const Color(0xFFECEEF4),
    onSurfaceVariant: const Color(0xFF97A0B2),
    outline: const Color(0xFF2A3140),
    outlineVariant: const Color(0xFF232A38),
    primary: const Color(0xFF7C8CFF),
    onPrimary: const Color(0xFFFFFFFF),
    primaryContainer: const Color(0xFF222A47),
    onPrimaryContainer: const Color(0xFFC9CEFF),
    secondary: const Color(0xFF9AA3FF),
    onSecondary: const Color(0xFF0A0C12),
    tertiary: const Color(0xFF8B5CF6),
    error: const Color(0xFFF87171),
    errorContainer: const Color(0xFF3A1D22),
    onError: const Color(0xFFFFFFFF),
    onErrorContainer: const Color(0xFFFCA5A5),
    shadow: const Color(0xFF000000),
  );

  static final ColorScheme light = ColorScheme.fromSeed(
    seedColor: primarySeed,
    brightness: Brightness.light,
  ).copyWith(
    surface: const Color(0xFFF7F8FB),
    surfaceContainerLowest: const Color(0xFFFFFFFF),
    surfaceContainerLow: const Color(0xFFEEF1F6),
    surfaceContainer: const Color(0xFFE7EBF2),
    surfaceContainerHighest: const Color(0xFFF0F2F7),
    onSurface: const Color(0xFF161A23),
    onSurfaceVariant: const Color(0xFF5B6472),
    outline: const Color(0xFFDDE2EA),
    outlineVariant: const Color(0xFFE2E7EF),
    primary: const Color(0xFF5B5BF0),
    onPrimary: const Color(0xFFFFFFFF),
    primaryContainer: const Color(0xFFE7E8FF),
    onPrimaryContainer: const Color(0xFF2727AE),
    secondary: const Color(0xFF6E7BFF),
    onSecondary: const Color(0xFFFFFFFF),
    tertiary: const Color(0xFF8B5CF6),
    error: const Color(0xFFDC2626),
    errorContainer: const Color(0xFFFEE2E2),
    onError: const Color(0xFFFFFFFF),
    onErrorContainer: const Color(0xFF7F1D1D),
    shadow: const Color(0xFF000000),
  );

  static final ColorScheme golden = ColorScheme.fromSeed(
    seedColor: const Color(0xFFD4A017),
    brightness: Brightness.dark,
  ).copyWith(
    surface: const Color(0xFF11100B),
    surfaceContainerLowest: const Color(0xFF090805),
    surfaceContainerLow: const Color(0xFF18150D),
    surfaceContainer: const Color(0xFF211C10),
    surfaceContainerHighest: const Color(0xFF2D2514),
    onSurface: const Color(0xFFFFF7E2),
    onSurfaceVariant: const Color(0xFFD8C79B),
    outline: const Color(0xFF5F4B21),
    outlineVariant: const Color(0xFF463817),
    primary: const Color(0xFFFFC857),
    onPrimary: const Color(0xFF231700),
    primaryContainer: const Color(0xFF4D3710),
    onPrimaryContainer: const Color(0xFFFFE3A0),
    secondary: const Color(0xFFE4B13A),
    onSecondary: const Color(0xFF241700),
    tertiary: const Color(0xFFFF8F5A),
    error: const Color(0xFFFF8A80),
    errorContainer: const Color(0xFF4A1E18),
    onError: const Color(0xFF2A0500),
    onErrorContainer: const Color(0xFFFFD4CD),
    shadow: const Color(0xFF000000),
  );

  static ThemeData _base(ColorScheme cs, Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: cs,
      scaffoldBackgroundColor: cs.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: cs.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w700,
          color: cs.onSurface,
          letterSpacing: -0.5,
        ),
      ),
      cardTheme: CardTheme(
        elevation: 0,
        color: cs.surfaceContainer,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(
            color: isDark
                ? Colors.white.withValues(alpha: 0.06)
                : Colors.black.withValues(alpha: 0.05),
          ),
        ),
      ),
      dividerTheme:
          DividerThemeData(color: cs.outlineVariant, thickness: 0.5, space: 1),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: cs.surfaceContainerHighest,
        contentTextStyle: TextStyle(color: cs.onSurface, fontSize: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        actionTextColor: cs.primary,
      ),
      dialogTheme: DialogTheme(
        backgroundColor: cs.surfaceContainerHighest,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(
            color: isDark
                ? Colors.white.withValues(alpha: 0.06)
                : Colors.black.withValues(alpha: 0.05),
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: cs.primary,
          foregroundColor: cs.onPrimary,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: cs.primary),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark
            ? cs.surfaceContainerHighest.withValues(alpha: 0.6)
            : cs.surfaceContainerLowest,
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
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        labelStyle: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
        hintStyle: TextStyle(
            fontSize: 13, color: cs.onSurfaceVariant.withValues(alpha: 0.5)),
      ),
      textTheme: TextTheme(
        titleLarge: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            color: cs.onSurface,
            letterSpacing: -0.5),
        titleMedium: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: cs.onSurface,
            letterSpacing: -0.3),
        bodyLarge: TextStyle(fontSize: 15, height: 1.5, color: cs.onSurface),
        bodyMedium: TextStyle(fontSize: 14, height: 1.45, color: cs.onSurface),
        labelLarge: TextStyle(
            fontSize: 15, fontWeight: FontWeight.w600, color: cs.onSurface),
      ),
    );
  }

  static final ThemeData darkTheme = _base(dark, Brightness.dark);
  static final ThemeData lightTheme = _base(light, Brightness.light);
  static final ThemeData goldenTheme = _base(golden, Brightness.dark);

  static ThemeMode materialThemeModeFor(AppSkinMode skin) {
    return switch (skin) {
      AppSkinMode.light => ThemeMode.light,
      AppSkinMode.system => ThemeMode.system,
      AppSkinMode.dark || AppSkinMode.golden => ThemeMode.dark,
    };
  }
}

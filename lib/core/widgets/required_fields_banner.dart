import 'package:flutter/material.dart';

/// 「还缺哪些必填项」的统一文案；无缺失返回 `null`。
///
/// 全 App 只留这一份措辞：角色表单/用户资料页的 IP 形象面板、以及表单顶栏的
/// 汇总提示条都从这里取。曾经各写一句（「请先填写：」与「必须填写：」），同一张
/// 角色表单上两句话同时可见，说的还是同样三项。
///
/// 返回 `null` 而不是空串，是为了让调用方用 `if (message != null)` 表达"没有
/// 缺失"，不必再各自判断一次列表长度。
String? requiredFieldsMessage(List<String> missingFields) =>
    missingFields.isEmpty ? null : '请先填写：${missingFields.join('、')}';

/// 顶栏下方的必填项汇总提示条。
///
/// 表单体是长 `ListView`，字段级红字（`validator` 返回的那句）会随字段滚出
/// 视口，用户点完「创建」可能整屏看不到任何反馈。这条提示挂在 `AppBar.bottom`
/// 上、位于滚动区之外，把「缺什么」一次说全；字段级红字仍保留，负责说「在哪
/// 一项」。
class RequiredFieldsBanner extends StatelessWidget {
  final List<String> missingFields;
  final ColorScheme cs;

  const RequiredFieldsBanner({
    super.key,
    required this.missingFields,
    required this.cs,
  });

  static const double _kFontSize = 13;
  static const double _kLineHeightFactor = 1.35;
  static const double _kVerticalPadding = 10;
  static const double _kBottomMargin = 4;
  static const double _kHorizontalMargin = 20;
  static const double _kHorizontalPadding = 12;
  static const double _kIconSize = 18;
  static const double _kIconGap = 8;

  /// 正文样式：量行数与真正渲染必须共用同一份。
  ///
  /// `inherit: false` 是必需的——`Text` 默认会把样式叠到 `DefaultTextStyle` 上
  /// （顶栏的 family / letterSpacing 会跟着进来），而 `TextPainter` 只量这里给的
  /// 这份，量出的行数就会比实际少一行，`PreferredSize` 的高度跟着不够。
  static TextStyle textStyle(ColorScheme cs) => TextStyle(
        inherit: false,
        fontSize: _kFontSize,
        height: _kLineHeightFactor,
        fontWeight: FontWeight.w600,
        color: cs.onErrorContainer,
      );

  /// 包成 `PreferredSize` 供 `AppBar.bottom` 直接使用。
  ///
  /// `PreferredSize` 的高度是固定值：偏小会裁掉正文（窄屏或放大字体时文案换成
  /// 两行），偏大会在顶栏下留一条空白。所以按当前宽度和字体缩放**量一遍真实行
  /// 数**再算高度，而不是假定一行。
  ///
  /// 宽度取自 `MediaQuery.sizeOf`，前提是"AppBar 横向铺满窗口"。本 App 的
  /// `MaterialApp.builder` 只套 Overlay 与两个 host、不加宽度约束，这条成立；
  /// 若将来在 builder 里限宽，这里的估算会偏大、行数少算，正文被静默裁掉——
  /// 届时必须改成按 `LayoutBuilder` 的实际约束量宽度。
  static PreferredSizeWidget appBarBottom({
    required BuildContext context,
    required List<String> missingFields,
    required ColorScheme cs,
  }) {
    final banner = RequiredFieldsBanner(missingFields: missingFields, cs: cs);
    final message = requiredFieldsMessage(missingFields);
    if (message == null) {
      return PreferredSize(preferredSize: Size.zero, child: banner);
    }

    final textScaler = MediaQuery.textScalerOf(context);
    final maxTextWidth = (MediaQuery.sizeOf(context).width -
            _kHorizontalMargin * 2 -
            _kHorizontalPadding * 2 -
            _kIconSize -
            _kIconGap)
        .clamp(0.0, double.infinity);
    final painter = TextPainter(
      text: TextSpan(text: message, style: textStyle(cs)),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
    )..layout(maxWidth: maxTextWidth);
    final lines = painter.computeLineMetrics().length;
    painter.dispose();

    return PreferredSize(
      preferredSize: Size.fromHeight(
          lines * textScaler.scale(_kFontSize) * _kLineHeightFactor +
              _kVerticalPadding * 2 +
              _kBottomMargin),
      child: banner,
    );
  }

  @override
  Widget build(BuildContext context) {
    final message = requiredFieldsMessage(missingFields);
    if (message == null) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(
          left: _kHorizontalMargin,
          right: _kHorizontalMargin,
          bottom: _kBottomMargin),
      padding: const EdgeInsets.symmetric(
          horizontal: _kHorizontalPadding, vertical: _kVerticalPadding),
      decoration: BoxDecoration(
        color: cs.errorContainer,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.error.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline_rounded,
              size: _kIconSize, color: cs.onErrorContainer),
          const SizedBox(width: _kIconGap),
          Expanded(child: Text(message, style: textStyle(cs))),
        ],
      ),
    );
  }
}

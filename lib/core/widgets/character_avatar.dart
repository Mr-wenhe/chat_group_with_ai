import 'package:flutter/material.dart';

/// 角色头像：有 IP 形象图时显示图片，否则回落 emoji/首字母文本。
///
/// 纯展示 widget，**不做任何 IO / 路径决策** —— [image] 由调用方解析好传入
/// （见 `ImageServiceSettingsAccess.characterAvatarImage`）。image 为 null
/// 时回落 [fallbackText]：头像是装饰性资产，缺失不应影响任何主流程。
///
/// 之所以收 [ImageProvider] 而不是文件路径：`testWidgets` 的 FakeAsync 区里
/// `FileImage` 的真实解码永不完成（本文件的首个测试版正是这样 hang 死的），
/// 收 provider 后测试可注入 `MemoryImage`，生产侧的 `existsSync` 判定也留在
/// 数据层，与「widget 只负责画」的边界一致。
class CharacterAvatar extends StatelessWidget {
  const CharacterAvatar({
    super.key,
    required this.fallbackText,
    required this.size,
    this.image,
    this.shape = BoxShape.circle,
    this.borderRadius,
    this.decoration,
    this.background,
    this.textStyle,
    this.child,
    this.overlay,
    this.onTap,
  });

  /// 无图时显示的文本（emoji / 首字母）。为空时显示 [child]。
  final String fallbackText;

  /// 边长（正方形直径）。半径制调用方自行 `radius * 2`。
  final double size;

  /// 已解析好的 IP 形象图；null → 回落 [fallbackText]。
  final ImageProvider? image;

  final BoxShape shape;

  /// [shape] 为 [BoxShape.rectangle] 时的圆角。
  final BorderRadius? borderRadius;

  /// 完整容器装饰（背景 + 描边）。优先于 [background] / [shape] 组合。
  final BoxDecoration? decoration;

  /// [decoration] 为空时的底色。
  final Color? background;

  final TextStyle? textStyle;

  /// [fallbackText] 为空时的兜底内容（如「全部 AI」的群组图标）。
  final Widget? child;

  /// 叠在头像之上的覆盖层（未激活蒙层等），铺满整个头像。
  final Widget? overlay;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    Widget avatar = Container(
      width: size,
      height: size,
      decoration: _decoration(),
      alignment: Alignment.center,
      // 有图时不再叠文本：DecorationImage 铺满并按 shape 裁切。
      child: image == null ? _fallback() : null,
    );
    if (overlay != null) {
      avatar = Stack(children: [avatar, Positioned.fill(child: overlay!)]);
    }
    if (onTap != null) avatar = GestureDetector(onTap: onTap, child: avatar);
    return avatar;
  }

  BoxDecoration _decoration() {
    final base = decoration ??
        BoxDecoration(
          shape: shape,
          borderRadius: shape == BoxShape.rectangle ? borderRadius : null,
          color: background,
        );
    final resolved = image;
    if (resolved == null) return base;
    return base.copyWith(
      image: DecorationImage(image: resolved, fit: BoxFit.cover),
    );
  }

  Widget _fallback() {
    if (fallbackText.isNotEmpty) return Text(fallbackText, style: textStyle);
    return child ?? const SizedBox.shrink();
  }
}

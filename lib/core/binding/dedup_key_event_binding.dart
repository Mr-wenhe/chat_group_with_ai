import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

/// 修复 macOS 在切换输入法 / 输入源（如 Cmd+Space）时，embedder 会把同一个物理键的
/// KeyDown 重复派发两次（中间没有 KeyUp），从而触发 `HardwareKeyboard` 的 debug
/// assert（`A KeyDownEvent is dispatched, but the state shows that the physical
/// key is already pressed`）导致 debug 构建直接崩溃的问题。
///
/// 该 assert 仅存在于 debug 构建（release/profile 下不校验），但会严重影响本地调试。
/// 这里在事件进入框架前做一层去重：维护「当前按下的物理键集合」，遇到重复 down 直接吞掉，
/// 仅放行合法的 down / up / repeat，使 `HardwareKeyboard._pressedKeys` 的状态始终保持一致。
class DedupKeyEventBinding extends WidgetsFlutterBinding {
  /// 与 `WidgetsFlutterBinding.ensureInitialized()` 等价的自定义绑定入口。
  /// 基类静态方法会硬编码创建默认实例，故此处覆盖以实例化本子类。
  static DedupKeyEventBinding ensureInitialized() {
    _instance ??= DedupKeyEventBinding();
    return _instance!;
  }

  static DedupKeyEventBinding? _instance;

  @override
  void initInstances() {
    super.initInstances();
    final ui.KeyDataCallback? original = platformDispatcher.onKeyData;
    if (original == null) return;
    platformDispatcher.onKeyData = (ui.KeyData keyData) {
      switch (keyData.type) {
        case ui.KeyEventType.down:
          // 同一物理键已处于按下状态 => 这是 embedder 重复派发的 down，丢弃。
          if (_pressedPhysicalKeys.contains(keyData.physical)) {
            return true;
          }
          _pressedPhysicalKeys.add(keyData.physical);
        case ui.KeyEventType.up:
          _pressedPhysicalKeys.remove(keyData.physical);
        case ui.KeyEventType.repeat:
          // repeat 发生在按键按住期间，不改变按下集合，直接转发。
          break;
      }
      return original(keyData);
    };
  }

  /// 由本 binding 维护的「当前按下的物理键」集合，用于在 down 阶段去重。
  final Set<int> _pressedPhysicalKeys = <int>{};
}

import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:hive/hive.dart';

/// 胶囊与窗口边缘之间留出的空隙。
const double _workTaskPillMargin = 8.0;

/// 把胶囊放进窗口内：整块留在可视区，四周留出 [margin]。
///
/// 窗口比胶囊还小时没有"放得下"的位置，退回左上角边距——至少保证左上角可见、
/// 还抓得回来，而不是把胶囊整个丢到屏幕外再也点不到。
Offset clampWorkTaskPillPosition({
  required Offset position,
  required Size pillSize,
  required Size viewport,
  double margin = _workTaskPillMargin,
}) {
  final maxX = math.max(margin, viewport.width - pillSize.width - margin);
  final maxY = math.max(margin, viewport.height - pillSize.height - margin);
  return Offset(
    position.dx.clamp(margin, maxX).toDouble(),
    position.dy.clamp(margin, maxY).toDouble(),
  );
}

/// 用户把折叠胶囊拖到哪儿，它下次就还在哪儿。
///
/// 存的是左上角的窗口逻辑坐标，不是相对默认锚点的偏移：控件行让位只在会话页
/// 存在，按偏移存的话同一个位置在会话页与角色列表页之间会差 50px，拖过一次的
/// 人会看到胶囊自己在页面之间跳。
class WorkTaskPillPosition {
  WorkTaskPillPosition._();

  static const String storageKey = 'work_mode_task_pill_position_v1';

  /// 读回拖过的位置；没拖过或值损坏时返回 null，调用方退回默认锚点。
  static Offset? read(Box<dynamic> settingsBox) {
    final raw = settingsBox.get(storageKey);
    if (raw is! String) return null;
    final parts = raw.split(',');
    if (parts.length != 2) return null;
    final dx = double.tryParse(parts[0]);
    final dy = double.tryParse(parts[1]);
    if (dx == null || dy == null) return null;
    if (!dx.isFinite || !dy.isFinite) return null;
    return Offset(dx, dy);
  }

  static Future<void> write(Box<dynamic> settingsBox, Offset position) =>
      settingsBox.put(storageKey, '${position.dx},${position.dy}');
}

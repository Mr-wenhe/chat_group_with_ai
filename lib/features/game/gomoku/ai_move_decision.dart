/// 五子棋一次落子决策的结果（模型玩家与本地引擎玩家共用）。
///
/// 单独成文件，避免观战调度器与引擎玩家为了一个值对象去依赖
/// [AiGomokuPlayer] 所在的模型调用实现。
library;

import 'gomoku_board.dart';

class AiMoveDecision {
  /// 解析出的坐标；无法决策时为 null。
  final GomokuPosition? position;

  /// 决策说明（模型原始输出 / 引擎战术理由），供观战展示。
  final String reasoning;

  /// 失败原因；成功时为 null。
  final String? error;

  /// 本次决策耗时（毫秒）。
  final int elapsedMs;

  const AiMoveDecision._({
    this.position,
    required this.reasoning,
    this.error,
    this.elapsedMs = 0,
  });

  factory AiMoveDecision.success(
    GomokuPosition position,
    String reasoning, {
    int elapsedMs = 0,
  }) =>
      AiMoveDecision._(
        position: position,
        reasoning: reasoning,
        elapsedMs: elapsedMs,
      );

  factory AiMoveDecision.failure(
    String error, {
    String reasoning = '',
    int elapsedMs = 0,
  }) =>
      AiMoveDecision._(
        error: error,
        reasoning: reasoning,
        elapsedMs: elapsedMs,
      );

  bool get isSuccess => position != null;
}

/// AI 角色玩家：模型优先，内置棋力辅助静默接手。
///
/// 用户要的是「和 App 里的 AI 角色玩」，不是和一个独立引擎玩——所以
/// 台前玩家始终是角色本身：有绑定模型就由模型自己想棋、自己出坐标；
/// 模型一旦失败（空内容/超时/限流/未绑定），由内置棋力辅助算出一步，
/// 观战区仍以角色名展示，不出现「系统代落」这类打断沉浸的字样。
library;

import 'package:dio/dio.dart' show CancelToken;

import 'ai_move_decision.dart';
import 'gomoku_board.dart';
import 'gomoku_player.dart';

class CharacterGomokuPlayer implements GomokuPlayer {
  /// 首选决策者：角色绑定的模型玩家。
  final GomokuPlayer primary;

  /// 备用决策者：本地棋力辅助（毫秒级、不会超时）。
  final GomokuPlayer fallback;

  const CharacterGomokuPlayer({
    required this.primary,
    required this.fallback,
  });

  @override
  Future<AiMoveDecision> decideMove({
    required GomokuBoard board,
    required GomokuStone myStone,
    CancelToken? cancelToken,
    void Function(String delta)? onThinking,
  }) async {
    final stopwatch = Stopwatch()..start();

    final decision = await primary.decideMove(
      board: board,
      myStone: myStone,
      cancelToken: cancelToken,
      onThinking: onThinking,
    );
    // 模型成功：原样展示它的输出（用户要求不清洗）。
    if (decision.isSuccess) return decision;
    // 用户主动取消：不再替他落子。
    if (cancelToken?.isCancelled == true) return decision;

    // 模型失败：辅助静默接手。不回吐 onThinking，避免把失败说明混进理由；
    // 也不标「代落」——观战区只看到角色名 + 这步的战术说明。
    final backup = await fallback.decideMove(
      board: board,
      myStone: myStone,
      cancelToken: cancelToken,
    );
    if (!backup.isSuccess) return backup;

    return AiMoveDecision.success(
      backup.position!,
      backup.reasoning,
      elapsedMs: stopwatch.elapsedMilliseconds,
    );
  }
}

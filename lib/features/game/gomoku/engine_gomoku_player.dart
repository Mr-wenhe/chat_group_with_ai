/// 本地引擎五子棋玩家：不调用模型、不读凭据、不发网络请求。
///
/// App 的角色头像与人设照常作为席位展示，但落子由 [GomokuEngine] 计算。
/// 这样彻底消灭「模型返回空内容 / 连接超时 / 系统代落」——它们都来自
/// 模型调用链路，引擎决策是毫秒级纯计算，不存在超时与解析失败。
library;

import 'package:dio/dio.dart' show CancelToken;

import 'ai_move_decision.dart';
import 'gomoku_board.dart';
import 'gomoku_engine.dart';
import 'gomoku_player.dart';

class EngineGomokuPlayer implements GomokuPlayer {
  final GomokuEngine _engine;

  const EngineGomokuPlayer({GomokuEngine? engine})
      : _engine = engine ?? const GomokuEngine();

  @override
  Future<AiMoveDecision> decideMove({
    required GomokuBoard board,
    required GomokuStone myStone,
    CancelToken? cancelToken,
    void Function(String delta)? onThinking,
  }) async {
    final stopwatch = Stopwatch()..start();
    int elapsed() => stopwatch.elapsedMilliseconds;

    // 引擎是同步纯计算；取消令牌在这里没有可中断的等待，保留仅为接口一致。
    if (cancelToken?.isCancelled == true) {
      return AiMoveDecision.failure('落子已取消', elapsedMs: elapsed());
    }
    if (board.isGameOver) {
      return AiMoveDecision.failure('对局已结束', elapsedMs: elapsed());
    }

    final move = _engine.bestMove(board, myStone);
    if (move == null) {
      return AiMoveDecision.failure('棋盘上没有可落位置', elapsedMs: elapsed());
    }

    // 观战区要展示决策依据；引擎不伪造逐字「思考流」，只给一条完整理由。
    onThinking?.call(move.reason);
    return AiMoveDecision.success(
      move.position,
      move.reason,
      elapsedMs: elapsed(),
    );
  }
}

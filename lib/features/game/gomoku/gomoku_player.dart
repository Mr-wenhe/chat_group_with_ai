/// 五子棋席位的统一决策接口。
///
/// 模型玩家（[AiGomokuPlayer]）与本地引擎玩家（EngineGomokuPlayer）都实现
/// 它，调度器只认这个接口——把五子棋从模型驱动切换到引擎驱动时，
/// 对局流程与观战 UI 一行都不用改。
library;

import 'package:dio/dio.dart' show CancelToken;

import 'ai_move_decision.dart';
import 'gomoku_board.dart';

abstract class GomokuPlayer {
  /// 根据当前棋盘为 [myStone] 选一个落点。
  ///
  /// [onThinking] 仅用于向观战区回吐进度；引擎玩家没有逐字思考，
  /// 调用一次给出战术理由即可。
  Future<AiMoveDecision> decideMove({
    required GomokuBoard board,
    required GomokuStone myStone,
    CancelToken? cancelToken,
    void Function(String delta)? onThinking,
  });
}

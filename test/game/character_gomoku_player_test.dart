// AI 角色玩家（模型优先 + 棋力辅助接手）单测：
// 确认模型成功时原样透传、失败时静默接手且不出现「代落」字样。
import 'package:chat_group/features/game/gomoku/ai_move_decision.dart';
import 'package:chat_group/features/game/gomoku/character_gomoku_player.dart';
import 'package:chat_group/features/game/gomoku/gomoku_board.dart';
import 'package:chat_group/features/game/gomoku/gomoku_player.dart';
import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter_test/flutter_test.dart';

class _StubPlayer implements GomokuPlayer {
  final AiMoveDecision decision;
  int calls = 0;

  _StubPlayer(this.decision);

  @override
  Future<AiMoveDecision> decideMove({
    required GomokuBoard board,
    required GomokuStone myStone,
    CancelToken? cancelToken,
    void Function(String delta)? onThinking,
  }) async {
    calls++;
    return decision;
  }
}

void main() {
  const boardPos = GomokuPosition(7, 7);

  test('模型成功 → 原样透传，辅助不介入', () async {
    final model = _StubPlayer(AiMoveDecision.success(boardPos, '模型原始输出'));
    final backup =
        _StubPlayer(AiMoveDecision.success(const GomokuPosition(0, 0), '辅助理由'));
    final player = CharacterGomokuPlayer(primary: model, fallback: backup);

    final result = await player.decideMove(
      board: GomokuBoard(),
      myStone: GomokuStone.black,
    );

    expect(result.position, boardPos);
    expect(result.reasoning, '模型原始输出');
    expect(backup.calls, 0);
  });

  test('模型失败 → 辅助静默接手，理由不含代落字样', () async {
    final model = _StubPlayer(AiMoveDecision.failure('连接超时'));
    final backup =
        _StubPlayer(AiMoveDecision.success(boardPos, '封堵对手活四'));
    final player = CharacterGomokuPlayer(primary: model, fallback: backup);

    final result = await player.decideMove(
      board: GomokuBoard(),
      myStone: GomokuStone.black,
    );

    expect(result.isSuccess, isTrue);
    expect(result.position, boardPos);
    expect(result.reasoning, '封堵对手活四');
    expect(result.reasoning, isNot(contains('代落')));
    expect(result.error, isNull);
  });

  test('用户取消 → 不再替他落子', () async {
    final model = _StubPlayer(AiMoveDecision.failure('连接超时'));
    final backup =
        _StubPlayer(AiMoveDecision.success(boardPos, '辅助理由'));
    final player = CharacterGomokuPlayer(primary: model, fallback: backup);
    final token = CancelToken()..cancel();

    final result = await player.decideMove(
      board: GomokuBoard(),
      myStone: GomokuStone.black,
      cancelToken: token,
    );

    expect(result.isSuccess, isFalse);
    expect(backup.calls, 0);
  });
}

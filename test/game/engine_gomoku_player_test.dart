// 引擎玩家与调度器集成测试：确认五子棋链路不再产生「代落」。
import 'package:chat_group/features/game/gomoku/engine_gomoku_player.dart';
import 'package:chat_group/features/game/gomoku/game_director.dart';
import 'package:chat_group/features/game/gomoku/gomoku_board.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('引擎玩家本地落子，返回战术理由而非模型文本', () async {
    final board = GomokuBoard();
    for (final col in [7, 8, 9, 10]) {
      board.place(7, col, GomokuStone.white);
    }
    final decision = await const EngineGomokuPlayer().decideMove(
      board: board,
      myStone: GomokuStone.black,
    );
    expect(decision.isSuccess, isTrue);
    expect(decision.reasoning, '堵对手成五');
    expect(decision.error, isNull);
  });

  test('请求已取消时明确失败，不会兜底落子', () async {
    final token = CancelToken();
    token.cancel();
    final decision = await const EngineGomokuPlayer().decideMove(
      board: GomokuBoard(),
      myStone: GomokuStone.black,
      cancelToken: token,
    );
    expect(decision.isSuccess, isFalse);
    expect(decision.error, contains('取消'));
  });

  test('两个引擎席位能自动下完一局，且不出现系统代落', () async {
    final director = GameDirector(
      moveSpacing: Duration.zero,
      seats: [
        GomokuSeat(
          name: '甲',
          avatar: '甲',
          stone: GomokuStone.black,
          ai: const EngineGomokuPlayer(),
        ),
        GomokuSeat(
          name: '乙',
          avatar: '乙',
          stone: GomokuStone.white,
          ai: const EngineGomokuPlayer(),
        ),
      ],
    );
    addTearDown(director.dispose);
    director.start();

    // 引擎决策是异步 Future；逐 tick 推进直到终局。
    for (var i = 0; i < 1000 && director.phase == GomokuPhase.playing; i++) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(director.phase, GomokuPhase.finished,
        reason: 'status=${director.statusMessage}');
    expect(director.events, isNotEmpty);
    for (final event in director.events) {
      expect(event.reasoning, isNot(contains('代落')));
    }
    expect(director.statusMessage, isNot(contains('代落')));
  });
}

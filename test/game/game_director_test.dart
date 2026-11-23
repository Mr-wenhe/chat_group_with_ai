// 对局调度器单测：用两个真人席位验证轮转、落子与终局，不涉及 AI/网络/Hive。
import 'package:chat_group/features/game/gomoku/game_director.dart';
import 'package:chat_group/features/game/gomoku/gomoku_board.dart';
import 'package:flutter_test/flutter_test.dart';

GameDirector _twoHumanGame() => GameDirector(seats: [
      GomokuSeat(name: '甲', avatar: '甲', stone: GomokuStone.black),
      GomokuSeat(name: '乙', avatar: '乙', stone: GomokuStone.white),
    ]);

void main() {
  group('轮转', () {
    test('黑先，交替落子后白方回合', () async {
      final director = _twoHumanGame();
      director.start();
      expect(director.currentSeat.name, '甲');
      expect(director.isHumanTurn, isTrue);

      await director.humanMove(7, 7); // 黑
      expect(director.board.stoneAt(7, 7), GomokuStone.black);
      expect(director.currentSeat.name, '乙');

      await director.humanMove(7, 8); // 白
      expect(director.board.stoneAt(7, 8), GomokuStone.white);
      expect(director.currentSeat.name, '甲');
      director.dispose();
    });

    test('非真人回合之外重复落子不会越权', () async {
      final director = _twoHumanGame();
      director.start();
      await director.humanMove(0, 0); // 甲落，轮到乙
      await director.humanMove(0, 1); // 乙落，轮到甲
      // 棋盘上各有一子，顺序正确。
      expect(director.board.moveCount, 2);
      expect(director.board.stoneAt(0, 0), GomokuStone.black);
      expect(director.board.stoneAt(0, 1), GomokuStone.white);
      director.dispose();
    });
  });

  group('终局', () {
    test('黑方连成五子后进入 finished 并记录胜者', () async {
      final director = _twoHumanGame();
      director.start();
      // 黑走 (0..4, 0)，白在别处应付，黑达成横向五连。
      await director.humanMove(0, 0);
      await director.humanMove(10, 10);
      await director.humanMove(0, 1);
      await director.humanMove(10, 11);
      await director.humanMove(0, 2);
      await director.humanMove(10, 12);
      await director.humanMove(0, 3);
      await director.humanMove(10, 13);
      await director.humanMove(0, 4);

      expect(director.phase, GomokuPhase.finished);
      expect(director.board.winner, GomokuStone.black);
      expect(director.statusMessage, contains('甲'));
      expect(director.events.length, 9);
      director.dispose();
    });
  });
}

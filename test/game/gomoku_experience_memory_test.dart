/// 棋局记忆的主体隔离：正文点名了对手，主体就必须带上对手。
///
/// 回归的是这样一条代码路径：`recordFinishedMatch` 曾把 `subjectIds` 固定成
/// `[自己, 'user']`，于是「AI A 与 AI B 对弈」的经历能被 A 在**不含 B** 的私聊
/// 或另一场棋局里读出来——记忆过滤（`forGame` 与 MemoryContextSelector）只按
/// `subjectIds` 判定可见性，参与者列表不参与。
library;
import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/permanent_memory.dart';
import 'package:chat_group/features/game/gomoku/ai_move_decision.dart';
import 'package:chat_group/features/game/gomoku/game_director.dart';
import 'package:chat_group/features/game/gomoku/gomoku_board.dart';
import 'package:chat_group/features/game/gomoku/gomoku_experience_memory.dart';
import 'package:chat_group/features/game/gomoku/gomoku_player.dart';
import 'package:chat_group/features/memory/memory_controls.dart';
import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter_test/flutter_test.dart';

import '../helpers/lifecycle_hive.dart';

/// 按脚本落子的 stub 玩家：只负责把对局推进到终局，不涉及模型或网络。
class _ScriptedPlayer implements GomokuPlayer {
  _ScriptedPlayer(this._moves);

  final List<GomokuPosition> _moves;
  int _index = 0;

  @override
  Future<AiMoveDecision> decideMove({
    required GomokuBoard board,
    required GomokuStone myStone,
    CancelToken? cancelToken,
    void Function(String delta)? onThinking,
  }) async {
    if (_index < _moves.length) {
      return AiMoveDecision.success(_moves[_index++], '脚本落子');
    }
    // 脚本用完时随便找一个空位，保证对局不会卡在某一手。
    for (var row = 0; row < GomokuBoard.size; row++) {
      for (var col = 0; col < GomokuBoard.size; col++) {
        if (board.stoneAt(row, col) == null) {
          return AiMoveDecision.success(GomokuPosition(row, col), '兜底落子');
        }
      }
    }
    return AiMoveDecision.failure('棋盘已满');
  }
}

/// 黑方横向五连。白方的落子与胜负无关，只为让轮转继续。
const List<GomokuPosition> _blackWin = [
  GomokuPosition(0, 0),
  GomokuPosition(0, 1),
  GomokuPosition(0, 2),
  GomokuPosition(0, 3),
  GomokuPosition(0, 4),
];
const List<GomokuPosition> _whiteFiller = [
  GomokuPosition(10, 10),
  GomokuPosition(10, 11),
  GomokuPosition(10, 12),
  GomokuPosition(10, 13),
];

/// 让出事件循环直到「轮到真人」或对局结束：AI 落子是异步驱动的，紧接着
/// `humanMove` 会撞上非真人回合被静默忽略。
Future<void> _settle(GameDirector director) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(Duration.zero);
    if (director.phase != GomokuPhase.playing || director.isHumanTurn) return;
  }
}

void main() {
  late Directory hiveDirectory;
  late DatabaseService db;
  late GomokuExperienceMemoryService service;

  setUp(() async {
    hiveDirectory = await openLifecycleHive();
    db = DatabaseService();
    service = GomokuExperienceMemoryService(db);
    // 自动记忆开关来自治理预算设置；显式打开，否则用例会因为"记忆功能被关掉"
    // 而什么都没写，测不到主体。
    await MemoryControls(db).setAutomaticMemoryEnabled(true);
  });

  tearDown(() async {
    await closeLifecycleHive(hiveDirectory, db);
  });

  AICharacter character(String id, String name) => AICharacter(
        id: id,
        name: name,
        avatar: name.substring(0, 1),
        age: 20,
        role: '棋手',
        personalityTags: const [],
        systemPrompt: 'test',
        apiKey: '',
        apiProvider: '',
        modelName: '',
        gender: CharacterGender.female,
        hasKnownGender: true,
      );

  /// 跑完一整局 AI 对 AI：黑方脚本五连，白方只做填充。
  Future<GameDirector> finishAiVersusAi(
    AICharacter black,
    AICharacter white,
  ) async {
    final director = GameDirector(
      seats: [
        GomokuSeat(
          name: black.name,
          avatar: black.avatar,
          stone: GomokuStone.black,
          ai: _ScriptedPlayer(_blackWin),
        ),
        GomokuSeat(
          name: white.name,
          avatar: white.avatar,
          stone: GomokuStone.white,
          ai: _ScriptedPlayer(_whiteFiller),
        ),
      ],
      moveSpacing: Duration.zero,
    );
    director.start();
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (director.phase == GomokuPhase.playing &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(director.phase, GomokuPhase.finished,
        reason: '脚本对局没有在时限内结束');
    return director;
  }

  test('AI 对 AI：主体同时包含双方，真人不在其中', () async {
    final black = character('char-a', '阿甲');
    final white = character('char-b', '阿乙');
    final director = await finishAiVersusAi(black, white);

    await service.recordFinishedMatch(
      matchId: 'match-ab',
      director: director,
      aiCharactersByStone: {
        GomokuStone.black: black,
        GomokuStone.white: white,
      },
    );

    final memory = db.permanentMemoryBox
        .get('gomoku-match:match-ab:${black.id}') as PermanentMemory;
    expect(memory.subjectIds, containsAll(<String>[black.id, white.id]));
    expect(memory.subjectIds, isNot(contains('user')),
        reason: '这一局没有真人席位，把真人写成主体等于扩大可见范围');
    expect(memory.participantIds, containsAll(<String>[black.id, white.id]));
    expect(memory.participantIds, isNot(contains('user')));
    expect(memory.originType, MemoryOriginType.game);

    director.dispose();
  });

  test('不含对手的会话读不到这条经历，含双方时能读到', () async {
    final black = character('char-a', '阿甲');
    final white = character('char-b', '阿乙');
    final director = await finishAiVersusAi(black, white);

    await service.recordFinishedMatch(
      matchId: 'match-ab',
      director: director,
      aiCharactersByStone: {
        GomokuStone.black: black,
        GomokuStone.white: white,
      },
    );

    // 只有自己：对局正文点名了阿乙，不该被注入。
    expect(
      service.forGame(
        observerCharacterId: black.id,
        visibleCharacterIds: [black.id],
      ),
      isEmpty,
    );

    // 双方都在场：可以读到。
    final visible = service.forGame(
      observerCharacterId: black.id,
      visibleCharacterIds: [black.id, white.id],
    );
    expect(visible, contains('阿乙'));

    director.dispose();
  });

  test('AI 对真人：主体带 user，且不塞进不存在的 AI', () async {
    final black = character('char-a', '阿甲');
    final director = GameDirector(
      seats: [
        GomokuSeat(
          name: black.name,
          avatar: black.avatar,
          stone: GomokuStone.black,
          ai: _ScriptedPlayer(_blackWin),
        ),
        GomokuSeat(name: '你', avatar: '我', stone: GomokuStone.white),
      ],
      moveSpacing: Duration.zero,
    );
    director.start();

    // 黑方先落一手，之后每轮等回到真人回合再落子，直到黑方连成五子。
    var guard = 0;
    while (director.phase == GomokuPhase.playing && guard < 30) {
      guard++;
      await _settle(director);
      if (director.phase != GomokuPhase.playing) break;
      expect(director.isHumanTurn, isTrue, reason: '脚本对局卡在非真人回合');
      // 真人占一个与胜负无关的位置（第 1 行，从右往左找空格）。
      var placed = false;
      for (var col = GomokuBoard.size - 1; col >= 0; col--) {
        if (director.board.stoneAt(1, col) == null) {
          await director.humanMove(1, col);
          placed = true;
          break;
        }
      }
      expect(placed, isTrue, reason: '找不到可落子的空格');
    }
    expect(director.phase, GomokuPhase.finished,
        reason: '人机对局没有在脚本内结束');

    await service.recordFinishedMatch(
      matchId: 'match-human',
      director: director,
      aiCharactersByStone: {GomokuStone.black: black},
    );

    final memory = db.permanentMemoryBox
        .get('gomoku-match:match-human:${black.id}') as PermanentMemory;
    expect(memory.subjectIds, containsAll(<String>[black.id, 'user']));
    expect(memory.participantIds, containsAll(<String>[black.id, 'user']));

    director.dispose();
  });
}

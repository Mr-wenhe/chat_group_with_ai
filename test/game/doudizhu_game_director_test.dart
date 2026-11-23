import 'dart:async';

import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/features/game/doudizhu/doudizhu_hard_engine.dart';
import 'package:chat_group/features/game/doudizhu/doudizhu_ai_player.dart';
import 'package:chat_group/features/game/doudizhu/doudizhu_game_director.dart';
import 'package:chat_group/features/game/doudizhu/doudizhu_move_generator.dart';
import 'package:chat_group/features/game/doudizhu/doudizhu_game_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart' show CancelToken;

AICharacter _character(String name) => AICharacter(
      name: name,
      avatar: name.substring(0, 1),
      age: 30,
      role: '牌手',
      personalityTags: const [],
      systemPrompt: '角色人设',
      apiKey: '',
      apiProvider: 'custom',
    );

class _DelayedPlayer implements DoudizhuTurnPlayer {
  final started = Completer<DoudizhuAiTurnInput>();
  final response = Completer<DoudizhuPlayerDecision?>();

  @override
  Future<DoudizhuPlayerDecision?> decide(
    DoudizhuAiTurnInput input, {
    CancelToken? cancelToken,
  }) {
    if (!started.isCompleted) started.complete(input);
    return response.future;
  }
}

class _CapturePlayer implements DoudizhuTurnPlayer {
  _CapturePlayer(this.onInput);

  final void Function(DoudizhuAiTurnInput input) onInput;

  @override
  Future<DoudizhuPlayerDecision?> decide(
    DoudizhuAiTurnInput input, {
    CancelToken? cancelToken,
  }) async {
    onInput(input);
    return null;
  }
}

void main() {
  test('participant snapshot hides other hands and bottom during bidding', () {
    final director = DoudizhuGameDirector(
      seats: const [
        DoudizhuSeat(name: '真人', avatar: '我'),
        DoudizhuSeat(name: '角色甲', avatar: '甲'),
        DoudizhuSeat(name: '角色乙', avatar: '乙'),
      ],
      viewMode: DoudizhuViewMode.participant,
      humanSeat: 0,
      seed: 12345,
    );

    final snapshot = director.snapshot();
    expect(snapshot.bottomCards, isNull);
    expect(snapshot.seats[0].visibleHand, director.state.hands[0]);
    expect(snapshot.seats[1].visibleHand, isNull);
    expect(snapshot.seats[2].visibleHand, isNull);
    director.dispose();
  });

  test('god snapshot shows all hands and the bottom record', () {
    final director = DoudizhuGameDirector(
      seats: const [
        DoudizhuSeat(name: '甲', avatar: '甲'),
        DoudizhuSeat(name: '乙', avatar: '乙'),
        DoudizhuSeat(name: '丙', avatar: '丙'),
      ],
      viewMode: DoudizhuViewMode.god,
      humanSeat: null,
      seed: 12345,
    );

    final snapshot = director.snapshot();
    for (var seat = 0; seat < 3; seat++) {
      expect(snapshot.seats[seat].visibleHand, director.state.hands[seat]);
    }
    expect(snapshot.bottomCards, director.state.bottom);
    director.dispose();
  });

  test('两种模式的叫分席位输入只含本席手牌且不含未公开底牌', () async {
    for (final mode in DoudizhuViewMode.values) {
      final captured = Completer<DoudizhuAiTurnInput>();
      final player = _CapturePlayer((input) {
        if (!captured.isCompleted) captured.complete(input);
      });
      final isParticipant = mode == DoudizhuViewMode.participant;
      final director = DoudizhuGameDirector(
        seats: [
          if (isParticipant)
            const DoudizhuSeat(name: '真人', avatar: '我')
          else
            DoudizhuSeat(name: '角色零', avatar: '零', player: player),
          DoudizhuSeat(name: '角色甲', avatar: '甲', player: player),
          DoudizhuSeat(name: '角色乙', avatar: '乙', player: player),
        ],
        viewMode: mode,
        humanSeat: isParticipant ? 0 : null,
        seed: 12345,
      );
      director.state.bidTurn = 1;
      director.start();
      final input = await captured.future.timeout(const Duration(seconds: 2));
      final hiddenCards = <int>{
        ...director.state.hands[0],
        ...director.state.hands[2],
        ...director.state.bottom,
      };

      expect(input.ownHand, director.state.hands[1], reason: '$mode');
      expect(input.ownHand.toSet().intersection(hiddenCards), isEmpty,
          reason: '$mode');
      expect(input.publicBottom, isNull, reason: '$mode');
      expect(input.lastPlay, isNull, reason: '$mode');
      expect(input.publicLog, isEmpty, reason: '$mode');
      expect(input.options.every((option) => option.cardIds.isEmpty), isTrue,
          reason: '$mode');
      expect(
          input.options.map((item) => item.actionId), ['b0', 'b1', 'b2', 'b3']);
      expect(director.state.conservesPhysicalCards, isTrue);
      director.dispose();
    }
  });

  test('叫 3 分后的过渡锁住重复点击', () {
    final director = DoudizhuGameDirector(
      seats: const [
        DoudizhuSeat(name: '真人', avatar: '我'),
        DoudizhuSeat(name: '座位二', avatar: '二'),
        DoudizhuSeat(name: '座位三', avatar: '三'),
      ],
      viewMode: DoudizhuViewMode.participant,
      humanSeat: 0,
      seed: 12345,
      transitionSpacing: const Duration(seconds: 10),
    );
    director.start();
    expect(director.submitAction(0, const DoudizhuBidAction(3)).legal, isTrue);
    expect(director.snapshot().isHumanTurn, isFalse);
    expect(director.submitAction(0, const DoudizhuBidAction(3)).legal, isFalse);
    expect(director.state.bids.where((bid) => bid == 3), hasLength(1));
    director.stop();
    director.dispose();
  });

  test('公开动作事件保留模型来源和安全角色台词', () async {
    final delayed = _DelayedPlayer();
    final director = DoudizhuGameDirector(
      seats: [
        DoudizhuSeat(name: '角色甲', avatar: '甲', player: delayed),
        const DoudizhuSeat(name: '角色乙', avatar: '乙'),
        const DoudizhuSeat(name: '角色丙', avatar: '丙'),
      ],
      viewMode: DoudizhuViewMode.god,
      humanSeat: null,
      seed: 12345,
    );
    director.start();
    await delayed.started.future.timeout(const Duration(seconds: 2));
    delayed.response.complete(
      const DoudizhuPlayerDecision(
        action: DoudizhuBidAction(1),
        source: DoudizhuDecisionSource.characterModel,
        modelAttempts: 1,
        publicLine: '这轮先稳住。',
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(director.events.last.source, DoudizhuDecisionSource.characterModel);
    expect(director.events.last.publicLine, '这轮先稳住。');
    expect(director.events.last.modelAttempts, 1);
    director.dispose();
  });

  test('停止后迟到的 AI 叫分不能写回牌局', () async {
    final delayed = _DelayedPlayer();
    final director = DoudizhuGameDirector(
      seats: [
        DoudizhuSeat(name: '角色甲', avatar: '甲', player: delayed),
        const DoudizhuSeat(name: '角色乙', avatar: '乙'),
        const DoudizhuSeat(name: '角色丙', avatar: '丙'),
      ],
      viewMode: DoudizhuViewMode.god,
      humanSeat: null,
      seed: 12345,
    );
    director.start();
    final input =
        await delayed.started.future.timeout(const Duration(seconds: 2));
    final before = List<int?>.from(director.state.bids);
    director.stop();
    delayed.response.complete(
      const DoudizhuPlayerDecision(
        action: DoudizhuBidAction(1),
        source: DoudizhuDecisionSource.characterModel,
        modelAttempts: 1,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(input.phase, DoudizhuPhase.bidding);
    expect(director.status, DoudizhuMatchStatus.stopped);
    expect(director.state.bids, before);
    director.dispose();
  });

  test('三家角色通过真实 Dart 宗师 isolate 完成整局并守恒 54 张牌', () async {
    const engine = DoudizhuHardEngine();
    DoudizhuSeat makeSeat(String name) {
      final primary = AiDoudizhuPlayer(
        character: _character(name),
        config: null,
      );
      return DoudizhuSeat(
        name: name,
        avatar: name.substring(0, 1),
        player: DoudizhuCharacterPlayer(primary: primary, fallback: engine),
      );
    }

    final director = DoudizhuGameDirector(
      seats: [makeSeat('白果'), makeSeat('黑豆'), makeSeat('青梅')],
      viewMode: DoudizhuViewMode.god,
      humanSeat: null,
      seed: 12345,
      moveSpacing: Duration.zero,
      transitionSpacing: Duration.zero,
    );
    final finished = Completer<void>();
    final subscription = director.changes.listen((_) {
      expect(director.state.conservesPhysicalCards, isTrue);
      if (director.status == DoudizhuMatchStatus.finished &&
          !finished.isCompleted) {
        finished.complete();
      }
      if (director.status == DoudizhuMatchStatus.error &&
          !finished.isCompleted) {
        finished.completeError(StateError(director.statusMessage));
      }
    });
    director.start();
    await finished.future.timeout(const Duration(seconds: 28));

    expect(director.state.phase, DoudizhuPhase.over);
    expect(director.state.conservesPhysicalCards, isTrue);
    expect(director.snapshot().scores, hasLength(3));
    await subscription.cancel();
    director.dispose();
  }, timeout: const Timeout(Duration(seconds: 29)));

  test('真人与两个 APP AI 通过牌局调度完成一局', () async {
    const engine = DoudizhuHardEngine();
    DoudizhuSeat makeSeat(String name) {
      return DoudizhuSeat(
        name: name,
        avatar: name.substring(0, 1),
        player: DoudizhuCharacterPlayer(
          primary: AiDoudizhuPlayer(character: _character(name), config: null),
          fallback: engine,
        ),
      );
    }

    final director = DoudizhuGameDirector(
      seats: [
        const DoudizhuSeat(name: '你', avatar: '我'),
        makeSeat('白果'),
        makeSeat('黑豆'),
      ],
      viewMode: DoudizhuViewMode.participant,
      humanSeat: 0,
      seed: 12345,
      moveSpacing: Duration.zero,
      transitionSpacing: Duration.zero,
    );
    final finished = Completer<void>();
    var humanActionPending = false;
    final subscription = director.changes.listen((_) {
      expect(director.state.conservesPhysicalCards, isTrue);
      if (director.status == DoudizhuMatchStatus.finished &&
          !finished.isCompleted) {
        finished.complete();
        return;
      }
      if (director.status == DoudizhuMatchStatus.error &&
          !finished.isCompleted) {
        finished.completeError(StateError(director.statusMessage));
        return;
      }
      if (!director.isHumanTurn || humanActionPending) return;
      humanActionPending = true;
      scheduleMicrotask(() {
        humanActionPending = false;
        if (!director.isHumanTurn) return;
        if (director.state.phase == DoudizhuPhase.bidding) {
          director.submitAction(0, const DoudizhuBidAction(3));
        } else if (director.state.lastPlay != null) {
          director.submitAction(0, const DoudizhuPassAction());
        } else {
          final move = generateDoudizhuMoves(director.state.hands[0]).first;
          director.submitAction(0, DoudizhuPlayAction(move.cardIds));
        }
      });
    });
    director.start();
    await finished.future.timeout(const Duration(seconds: 28));

    expect(director.state.phase, DoudizhuPhase.over);
    expect(director.state.conservesPhysicalCards, isTrue);
    expect(director.snapshot().scores, hasLength(3));
    await subscription.cancel();
    director.dispose();
  }, timeout: const Timeout(Duration(seconds: 29)));
}

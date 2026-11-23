import 'dart:async';
import 'dart:isolate';

import 'package:dio/dio.dart' show CancelToken;

import 'doudizhu_ai_player.dart';
import 'doudizhu_difficulty.dart';
import 'doudizhu_engine.dart';
import 'doudizhu_game_state.dart';
import 'doudizhu_rules.dart';

const Duration doudizhuHardEngineTimeout = Duration(milliseconds: 1500);

/// Runs the upstream DP scorer away from Flutter's UI isolate.
class DoudizhuHardEngine implements DoudizhuHardMoveSelector {
  const DoudizhuHardEngine({this.timeout = doudizhuHardEngineTimeout});

  final Duration timeout;

  @override
  Future<DoudizhuHardDecision?> decide(
    DoudizhuAiTurnInput input, {
    CancelToken? cancelToken,
  }) async {
    if (input.phase != DoudizhuPhase.playing ||
        cancelToken?.isCancelled == true) {
      return null;
    }

    final resultPort = ReceivePort();
    final errorPort = ReceivePort();
    final exitPort = ReceivePort();
    final completer = Completer<DoudizhuHardDecision?>();
    Isolate? isolate;
    Timer? watchdog;
    StreamSubscription<Object?>? resultSubscription;
    StreamSubscription<Object?>? errorSubscription;
    StreamSubscription<Object?>? exitSubscription;
    var completed = false;

    void finish(DoudizhuHardDecision? result) {
      if (completed) return;
      completed = true;
      watchdog?.cancel();
      resultSubscription?.cancel();
      errorSubscription?.cancel();
      exitSubscription?.cancel();
      resultPort.close();
      errorPort.close();
      exitPort.close();
      isolate?.kill(priority: Isolate.immediate);
      completer.complete(result);
    }

    resultSubscription = resultPort.listen((message) {
      if (message is! List || message.length < 6) {
        finish(null);
        return;
      }
      final cardIds = message[0] as List<int>?;
      final action = cardIds == null
          ? const DoudizhuPassAction()
          : DoudizhuPlayAction(cardIds);
      finish(
        DoudizhuHardDecision(
          action: action,
          elapsedMilliseconds: message[1] as int,
          candidateCount: message[2] as int,
          handsBefore: message[3] as int,
          handsAfter: message[4] as int,
          score: message[5] as int,
        ),
      );
    });
    errorSubscription = errorPort.listen((_) => finish(null));
    exitSubscription = exitPort.listen((_) {
      if (!completed) finish(null);
    });
    cancelToken?.whenCancel.then((_) => finish(null));

    try {
      isolate = await Isolate.spawn<List<Object?>>(
        _runDoudizhuEngine,
        [
          resultPort.sendPort,
          List<int>.of(input.ownHand),
          _encodeMove(input.lastPlay?.move),
          input.seat,
          input.landlord,
          List<int>.of(input.handSizes),
          _playedCounts(input.publicLog),
          input.passCount,
          input.lastPlay?.seat ?? -1,
        ],
        onError: errorPort.sendPort,
        onExit: exitPort.sendPort,
        errorsAreFatal: true,
      );
      if (completed || cancelToken?.isCancelled == true) {
        isolate.kill(priority: Isolate.immediate);
        if (!completed) finish(null);
      } else {
        watchdog = Timer(timeout, () => finish(null));
      }
    } on Object {
      finish(null);
    }
    return completer.future;
  }
}

List<Object?>? _encodeMove(DoudizhuMove? move) {
  if (move == null) return null;
  return [
    move.cardIds,
    move.type.key,
    move.rank,
    move.len,
  ];
}

List<int> _playedCounts(List<DoudizhuGameLogEntry> log) {
  final counts = List<int>.filled(doudizhuRankCount, 0);
  for (final entry in log) {
    if (entry.kind != DoudizhuLogKind.play) continue;
    for (final card in entry.cardIds) {
      counts[DoudizhuRules.rankOf(card)]++;
    }
  }
  return counts;
}

void _runDoudizhuEngine(List<Object?> arguments) {
  final replyPort = arguments[0] as SendPort;
  final hand = arguments[1] as List<int>;
  final lastPlayData = arguments[2] as List<Object?>?;
  final lastPlay = lastPlayData == null
      ? null
      : DoudizhuMove(
          cardIds: lastPlayData[0] as List<int>,
          type: DoudizhuCardType.fromKey(lastPlayData[1] as String)!,
          rank: lastPlayData[2] as int,
          len: lastPlayData[3] as int,
        );
  final seat = arguments[3] as int;
  final landlord = arguments[4] as int;
  final handSizes = arguments[5] as List<int>;
  final playedCounts = arguments[6] as List<int>;
  final passCount = arguments[7] as int;
  final lastPlaySeat = arguments[8] as int;
  final result = const DoudizhuEngine().decide(
    hand: hand,
    lastPlay: lastPlay,
    context: DoudizhuEngineContext(
      seat: seat,
      landlord: landlord,
      handSizes: handSizes,
      playedCounts: playedCounts,
      passCount: passCount,
      lastPlaySeat: lastPlaySeat,
    ),
  );
  final pick = pickDoudizhuMove(result.candidates);
  final candidate = pick?.candidate;
  if (candidate == null) {
    replyPort.send(const []);
    return;
  }
  replyPort.send([
    candidate.cardIds == null ? null : List<int>.of(candidate.cardIds!),
    result.elapsedMilliseconds,
    result.candidateCount,
    result.handsBefore,
    result.handsAfter,
    candidate.score,
  ]);
}

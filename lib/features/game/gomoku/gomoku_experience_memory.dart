/// 五子棋对局经历的持久化与后续读取。
library;

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/permanent_memory.dart';
import 'package:chat_group/features/game/gomoku/game_director.dart';
import 'package:chat_group/features/game/gomoku/gomoku_board.dart';
import 'package:chat_group/features/memory/memory_controls.dart';

class GomokuExperienceMemoryService {
  static const int _gamePromptBudget = 600;
  static const int _rememberedMoveCount = 12;
  static const int _rememberedTacticCount = 3;

  /// 真人主体的固定 id（与消息 `senderId`、记忆主体约定一致）。
  static const String _humanSubjectId = 'user';

  final DatabaseService _db;

  GomokuExperienceMemoryService(this._db);

  /// 选择该角色在可见对局参与者范围内的棋局经历，供后续落子提示词使用。
  String forGame({
    required String observerCharacterId,
    required List<String> visibleCharacterIds,
  }) {
    final box = _db.permanentMemoryBox;
    if (!box.isOpen) return '';

    final visibleIds = {...visibleCharacterIds, observerCharacterId};
    final memories = box.values.where((memory) {
      if (memory.observerCharacterId != observerCharacterId ||
          memory.kind != MemoryKind.sharedExperience ||
          memory.originType != MemoryOriginType.game ||
          memory.status != MemoryStatus.active) {
        return false;
      }
      return memory.subjectIds.every(
        (id) => id == 'user' || visibleIds.contains(id),
      );
    }).toList()
      ..sort((a, b) {
        final importance = b.importance.compareTo(a.importance);
        return importance != 0
            ? importance
            : b.occurredAt.compareTo(a.occurredAt);
      });

    final selected = <String>[];
    var used = 0;
    for (final memory in memories) {
      final line = memory.content.trim();
      if (line.isEmpty) continue;
      final needed = line.length + (selected.isEmpty ? 0 : 1);
      if (used + needed > _gamePromptBudget) continue;
      selected.add(line);
      used += needed;
    }
    return selected.join('\n');
  }

  /// 每个 AI 参赛角色各自记录一份赛果与简短棋谱，重复通知不会重复写入。
  Future<void> recordFinishedMatch({
    required String matchId,
    required GameDirector director,
    required Map<GomokuStone, AICharacter> aiCharactersByStone,
  }) async {
    if (director.phase != GomokuPhase.finished) return;

    final box = _db.permanentMemoryBox;
    if (!box.isOpen || !MemoryControls(_db).automaticMemoryEnabled) return;

    final moves = director.events
        .where((event) => event.position.row >= 0 && event.position.col >= 0)
        .toList(growable: false);
    final occurredAt = DateTime.now();
    // 参与者与主体都按真实席位算：AI 席位写角色 id，真人席位才写 `user`。
    // 原来无条件把 `'user'` 塞进参与者、主体只写「自己 + user」，等于把另一位
    // AI 对手的存在抹掉了——那条记忆于是被当成「我和主人的私事」，能通过任何
    // 只含自己的会话的可见性过滤（见 [forGame] 与 MemoryContextSelector 都只比
    // subjectIds）。
    final participantIds = <String>{
      ...aiCharactersByStone.values.map((character) => character.id),
      if (director.seats.any((seat) => seat.isHuman)) _humanSubjectId,
    }.toList(growable: false);

    for (final entry in aiCharactersByStone.entries) {
      await _recordSeatMemory(
        matchId: matchId,
        director: director,
        stone: entry.key,
        character: entry.value,
        aiCharactersByStone: aiCharactersByStone,
        moves: moves,
        participantIds: participantIds,
        occurredAt: occurredAt,
      );
    }
  }

  Future<void> _recordSeatMemory({
    required String matchId,
    required GameDirector director,
    required GomokuStone stone,
    required AICharacter character,
    required Map<GomokuStone, AICharacter> aiCharactersByStone,
    required List<GomokuEvent> moves,
    required List<String> participantIds,
    required DateTime occurredAt,
  }) async {
    final memoryId = 'gomoku-match:$matchId:${character.id}';
    final box = _db.permanentMemoryBox;
    if (box.containsKey(memoryId)) return;

    final seat = _seatFor(director, stone);
    final opponent = _opponentFor(director, stone);
    if (seat == null || opponent == null) return;
    // 对手主体的身份决定了这条记忆能不能被隔离。对手是 AI 却查不到角色 id 时
    // 宁可这条不写，也不能退回 `'user'` 把隔离条件变成"谁都能读"。
    final opponentSubject = _subjectIdFor(opponent, aiCharactersByStone);
    if (opponentSubject == null) return;

    final result = _matchResult(director.board.winner, stone);
    final trace = _moveTrace(moves);
    final tactics = _tacticalNotes(moves, stone);
    final content = [
      '五子棋对局经历：我执${stone.label}子，与${opponent.name}对弈，最终$result，共${director.board.moveCount}手。',
      if (trace.isNotEmpty) '棋谱$trace。',
      if (tactics.isNotEmpty) '我当时的战术判断：$tactics。',
      '复盘时先检查双方一步成五、活四、活三和双重威胁，再评估对手的最佳回应。',
    ].join();

    await box.put(
      memoryId,
      PermanentMemory(
        id: memoryId,
        observerCharacterId: character.id,
        kind: MemoryKind.sharedExperience,
        content: content,
        // 正文点名了对手，主体就必须带上对手：只写「自己 + user」会让这条记忆
        // 在只含自己的私聊、以及不含对手的另一场棋局里照样可见。
        subjectIds: [character.id, opponentSubject],
        status: MemoryStatus.active,
        importance: 75,
        confidence: 0.95,
        originType: MemoryOriginType.game,
        originNameSnapshot: '五子棋对局',
        participantIds: participantIds,
        occurredAt: occurredAt,
      ),
    );
  }

  /// 席位对应的记忆主体 id：AI 用角色 id，真人用 [GomokuSeat.isHuman] 判 `user`。
  ///
  /// AI 席位在 [aiCharactersByStone] 里查不到时返回 null（调用方据此放弃写入）。
  String? _subjectIdFor(
    GomokuSeat seat,
    Map<GomokuStone, AICharacter> aiCharactersByStone,
  ) {
    if (seat.isHuman) return _humanSubjectId;
    return aiCharactersByStone[seat.stone]?.id;
  }

  String _matchResult(GomokuStone? winner, GomokuStone stone) {
    if (winner == null) return '和棋';
    return winner == stone ? '获胜' : '落败';
  }

  GomokuSeat? _seatFor(GameDirector director, GomokuStone stone) {
    for (final seat in director.seats) {
      if (seat.stone == stone && !seat.isHuman) return seat;
    }
    return null;
  }

  GomokuSeat? _opponentFor(GameDirector director, GomokuStone stone) {
    for (final seat in director.seats) {
      if (seat.stone != stone) return seat;
    }
    return null;
  }

  String _moveTrace(List<GomokuEvent> moves) {
    if (moves.isEmpty) return '';
    final start = moves.length > _rememberedMoveCount
        ? moves.length - _rememberedMoveCount
        : 0;
    final recent = moves.skip(start).map((event) {
      return '${event.stone.symbol}${event.position}';
    }).join(' ');
    final range = start == 0 ? '' : '（末${moves.length - start}手）';
    return '$range：$recent';
  }

  String _tacticalNotes(List<GomokuEvent> moves, GomokuStone stone) {
    final notes = <String>[];
    for (final event in moves.reversed) {
      if (event.stone != stone) continue;
      final note = _compactNote(event.reasoning);
      if (note.isEmpty) continue;
      notes.add('第${event.moveNumber}手$note');
      if (notes.length == _rememberedTacticCount) break;
    }
    return notes.reversed.join('；');
  }

  String _compactNote(String value) {
    final normalized = value
        .replaceAll(RegExp(r'\{[^{}]*\}'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (normalized.isEmpty) return '';
    final runes = normalized.runes.toList(growable: false);
    if (runes.length <= 60) return normalized;
    return '${String.fromCharCodes(runes.take(60))}…';
  }
}

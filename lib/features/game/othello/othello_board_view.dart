import 'package:flutter/material.dart';

import 'othello_types.dart';

const Color _boardColor = Color(0xFF2E7658);
const Color _boardGridColor = Color(0xFF183E30);
const Color _lastMoveColor = Color(0xFFFFBF47);

/// Native Flutter board. It renders coordinate labels, legal targets, discs,
/// and the latest move; move legality remains in the director/rules layer.
class OthelloBoardView extends StatelessWidget {
  const OthelloBoardView({
    super.key,
    required this.state,
    required this.interactive,
    required this.onTap,
  });

  final OthelloGameState state;
  final bool interactive;
  final ValueChanged<OthelloMove> onTap;

  static Key cellKey(int row, int col) => ValueKey('othello-cell-$row-$col');

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final legalMoves = state.validMoves.map((move) => move.move).toSet();
    return AspectRatio(
      aspectRatio: 1,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          children: [
            SizedBox(
              height: 22,
              child: Row(
                children: [
                  const SizedBox(width: 22),
                  for (var col = 0; col < othelloBoardSize; col++)
                    Expanded(
                      child: Center(
                        child: Text(
                          String.fromCharCode(65 + col),
                          style: TextStyle(
                            color: cs.onSurfaceVariant,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: Row(
                children: [
                  SizedBox(
                    width: 22,
                    child: Column(
                      children: [
                        for (var row = 0; row < othelloBoardSize; row++)
                          Expanded(
                            child: Center(
                              child: Text(
                                '${row + 1}',
                                style: TextStyle(
                                  color: cs.onSurfaceVariant,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: AspectRatio(
                      aspectRatio: 1,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: _boardColor,
                          border: Border.all(color: _boardGridColor, width: 2),
                          borderRadius: BorderRadius.circular(8),
                          boxShadow: [
                            BoxShadow(
                              color: cs.shadow.withValues(alpha: 0.12),
                              blurRadius: 8,
                              offset: const Offset(0, 3),
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: GridView.builder(
                            physics: const NeverScrollableScrollPhysics(),
                            padding: EdgeInsets.zero,
                            itemCount: othelloBoardSize * othelloBoardSize,
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: othelloBoardSize,
                            ),
                            itemBuilder: (context, index) {
                              final row = index ~/ othelloBoardSize;
                              final col = index % othelloBoardSize;
                              final move = OthelloMove(row, col);
                              final value = state.board[row][col];
                              final isLegal = legalMoves.contains(move);
                              final isLastMove = state.lastMove == move;
                              return _BoardCell(
                                key: cellKey(row, col),
                                move: move,
                                value: value,
                                isLegal: isLegal,
                                isLastMove: isLastMove,
                                canTap: interactive && isLegal,
                                onTap: () => onTap(move),
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BoardCell extends StatelessWidget {
  const _BoardCell({
    super.key,
    required this.move,
    required this.value,
    required this.isLegal,
    required this.isLastMove,
    required this.canTap,
    required this.onTap,
  });

  final OthelloMove move;
  final int? value;
  final bool isLegal;
  final bool isLastMove;
  final bool canTap;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      button: canTap,
      enabled: canTap,
      label: _semanticLabel(),
      child: Material(
        color: isLastMove
            ? _lastMoveColor.withValues(alpha: 0.22)
            : Colors.transparent,
        child: InkWell(
          onTap: canTap ? onTap : null,
          splashColor: Colors.white.withValues(alpha: 0.16),
          highlightColor: Colors.white.withValues(alpha: 0.08),
          child: Container(
            decoration: const BoxDecoration(
              border: Border(
                right: BorderSide(color: _boardGridColor, width: 0.75),
                bottom: BorderSide(color: _boardGridColor, width: 0.75),
              ),
            ),
            child: Center(
              child: value == null
                  ? isLegal
                      ? Container(
                          width: 9,
                          height: 9,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.65),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: _boardGridColor.withValues(alpha: 0.65),
                              width: 1,
                            ),
                          ),
                        )
                      : null
                  : _Disc(
                      isBlack: value == othelloBlackValue,
                      isLastMove: isLastMove,
                      outline: cs.outline.withValues(alpha: 0.55),
                    ),
            ),
          ),
        ),
      ),
    );
  }

  String _semanticLabel() {
    final coordinate = move.toCoordinate();
    if (value == othelloBlackValue) return '$coordinate，黑子';
    if (value == othelloWhiteValue) return '$coordinate，白子';
    if (isLegal) return '$coordinate，合法落点';
    return '$coordinate，空位';
  }
}

class _Disc extends StatelessWidget {
  const _Disc({
    required this.isBlack,
    required this.isLastMove,
    required this.outline,
  });

  final bool isBlack;
  final bool isLastMove;
  final Color outline;

  @override
  Widget build(BuildContext context) {
    return FractionallySizedBox(
      widthFactor: 0.78,
      heightFactor: 0.78,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isBlack ? const Color(0xFF171A19) : const Color(0xFFF9FAF8),
          border: Border.all(
            color: isBlack ? const Color(0xFF0D0F0E) : outline,
            width: isBlack ? 1 : 1.2,
          ),
          boxShadow: const [
            BoxShadow(
              color: Color(0x3D000000),
              blurRadius: 2,
              offset: Offset(0, 1),
            ),
          ],
        ),
        child: isLastMove
            ? Center(
                child: FractionallySizedBox(
                  widthFactor: 0.28,
                  heightFactor: 0.28,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isBlack ? _lastMoveColor : const Color(0xFFB84D20),
                    ),
                  ),
                ),
              )
            : null,
      ),
    );
  }
}

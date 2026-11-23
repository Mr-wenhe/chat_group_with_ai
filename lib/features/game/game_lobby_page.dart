import 'package:chat_group/core/theme/app_theme.dart';
import 'package:chat_group/core/widgets/app_widgets.dart';
import 'package:chat_group/features/game/gomoku/gomoku_game_page.dart';
import 'package:chat_group/features/game/doudizhu/doudizhu_game_page.dart';
import 'package:chat_group/features/game/othello/othello_game_page.dart';
import 'package:flutter/material.dart';

class GameLobbyPage extends StatelessWidget {
  const GameLobbyPage({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        backgroundColor: cs.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                gradient: AppTheme.primaryGradient,
                borderRadius: BorderRadius.circular(9),
              ),
              child: const Icon(
                Icons.sports_esports_rounded,
                size: 18,
                color: Colors.white,
              ),
            ),
            const SizedBox(width: 12),
            Text(
              '游戏',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 22,
                color: cs.onSurface,
              ),
            ),
          ],
        ),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final contentWidth =
              constraints.maxWidth > 900 ? 860.0 : constraints.maxWidth;
          return Center(
            child: SizedBox(
              width: contentWidth,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                children: [
                  const _LobbyBanner(),
                  const SizedBox(height: 28),
                  Row(
                    children: [
                      Text(
                        '全部游戏',
                        style: TextStyle(
                          color: cs.onSurface,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        '3 款',
                        style: TextStyle(
                          color: cs.onSurfaceVariant,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _GomokuGameCard(
                    colorScheme: cs,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const GomokuGamePage(),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _OthelloGameCard(
                    colorScheme: cs,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const OthelloGamePage(),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _DoudizhuGameCard(
                    colorScheme: cs,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const DoudizhuGamePage(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
      bottomNavigationBar: AppBottomNav(currentIndex: 3, cs: cs),
    );
  }
}

class _LobbyBanner extends StatelessWidget {
  const _LobbyBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: AppTheme.primaryGradient,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '游戏大厅',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '和 AI 角色一起玩，当前开放 3 款游戏。',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.9),
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(18),
            ),
            child: const Icon(
              Icons.sports_esports_rounded,
              color: Colors.white,
              size: 30,
            ),
          ),
        ],
      ),
    );
  }
}

class _GomokuGameCard extends StatelessWidget {
  final ColorScheme colorScheme;
  final VoidCallback onTap;

  const _GomokuGameCard({
    required this.colorScheme,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = colorScheme;
    return Material(
      color: cs.surfaceContainerLow,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.6)),
          ),
          child: Row(
            children: [
              const _GomokuBoardPreview(),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '五子棋',
                      style: TextStyle(
                        color: cs.onSurface,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '让 AI 角色互相对弈，或亲自挑战 AI。',
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontSize: 13,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        _GameModeChip(label: 'AI 对弈', colorScheme: cs),
                        _GameModeChip(label: '人机对战', colorScheme: cs),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right_rounded, color: cs.primary, size: 26),
            ],
          ),
        ),
      ),
    );
  }
}

class _OthelloGameCard extends StatelessWidget {
  const _OthelloGameCard({
    required this.colorScheme,
    required this.onTap,
  });

  final ColorScheme colorScheme;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = colorScheme;
    return Material(
      color: cs.surfaceContainerLow,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.6)),
          ),
          child: Row(
            children: [
              const _OthelloBoardPreview(),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '黑白棋',
                      style: TextStyle(
                        color: cs.onSurface,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '围绕翻子与角位布局，和 AI 角色对弈或亲自落子。',
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontSize: 13,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        _GameModeChip(label: '上帝视角', colorScheme: cs),
                        _GameModeChip(label: '真人参与', colorScheme: cs),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right_rounded, color: cs.primary, size: 26),
            ],
          ),
        ),
      ),
    );
  }
}

class _DoudizhuGameCard extends StatelessWidget {
  const _DoudizhuGameCard({required this.colorScheme, required this.onTap});

  final ColorScheme colorScheme;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = colorScheme;
    return Material(
      color: cs.surfaceContainerLow,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.6)),
          ),
          child: Row(
            children: [
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: const Color(0xff22684d),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Center(
                  child: Text('♠  ♥\n♣  ♦',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        height: 1.25,
                        fontWeight: FontWeight.w700,
                      )),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '斗地主',
                      style: TextStyle(
                        color: cs.onSurface,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '经典三人叫分玩法，支持上帝视角和真人参与。',
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontSize: 13,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        _GameModeChip(label: '上帝视角', colorScheme: cs),
                        _GameModeChip(label: '真人参与', colorScheme: cs),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right_rounded, color: cs.primary, size: 26),
            ],
          ),
        ),
      ),
    );
  }
}

class _OthelloBoardPreview extends StatelessWidget {
  const _OthelloBoardPreview();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 80,
      height: 80,
      decoration: BoxDecoration(
        color: const Color(0xFF2E7658),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF183E30)),
      ),
      child: const CustomPaint(painter: _OthelloBoardPreviewPainter()),
    );
  }
}

class _OthelloBoardPreviewPainter extends CustomPainter {
  const _OthelloBoardPreviewPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = const Color(0xFF183E30)
      ..strokeWidth = 0.8;
    final step = size.width / 8;
    for (var index = 1; index < 8; index++) {
      final offset = index * step;
      canvas.drawLine(Offset(offset, 0), Offset(offset, size.height), line);
      canvas.drawLine(Offset(0, offset), Offset(size.width, offset), line);
    }
    _drawDisc(canvas, step * 3.5, step * 3.5, const Color(0xFFF9FAF8), step);
    _drawDisc(canvas, step * 4.5, step * 3.5, const Color(0xFF171A19), step);
    _drawDisc(canvas, step * 3.5, step * 4.5, const Color(0xFF171A19), step);
    _drawDisc(canvas, step * 4.5, step * 4.5, const Color(0xFFF9FAF8), step);
  }

  void _drawDisc(Canvas canvas, double x, double y, Color color, double step) {
    canvas.drawCircle(Offset(x, y), step * 0.37, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _OthelloBoardPreviewPainter oldDelegate) =>
      false;
}

class _GameModeChip extends StatelessWidget {
  final String label;
  final ColorScheme colorScheme;

  const _GameModeChip({required this.label, required this.colorScheme});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: colorScheme.onPrimaryContainer,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _GomokuBoardPreview extends StatelessWidget {
  const _GomokuBoardPreview();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 80,
      height: 80,
      decoration: BoxDecoration(
        color: const Color(0xFFF2D7A0),
        borderRadius: BorderRadius.circular(16),
      ),
      child: const CustomPaint(painter: _GomokuBoardPainter()),
    );
  }
}

class _GomokuBoardPainter extends CustomPainter {
  const _GomokuBoardPainter();

  @override
  void paint(Canvas canvas, Size size) {
    const inset = 11.0;
    final step = (size.width - inset * 2) / 4;
    final linePaint = Paint()
      ..color = const Color(0xFF8C652B)
      ..strokeWidth = 1.2;

    for (var i = 0; i < 5; i++) {
      final position = inset + step * i;
      canvas.drawLine(
        Offset(inset, position),
        Offset(size.width - inset, position),
        linePaint,
      );
      canvas.drawLine(
        Offset(position, inset),
        Offset(position, size.height - inset),
        linePaint,
      );
    }

    _drawStone(
        canvas, inset + step, inset + step, const Color(0xFF202020), step);
    _drawStone(
      canvas,
      inset + step * 2,
      inset + step,
      const Color(0xFFF8F8F8),
      step,
    );
    _drawStone(
      canvas,
      inset + step * 2,
      inset + step * 2,
      const Color(0xFF202020),
      step,
    );
    _drawStone(
      canvas,
      inset + step * 3,
      inset + step * 3,
      const Color(0xFFF8F8F8),
      step,
    );
  }

  void _drawStone(Canvas canvas, double x, double y, Color color, double step) {
    final center = Offset(x, y);
    canvas.drawCircle(center, step * 0.32, Paint()..color = color);
    if (color == const Color(0xFFF8F8F8)) {
      canvas.drawCircle(
        center,
        step * 0.32,
        Paint()
          ..color = const Color(0xFF8C652B)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.8,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _GomokuBoardPainter oldDelegate) => false;
}

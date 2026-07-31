import 'package:flutter/material.dart';

/// A rounded chip used as a hint in the empty-state view.
///
/// Pure presentation — no page state dependency.
class HintChip extends StatelessWidget {
  final String text;
  final ColorScheme cs;

  const HintChip({super.key, required this.text, required this.cs});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Text(text,
          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
    );
  }
}

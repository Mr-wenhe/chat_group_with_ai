import 'package:flutter/material.dart';

/// A tappable row button used inside bottom sheets (attachment menu, action sheet).
///
/// Mirrors the old `_sheetBtn` method signature for drop-in replacement.
/// The `ctx` parameter is accepted but unused (kept for API compatibility).
class SheetButton extends StatelessWidget {
  final BuildContext ctx;
  final ColorScheme cs;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const SheetButton(
    this.ctx,
    this.cs,
    this.icon,
    this.label,
    this.onTap, {
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: cs.onSurface),
            const SizedBox(width: 14),
            Text(label, style: TextStyle(fontSize: 15, color: cs.onSurface)),
          ],
        ),
      ),
    );
  }
}

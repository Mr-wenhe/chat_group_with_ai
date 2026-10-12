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

  /// 破坏性操作（删除）用 error 色区分。
  final bool destructive;

  const SheetButton(
    this.ctx,
    this.cs,
    this.icon,
    this.label,
    this.onTap, {
    super.key,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final foreground = destructive ? cs.error : cs.onSurface;
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
            Icon(icon, size: 20, color: foreground),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 15, color: foreground),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

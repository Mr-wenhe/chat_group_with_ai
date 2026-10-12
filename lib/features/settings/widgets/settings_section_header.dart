import 'package:flutter/material.dart';

/// Titled divider that heads a group of settings cards. Shared by the settings
/// page and its sub-pages so section headings match in both.
class SettingsSectionHeader extends StatelessWidget {
  final String title;
  final ColorScheme cs;
  const SettingsSectionHeader(
      {super.key, required this.title, required this.cs});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(title,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: cs.primary,
                letterSpacing: 0.3)),
        const SizedBox(width: 12),
        Expanded(child: Divider(color: cs.outlineVariant, thickness: 0.5)),
      ],
    );
  }
}

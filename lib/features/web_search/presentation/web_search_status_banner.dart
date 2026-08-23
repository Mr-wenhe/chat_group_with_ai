import 'package:flutter/material.dart';

import '../application/search_run_state.dart';

/// Compact, reusable search status surface used by group chat and DM.
class WebSearchStatusBanner extends StatelessWidget {
  final SearchRunState state;
  final String message;
  final VoidCallback? onOpenDetails;

  const WebSearchStatusBanner({
    super.key,
    required this.state,
    required this.message,
    this.onOpenDetails,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
      child: Material(
        color: state.status == SearchRunStatus.failed
            ? colors.errorContainer.withValues(alpha: 0.62)
            : colors.tertiaryContainer.withValues(alpha: 0.48),
        borderRadius: BorderRadius.circular(10),
        child: ListTile(
          dense: true,
          minLeadingWidth: 20,
          leading: _leading(colors),
          title: Text(message, maxLines: 2, overflow: TextOverflow.ellipsis),
          trailing: onOpenDetails == null
              ? null
              : const Icon(Icons.chevron_right_rounded, size: 18),
          onTap: onOpenDetails,
        ),
      ),
    );
  }

  Widget _leading(ColorScheme colors) {
    if (_isBusy) {
      return const SizedBox.square(
        dimension: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    final color =
        state.status == SearchRunStatus.failed ? colors.error : colors.tertiary;
    return Icon(
      state.status == SearchRunStatus.failed
          ? Icons.error_outline_rounded
          : Icons.public_rounded,
      size: 18,
      color: color,
    );
  }

  bool get _isBusy => switch (state.status) {
        SearchRunStatus.awaitingConsent ||
        SearchRunStatus.planning ||
        SearchRunStatus.searching ||
        SearchRunStatus.retrying ||
        SearchRunStatus.evaluating =>
          true,
        _ => false,
      };
}

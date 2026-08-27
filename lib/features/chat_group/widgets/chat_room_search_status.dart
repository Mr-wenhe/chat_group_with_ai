import 'package:flutter/material.dart';

import 'package:chat_group/features/web_search/application/search_run_state.dart';
import 'package:chat_group/features/web_search/presentation/web_search_status_banner.dart';

/// Page-owned search status surface. Keeping the conditional banner outside
/// ChatRoomPage makes the search presentation reusable by group and DM rooms.
class ChatRoomSearchStatus extends StatelessWidget {
  final SearchRunState state;
  final String message;
  final VoidCallback? onOpenDetails;

  const ChatRoomSearchStatus({
    super.key,
    required this.state,
    required this.message,
    this.onOpenDetails,
  });

  @override
  Widget build(BuildContext context) {
    if (state.status == SearchRunStatus.idle) return const SizedBox.shrink();
    return WebSearchStatusBanner(
      state: state,
      message: message,
      onOpenDetails: onOpenDetails,
    );
  }
}

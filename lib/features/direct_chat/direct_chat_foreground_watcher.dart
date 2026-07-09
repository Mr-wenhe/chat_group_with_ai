import 'dart:async';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/widgets/top_toast.dart';
import 'package:chat_group/features/chat_group/group_chat_proactive_service.dart';
import 'package:chat_group/features/direct_chat/direct_chat_proactive_service.dart';
import 'package:chat_group/features/direct_chat/direct_chat_session.dart';
import 'package:chat_group/services/conversation_presence_service.dart';
import 'package:flutter/material.dart';

class DirectChatForegroundWatcher extends StatefulWidget {
  final Widget child;
  final DatabaseService db;
  final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey;
  final GlobalKey<NavigatorState> navigatorKey;

  const DirectChatForegroundWatcher({
    super.key,
    required this.child,
    required this.db,
    required this.scaffoldMessengerKey,
    required this.navigatorKey,
  });

  @override
  State<DirectChatForegroundWatcher> createState() =>
      _DirectChatForegroundWatcherState();
}

class _DirectChatForegroundWatcherState
    extends State<DirectChatForegroundWatcher> with WidgetsBindingObserver {
  static const Duration _initialDelay = Duration(seconds: 25);
  static const Duration _interval = Duration(seconds: 95);
  static const Duration _handoffDelay = Duration(seconds: 8);

  Timer? _timer;
  StreamSubscription<String>? _presenceSub;
  bool _checking = false;
  String? _preferredConversationId;
  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _presenceSub = ConversationPresenceService.instance.leftConversationStream
        .listen(_scheduleHandoffCheck);
    _timer = Timer(_initialDelay, _tick);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _presenceSub?.cancel();
    _timer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    if (state == AppLifecycleState.resumed) {
      _scheduleNext();
    }
  }

  Future<void> _tick() async {
    if (!mounted || _checking || _lifecycleState != AppLifecycleState.resumed) {
      _scheduleNext();
      return;
    }
    _checking = true;
    try {
      final activeConversationId =
          ConversationPresenceService.instance.activeConversationId;
      final preferredConversationId = _preferredConversationId ??
          ConversationPresenceService.instance
              .consumeRecentlyLeftConversationId();
      _preferredConversationId = null;
      final directResult = await DirectChatProactiveService(db: widget.db)
          .tryCreateProactiveMessage(
        preferredConversationId: _isDirectConversation(preferredConversationId)
            ? preferredConversationId
            : null,
      );
      if (directResult != null) {
        final conversationId = 'dm:${directResult.character.id}';
        if (activeConversationId == conversationId) {
          await widget.db.markDirectChatRead(
            conversationId,
            readAt: directResult.message.timestamp
                .add(const Duration(milliseconds: 1)),
          );
          if (mounted) setState(() {});
          return;
        }
        if (!mounted) return;
        AppToast.show(
          context,
          '${directResult.character.name} 主动发来一条私聊',
          icon: Icons.mark_chat_unread_rounded,
          actionLabel: '去看看',
          onTap: () =>
              widget.navigatorKey.currentState?.pushNamed('/direct-chats'),
        );
        if (mounted) setState(() {});
        return;
      }

      final groupResult = await GroupChatProactiveService(db: widget.db)
          .tryCreateProactiveMessage(
        activeGroupId: activeConversationId,
        preferredGroupId: _isDirectConversation(preferredConversationId)
            ? null
            : preferredConversationId,
      );
      if (groupResult != null) {
        if (activeConversationId == groupResult.group.id) {
          await widget.db.markGroupChatRead(
            groupResult.group.id,
            readAt: groupResult.message.timestamp
                .add(const Duration(milliseconds: 1)),
          );
          if (mounted) setState(() {});
          return;
        }
        if (!mounted) return;
        AppToast.show(
          context,
          '${groupResult.character.name} 在「${groupResult.group.name}」里发言了',
          icon: Icons.groups_rounded,
          actionLabel: '去看看',
          onTap: () => widget.navigatorKey.currentState
              ?.pushNamed('/chat/${groupResult.group.id}'),
        );
        if (mounted) setState(() {});
      }
    } finally {
      _checking = false;
      _scheduleNext();
    }
  }

  void _scheduleNext() {
    _timer?.cancel();
    _timer = Timer(_interval, _tick);
  }

  void _scheduleHandoffCheck(String conversationId) {
    _preferredConversationId = conversationId;
    if (_lifecycleState != AppLifecycleState.resumed) return;
    _timer?.cancel();
    _timer = Timer(_handoffDelay, _tick);
  }

  bool _isDirectConversation(String? conversationId) {
    return conversationId != null &&
        DirectChatSession.isDirectConversationId(conversationId);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

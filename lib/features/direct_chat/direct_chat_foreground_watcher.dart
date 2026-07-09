import 'dart:async';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/features/chat_group/group_chat_proactive_service.dart';
import 'package:chat_group/features/direct_chat/direct_chat_proactive_service.dart';
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

  Timer? _timer;
  bool _checking = false;
  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer(_initialDelay, _tick);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
      final directResult = await DirectChatProactiveService(db: widget.db)
          .tryCreateProactiveMessage();
      if (directResult != null) {
        widget.scaffoldMessengerKey.currentState?.showSnackBar(
          SnackBar(
            content: Text('${directResult.character.name} 主动发来一条私聊'),
            behavior: SnackBarBehavior.floating,
            action: SnackBarAction(
              label: '去看看',
              onPressed: () {
                widget.navigatorKey.currentState?.pushNamed('/direct-chats');
              },
            ),
          ),
        );
        if (mounted) setState(() {});
        return;
      }

      final groupResult = await GroupChatProactiveService(db: widget.db)
          .tryCreateProactiveMessage();
      if (groupResult != null) {
        widget.scaffoldMessengerKey.currentState?.showSnackBar(
          SnackBar(
            content: Text(
              '${groupResult.character.name} 在「${groupResult.group.name}」里发言了',
            ),
            behavior: SnackBarBehavior.floating,
            action: SnackBarAction(
              label: '去看看',
              onPressed: () {
                widget.navigatorKey.currentState
                    ?.pushNamed('/chat/${groupResult.group.id}');
              },
            ),
          ),
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

  @override
  Widget build(BuildContext context) => widget.child;
}

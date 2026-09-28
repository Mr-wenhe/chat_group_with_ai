import 'dart:async';

import 'package:chat_group/features/chat_group/chat_room_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 通知类入口（“有新消息了”）的跳转契约：
/// 必须进入产生通知的那个会话，并把该消息 id 一起带进去用于定位。
///
/// 这里只断言压栈路由构造出的 [ChatRoomPage] 参数，不 mount 真实聊天页
/// （那需要 Hive 与 API 配置）。
void main() {
  group('openChatRoomAtMessage', () {
    testWidgets('群聊通知进入对应群并携带定位消息 id', (tester) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      final observer = _RecordingNavigatorObserver();
      await tester.pumpWidget(_host(navigatorKey, observer));

      unawaited(openChatRoomAtMessage(
        navigatorKey.currentState!,
        conversationId: 'group-1',
        messageId: 'message-7',
      ));

      final room = _pushedChatRoom(observer, tester);
      expect(room.groupId, 'group-1');
      expect(room.initialMessageId, 'message-7');

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('私聊通知直达该会话（而不是私聊列表）并携带定位消息 id', (tester) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      final observer = _RecordingNavigatorObserver();
      await tester.pumpWidget(_host(navigatorKey, observer));

      unawaited(openChatRoomAtMessage(
        navigatorKey.currentState!,
        conversationId: 'dm:char-3',
        messageId: 'message-11',
      ));

      final room = _pushedChatRoom(observer, tester);
      expect(room.groupId, 'dm:char-3');
      expect(room.initialMessageId, 'message-11');

      await tester.pumpWidget(const SizedBox());
    });
  });
}

Widget _host(
  GlobalKey<NavigatorState> navigatorKey,
  NavigatorObserver observer,
) {
  return MaterialApp(
    navigatorKey: navigatorKey,
    navigatorObservers: [observer],
    home: const Scaffold(body: SizedBox.shrink()),
  );
}

/// 取出最后压栈的路由并校验其目标是带定位参数的 [ChatRoomPage]。
///
/// 刻意不 pump：一旦 pump，路由会被真正挂载，聊天页的 Hive 依赖就会启动。
ChatRoomPage _pushedChatRoom(
  _RecordingNavigatorObserver observer,
  WidgetTester tester,
) {
  final route = observer.pushedRoutes.last as MaterialPageRoute<dynamic>;
  final destination = route.builder(tester.element(find.byType(MaterialApp)));
  expect(destination, isA<ChatRoomPage>());
  return destination as ChatRoomPage;
}

class _RecordingNavigatorObserver extends NavigatorObserver {
  final List<Route<dynamic>> pushedRoutes = [];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushedRoutes.add(route);
    super.didPush(route, previousRoute);
  }
}

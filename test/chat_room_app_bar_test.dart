import 'package:chat_group/features/chat_group/widgets/chat_room_app_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('keeps relationship and memory actions available on a narrow bar',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var membersOpened = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: ChatRoomAppBar(
            title: '测试群聊',
            subtitle: '一段很长的群聊摘要不会挤占操作入口',
            isSearching: false,
            searchController: TextEditingController(),
            hasSearchResults: false,
            searchResultLabel: '0 / 0',
            showGroupActions: true,
            onSearchChanged: (_) {},
            onEnterSearch: () {},
            onPreviousResult: () {},
            onNextResult: () {},
            onExitSearch: () {},
            onExport: () {},
            onOpenMemory: () {},
            onOpenRelationship: () {},
            relationshipTooltip: '查看关系',
            webSearchIcon: Icons.public_rounded,
            webSearchTooltip: '联网搜索',
            onConfigureWebSearch: () {},
            onClearConversation: () {},
            onOpenMembers: () => membersOpened = true,
          ),
        ),
      ),
    );

    expect(find.byTooltip('查看记忆'), findsOneWidget);
    expect(find.byTooltip('查看关系'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey('chat-room-more-actions')));
    await tester.pumpAndSettle();
    expect(find.text('群成员'), findsOneWidget);
    expect(find.text('导出对话'), findsOneWidget);
    await tester.tap(find.text('群成员'));
    await tester.pumpAndSettle();
    expect(membersOpened, isTrue);
  });
}

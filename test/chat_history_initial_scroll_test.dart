import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chat_group/features/chat_group/chat_scroll_utils.dart';

void main() {
  testWidgets('异步载入的可变高度历史消息会滚到最终末条', (tester) async {
    final scrollController = ScrollController();
    addTearDown(scrollController.dispose);

    await tester.pumpWidget(
      MaterialApp(home: _HistoryView(scrollController: scrollController)),
    );
    await tester.pumpAndSettle();

    expect(
      scrollController.offset,
      scrollController.position.maxScrollExtent,
      reason: '重启后载入历史消息应定位到最后一条，而非首帧估算的末端',
    );
  });
}

class _HistoryView extends StatefulWidget {
  final ScrollController scrollController;

  const _HistoryView({required this.scrollController});

  @override
  State<_HistoryView> createState() => _HistoryViewState();
}

class _HistoryViewState extends State<_HistoryView> {
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      setState(() => _loaded = true);
      scrollToBottomAfterInitialLayout(widget.scrollController);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const SizedBox.shrink();
    return ListView.builder(
      controller: widget.scrollController,
      itemCount: 30,
      itemBuilder: (context, index) => Padding(
        padding: const EdgeInsets.all(8),
        child: Text(index < 12 ? '短消息' : '很长的历史消息 ' * 100),
      ),
    );
  }
}

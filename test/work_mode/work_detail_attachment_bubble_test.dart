import 'dart:io';

import 'package:chat_group/core/models/media_attachment.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/widgets/readable_json_dialog.dart';
import 'package:chat_group/features/chat_group/widgets/chat_message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 工作模式详情留档在聊天气泡里的呈现。
///
/// 单独成文件而不是并进 `chat_message_bubble_test.dart`：那份用例集合负责气泡
/// 排版与操作菜单，这里只管一类附件的卡片语义。
void main() {
  const taskId = 'c5b9cb7a-651f-45c5-ac81-eae78e8aca4c';
  const digest = '86f37541e97fa4cdd9484fcf';

  MediaAttachment detail(String path) => MediaAttachment(
        type: 'file',
        localPath: path,
        fileName: '方案与验收详情.json',
        fileSize: 3269,
        mimeType: 'application/json',
      );

  Widget bubble(List<MediaAttachment> media) => MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 360,
            child: ChatMessageBubble(
              message: Message(
                id: 'message-1',
                groupId: 'g1',
                senderId: 'ai-1',
                senderType: Message.senderTypeAi,
                content: '先按最小可玩版起方案',
                media: media,
              ),
              characters: const [],
              cs: const ColorScheme.light(),
              senderColor: (_) => Colors.blue,
              ownerName: '我',
            ),
          ),
        ),
      );

  testWidgets('显示「内部记录」而不是文档解析状态', (tester) async {
    await tester.pumpWidget(bubble([
      detail('/Users/u/…/work_mode_agent/events/$taskId.detail.$digest.json')
    ]));

    expect(find.text('内部记录 · 3.2 KB'), findsOneWidget);
    // 「待解析」是给用户文档用的状态，对内部留档没有意义，也是
    // "这文件是什么" 的困惑来源。
    expect(find.textContaining('待解析'), findsNothing);
  });

  testWidgets('桌面用户附件显示预览入口，其余平台保留解析状态', (tester) async {
    await tester.pumpWidget(bubble([
      MediaAttachment(
        type: 'file',
        localPath: '/Users/u/Documents/报告.docx',
        fileName: '报告.docx',
        fileSize: 4096,
      )
    ]));

    expect(
        find.textContaining(
            Platform.isMacOS || Platform.isWindows ? '点击预览' : '待解析'),
        findsOneWidget);
    expect(find.textContaining('内部记录'), findsNothing);
  });

  testWidgets('点开走应用内可读视图，而不是交给系统打开 JSON', (tester) async {
    // 全程同步文件 API：testWidgets 跑在 FakeAsync 区里，真实 I/O 的 Future
    // 永远不会完成，`await createTemp()` 之类会把用例永久挂住。
    final root = Directory.systemTemp.createTempSync('detail_bubble');
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });
    final events = Directory('${root.path}/work_mode_agent/events')
      ..createSync(recursive: true);
    final file = File('${events.path}/$taskId.detail.$digest.json')
      ..writeAsStringSync('{"scope":"做一个飞行棋"}');

    await tester.pumpWidget(bubble([detail(file.path)]));
    await tester.tap(find.text('方案与验收详情.json'));
    // 有界 pump 而不是 pumpAndSettle：本仓库测试对帧数有界（CLAUDE.md 死循环
    // 防护规则），对话框的入栈过渡用固定时长推完即可。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(ReadableJsonDialog), findsOneWidget);
    // 气泡自己的正文也是 SelectableText，必须限定在对话框内取。
    expect(
      tester
          .widget<SelectableText>(find.descendant(
            of: find.byType(ReadableJsonDialog),
            matching: find.byType(SelectableText),
          ))
          .data,
      contains('"scope": "做一个飞行棋"'),
    );
  });

  testWidgets('长按仍给出打开、定位与复制路径', (tester) async {
    await tester.pumpWidget(bubble([
      detail('/Users/u/…/work_mode_agent/events/$taskId.detail.$digest.json')
    ]));

    await tester.longPress(find.text('方案与验收详情.json'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('打开文件'), findsOneWidget);
    expect(find.text('在 Finder/资源管理器中显示'), findsOneWidget);
    expect(find.text('复制绝对路径'), findsOneWidget);
  });
}

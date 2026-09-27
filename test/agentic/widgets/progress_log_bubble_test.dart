import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/features/chat_group/widgets/blinking_cursor.dart';
import 'package:chat_group/features/chat_group/widgets/chat_message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// `ProgressLogBubble` Widget 测试：可折叠 + 实时耗时 + 终态冻结。
///
/// 进度内容的**生产**侧（旧版 `AgentRuntime` 埋点）已移除，气泡现在只为
/// 历史 `agent-progress:` 消息渲染。因此这里直接把当年的行格式写成字面量，
/// 作为渲染契约的固定输入；断言覆盖的是气泡的解析与展示，不依赖已删除的格式化逻辑。
void main() {
  // 确定性时钟：测试期间手动推进，避免依赖真实墙钟导致耗时跳动断言不稳定。
  const baseEpoch = 1700000000000; // 固定基准毫秒
  int fakeNow = baseEpoch;

  setUp(() {
    fakeNow = baseEpoch;
    ProgressLogBubble.nowMs = () => fakeNow;
  });

  tearDown(() {
    ProgressLogBubble.nowMs = () => DateTime.now().millisecondsSinceEpoch;
  });

  // 历史进度消息的行格式（与老版本生成器输出一致）。
  const runningHeader = '🧭 小智 · 工作模式 ｜ 执行中';
  const doneHeader = '🧭 小智 · 工作模式 ｜ 已完成';
  const doneStepLine = '✅ 已创建文件：page.html · 需批准';
  const activeStepLine = '⏳ 正在校验结果：page.html';
  const finalStepLine = '✅ 正在校验结果：page.html';

  const runningContent = '$runningHeader\n$doneStepLine\n$activeStepLine';
  const finalContent = '$doneHeader\n$doneStepLine\n$finalStepLine';

  /// 将进度 content 包裹为历史 `agent-progress:` 消息。
  Message progressMessage(String content) => Message(
        id: 'agent-progress:test',
        groupId: 'g1',
        senderId: 'c1',
        senderType: 'ai',
        content: content,
      );

  /// 读取头部含 ⏱ 的 Text 文案。
  String headerElapsedText(WidgetTester tester) {
    for (final widget in tester.widgetList<Text>(find.byType(Text))) {
      final data = widget.data;
      if (data != null && data.contains('⏱')) return data;
    }
    return '';
  }

  group('ProgressLogBubble', () {
    // 默认展开：渲染完整多行（含 ✅ 已完成行）。
    testWidgets('defaults to expanded, shows full step lines', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ProgressLogBubble(message: progressMessage(runningContent))),
      ));

      // 展开态：✅ 已完成行可见。
      expect(find.text(doneStepLine), findsOneWidget);
      // 进行中 ⏳ 行可见，且尾部有 BlinkingCursor。
      expect(find.text(activeStepLine), findsOneWidget);
      expect(find.byType(BlinkingCursor), findsOneWidget);
    });

    // runStartedAtMs 非空时头部含 ⏱。
    testWidgets('shows ⏱ when runStartedAtMs is provided', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ProgressLogBubble(
            message: progressMessage(runningContent),
            runStartedAtMs: baseEpoch - 2000,
          ),
        ),
      ));

      final header = headerElapsedText(tester);
      expect(header, contains('⏱'));
      expect(header, contains('2s'));
    });

    // 折叠后仅渲染单行摘要，含「已 N 步」，且多行明细消失。
    testWidgets('collapsed shows single-line summary with 已 N 步',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ProgressLogBubble(
            message: progressMessage(runningContent),
            runStartedAtMs: baseEpoch - 2000,
          ),
        ),
      ));

      // 初始展开 → 折叠按钮为 expand_less。
      expect(find.byIcon(Icons.expand_less), findsOneWidget);
      await tester.tap(find.byIcon(Icons.expand_less));
      await tester.pump();

      // 折叠态：多行明细消失，仅保留单行摘要（含实时耗时 + 步数）。
      expect(find.text(doneStepLine), findsNothing);
      expect(find.text(activeStepLine), findsNothing);
      expect(find.byIcon(Icons.expand_more), findsOneWidget);
      // 摘要含「已 1 步」且仍有 ⏱ 实时耗时。
      final header = headerElapsedText(tester);
      expect(header, contains('⏱'));
      expect(header, contains('已 1 步'));
    });

    // 实时耗时跳动：推进时钟 + pump 触发 Timer，⏱ 数值变化。
    testWidgets('elapsed ticks every second via Timer', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ProgressLogBubble(
            message: progressMessage(runningContent),
            runStartedAtMs: baseEpoch - 2000,
          ),
        ),
      ));

      final before = headerElapsedText(tester);
      expect(before, contains('2s'));

      // 推进 1 秒并触发 Timer.periodic 回调（fake 时钟）。
      fakeNow += 1000;
      await tester.pump(const Duration(seconds: 1));

      final after = headerElapsedText(tester);
      expect(after, contains('3s'));
      expect(after, isNot(equals(before)));
    });

    // 终态（末行 ✅）不显示 ⏳，不启动 Timer；折叠摘要用「共 N 步」。
    testWidgets('final content has no ⏳ and uses 共 N 步', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ProgressLogBubble(
            message: progressMessage(finalContent),
            runStartedAtMs: baseEpoch - 5000,
          ),
        ),
      ));

      // 终态无进行中光标、无 ⏳ 当前行。
      expect(find.byType(BlinkingCursor), findsNothing);
      expect(find.text(activeStepLine), findsNothing);
      // 展开态头部为「已完成」，✅ 已完成行可见，⏱ 展示冻结值。
      expect(find.textContaining('已完成'), findsWidgets);
      final header = headerElapsedText(tester);
      expect(header, contains('⏱'));
      expect(header, contains('5s'));
      expect(find.text(doneStepLine), findsOneWidget);

      // 折叠后单行摘要用「共 2 步」（终态含 2 条 ✅ 行）。
      await tester.tap(find.byIcon(Icons.expand_less));
      await tester.pump();
      final collapsed = headerElapsedText(tester);
      expect(collapsed, contains('共 2 步'));
      expect(find.text(doneStepLine), findsNothing);
    });

    // runStartedAtMs 为 null：头部无 ⏱、不崩溃、不启动 Timer。
    testWidgets('null runStartedAtMs shows no ⏱ and does not crash',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ProgressLogBubble(message: progressMessage(runningContent))),
      ));

      expect(headerElapsedText(tester), isEmpty);
      // 进行中仍有 BlinkingCursor（不依赖耗时的光标逻辑不变）。
      expect(find.byType(BlinkingCursor), findsOneWidget);
      // 推进时间不引发崩溃（无 Timer 刷新，但 build 幂等）。
      await tester.pump(const Duration(seconds: 1));
      expect(headerElapsedText(tester), isEmpty);
    });

    // 终态 content 已把 ⏱ 烘焙进首行，且 runStartedAtMs 变 null
    // （_progressStartTimes 已清理）后，气泡仍正确显示冻结耗时——
    // 取自 content 而非 live 计算，既不丢失也不与 live 重复。
    testWidgets(
        'final content bakes frozen ⏱ shown when runStartedAtMs is null',
        (tester) async {
      // 构造：终态 + 冻结耗时 42s → 首行烘焙 ⏱ 42s。
      const bakedContent = '$doneHeader ⏱ 42s\n$doneStepLine\n$finalStepLine';
      final message = Message(
        id: 'agent-progress:final',
        groupId: 'g1',
        senderId: 'c1',
        senderType: 'ai',
        content: bakedContent,
      );

      // runStartedAtMs 为 null：模拟终态后 _progressStartTimes.remove 的状态。
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ProgressLogBubble(message: message)),
      ));

      // 首行头部含烘焙的冻结耗时（来自 content，而非 live 计算）。
      final header = headerElapsedText(tester);
      expect(header, contains('⏱ 42s'));
      expect(header, contains('已完成'));
      // 终态无进行中光标、未启动 live Timer。
      expect(find.byType(BlinkingCursor), findsNothing);
    });
  });
}

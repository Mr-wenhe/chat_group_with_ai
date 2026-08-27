part of 'chat_message_bubble.dart';

/// P2：可折叠 + 实时总耗时跳动的进度气泡。
///
/// 复用 [Message.content] 已写入的多行步骤日志（首行头部 → ✅ 已完成行 → ⏳ 当前行），
/// 在其上叠加：
///  - 折叠/展开：本地 [_expanded] 状态，点击头部行首图标切换；
///  - 实时耗时：[runStartedAtMs] 非空时头部每秒刷新 `⏱ {formatElapsed}`；
///  - 终态冻结：末行不以 ⏳ 开头即终态，取消 [Timer] 停止跳动。
///
/// 动效由 widget 自身 [setState] 驱动，不依赖外部频繁 setState 全树重建；
/// [BlinkingCursor] 仅出现在展开态且末行为 ⏳ 的进行中步骤。
class ProgressLogBubble extends StatefulWidget {
  final Message message;
  final int? runStartedAtMs;

  const ProgressLogBubble({
    super.key,
    required this.message,
    this.runStartedAtMs,
  });

  /// 当前时刻（ms）。默认取系统时钟；测试可临时替换以确定性验证耗时跳动。
  static int Function() nowMs = () => DateTime.now().millisecondsSinceEpoch;

  @override
  State<ProgressLogBubble> createState() => _ProgressLogBubbleState();
}

class _ProgressLogBubbleState extends State<ProgressLogBubble> {
  bool _expanded = true;
  Timer? _timer;

  /// 终态判定：content 末非空行不以 ⏳ 开头（如 ✅ 终态摘要）即为终态。
  bool _isFinalState(String content) {
    final lines = content.split('\n');
    final lastNonEmpty =
        lines.lastWhere((l) => l.trim().isNotEmpty, orElse: () => '');
    return !lastNonEmpty.startsWith(stepPrefixActive);
  }

  String get _normalizedContent =>
      widget.message.content.replaceAll('\\n', '\n');

  @override
  void initState() {
    super.initState();
    // 仅当携带启动时刻且当前为进行中（非终态）时，启动每秒刷新 Timer。
    if (widget.runStartedAtMs != null && !_isFinalState(_normalizedContent)) {
      _timer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => setState(() {}),
      );
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final textColor = WeComChatTokens.text(context);
    final content = _normalizedContent;
    final lines = content.split('\n');
    final header = lines.first;
    final stepLines = lines.skip(1).where((l) => l.trim().isNotEmpty).toList();
    final doneCount =
        stepLines.where((l) => l.startsWith(stepPrefixDone)).length;
    final isFinal = _isFinalState(content);

    // 终态：取消 Timer，⏱ 冻结，不再跳动。
    if (isFinal && _timer != null) {
      _timer?.cancel();
      _timer = null;
    }

    // 实时总耗时文案（runStartedAtMs 为空则不展示）。
    final elapsed = widget.runStartedAtMs == null
        ? ''
        : ' ⏱ ${formatElapsed(((ProgressLogBubble.nowMs() - widget.runStartedAtMs!) / 1000).round())}';

    final summaryText = isFinal ? '共 $doneCount 步' : '已 $doneCount 步';

    final collapseButton = GestureDetector(
      onTap: () => setState(() => _expanded = !_expanded),
      child: Icon(
        _expanded ? Icons.expand_less : Icons.expand_more,
        size: 16,
        color: textColor,
      ),
    );

    final lineStyle = TextStyle(
      fontSize: 15,
      color: textColor,
      height: 1.45,
    );

    // 折叠态：单行摘要（头部 + 实时耗时 + 步数），无多行明细、无 BlinkingCursor。
    if (!_expanded) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          collapseButton,
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              '$header$elapsed · $summaryText',
              style: lineStyle,
            ),
          ),
        ],
      );
    }

    // 展开态：完整多行 + 进行中步骤行尾 BlinkingCursor。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            collapseButton,
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                '$header$elapsed',
                style: lineStyle,
              ),
            ),
          ],
        ),
        ...stepLines.map((line) {
          final isActive = line.startsWith(stepPrefixActive);
          return Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Flexible(
                child: Text(line, style: lineStyle),
              ),
              if (isActive) ...[
                const SizedBox(width: 2),
                BlinkingCursor(color: textColor),
              ],
            ],
          );
        }),
      ],
    );
  }
}

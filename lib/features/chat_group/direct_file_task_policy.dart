bool shouldAutoApproveDirectFileTask({
  required bool isDirectChat,
  required String userMessage,
}) {
  if (!isDirectChat) return false;
  final lower = userMessage.toLowerCase();
  final asksForCommand = lower.contains('flutter test') ||
      lower.contains('flutter analyze') ||
      lower.contains('运行测试') ||
      lower.contains('运行命令') ||
      lower.contains('执行命令') ||
      lower.contains('terminal') ||
      lower.contains('command.run');
  if (asksForCommand) return false;

  final hasCreateVerb = lower.contains('生成') ||
      lower.contains('创建') ||
      lower.contains('写') ||
      lower.contains('写入') ||
      lower.contains('写文件') ||
      lower.contains('写一份') ||
      lower.contains('撰写') ||
      lower.contains('实现') ||
      lower.contains('输出') ||
      lower.contains('导出') ||
      lower.contains('脚本') ||
      lower.contains('script') ||
      lower.contains('create') ||
      lower.contains('write');
  if (!hasCreateVerb) return false;

  return lower.contains('文件') ||
      lower.contains('文档') ||
      lower.contains('脚本') ||
      lower.contains('script') ||
      lower.contains('bash') ||
      lower.contains('markdown') ||
      lower.contains('md格式') ||
      lower.contains('工程目录') ||
      lower.contains('工作目录') ||
      lower.contains('path') ||
      lower.contains('file') ||
      RegExp(
        r'\.(?:html|md|markdown|dart|txt|json|yaml|yml|svg|css|js|ts|py|sh|bash|c|cc|cpp|h|hpp)\b',
        caseSensitive: false,
      ).hasMatch(userMessage) ||
      RegExp(
        r'(?:html|html5|md|markdown|dart|txt|json|yaml|yml|svg|css|js|ts|py|sh|bash)\s*(?:文件|格式|脚本)',
        caseSensitive: false,
      ).hasMatch(userMessage) ||
      RegExp(
        r'(?:使用|用|生成|创建|实现|输出|写)\s*(html|html5|md|markdown|dart|txt|json|yaml|yml|svg|css|js|ts|py|sh|bash)(?![a-zA-Z0-9_])',
        caseSensitive: false,
      ).hasMatch(userMessage) ||
      RegExp(
        r'(?:^|[\s，。！？!?、；;：:,])(?:html|html5|md|markdown|dart|txt|json|yaml|yml|svg|css|js|ts|py|sh|bash)(?:$|[\s，。！？!?、；;：:,])',
        caseSensitive: false,
      ).hasMatch(userMessage);
}

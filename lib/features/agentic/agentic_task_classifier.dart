class AgenticTaskClassifier {
  static const _alwaysAgenticPatterns = [
    '写代码',
    'review',
    '代码审查',
    '修复',
    'bug',
    '运行测试',
    '运行命令',
    'flutter analyze',
    'flutter test',
    '当前浏览器',
    '浏览器页面',
    '网页内容',
    '选中的网页',
    '生成skill',
    '生成 skill',
    '创建skill',
    '创建 skill',
    '下载skill',
    '下载 skill',
    '安装skill',
    '安装 skill',
    '专家skill',
    '专家 skill',
    '审核这份',
    '审查这份',
    '任务计划',
    '实施计划',
    '进度保存',
    '进度文件',
  ];

  static final _createOrEditIntent = RegExp(
    r'(生成|创建|写|制作|做一个|做个|帮我做|给我做|实现|开发|输出|导出|'
    r'修改|改一下|改写|编辑|整理|转换|撰写|审核|审查|保存|'
    r'create|write|build|make|generate|edit|audit)',
    caseSensitive: false,
  );

  static final _artifactIntent = RegExp(
    r'(代码|脚本|script|特效|html?|网页|主页|个人页|介绍页|页面|网站|落地页|'
    r'landing|app|应用|小程序|小游戏|文件|文件夹|路径|markdown|\bmd\b|文档|'
    r'报告|简历|工作流|dart|flutter|json|ya?ml|css|javascript|\bjs\b|'
    r'python|\bpy\b)',
    caseSensitive: false,
  );

  static final _explicitFilePath = RegExp(
    r'(?<![\w./\\-])[\w][\w./\\-]*\.(?:html?|md|markdown|dart|txt|json|yaml|yml|svg|css|js|ts|py|sh|bash|c|cc|cpp|h|hpp)(?![\w./\\-])',
    caseSensitive: false,
  );

  static bool requiresAgenticWork(String message) {
    final lower = message.toLowerCase();
    if (_alwaysAgenticPatterns.any(lower.contains)) return true;

    final hasAction = _createOrEditIntent.hasMatch(lower);
    if (!hasAction) return false;
    return _artifactIntent.hasMatch(lower) ||
        _explicitFilePath.hasMatch(message);
  }
}

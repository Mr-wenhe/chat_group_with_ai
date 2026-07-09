enum AutonomousTriggerKind {
  none,
  suggest,
  startInConversationDir,
  needsProjectAuthorization,
  startInAuthorizedProject,
}

class AutonomousTriggerResult {
  final AutonomousTriggerKind kind;
  final String taskType;
  final bool likelyNeedsProject;

  const AutonomousTriggerResult({
    required this.kind,
    required this.taskType,
    required this.likelyNeedsProject,
  });

  bool get shouldStart =>
      kind == AutonomousTriggerKind.startInConversationDir ||
      kind == AutonomousTriggerKind.startInAuthorizedProject;
}

class AutonomousTriggerDetector {
  static const _codePatterns = [
    '代码',
    '开发',
    '实现',
    '修复',
    'bug',
    '测试',
    'review',
    'cpp',
    'c++',
    '.dart',
    '.cpp',
    '.py',
    '.js',
  ];
  static const _docPatterns = ['文档', 'markdown', '报告', '计划', '需求', '总结'];
  static const _workflowPatterns = ['工作流', '流程', '自动化', '脚本', 'pipeline'];
  static const _filePatterns = ['生成文件', '创建文件', '写入', '转换', '整理文件', '目录'];
  static const _mediaPatterns = ['图片', '格式转换', '压缩', '裁剪', '转成'];
  static const _systemPatterns = ['系统', '命令', 'cpu', '内存', 'memory', '磁盘'];

  const AutonomousTriggerDetector();

  AutonomousTriggerResult detect({
    required String text,
    required bool autonomyEnabled,
    required bool sourceAuthorized,
  }) {
    final lower = text.toLowerCase();
    final taskType = _taskType(lower);
    if (taskType == 'chat') {
      return const AutonomousTriggerResult(
        kind: AutonomousTriggerKind.none,
        taskType: 'chat',
        likelyNeedsProject: false,
      );
    }

    final needsProject = _looksProjectBound(lower, taskType);
    if (!autonomyEnabled) {
      return AutonomousTriggerResult(
        kind: AutonomousTriggerKind.suggest,
        taskType: taskType,
        likelyNeedsProject: needsProject,
      );
    }
    if (needsProject && !sourceAuthorized) {
      return AutonomousTriggerResult(
        kind: AutonomousTriggerKind.needsProjectAuthorization,
        taskType: taskType,
        likelyNeedsProject: true,
      );
    }
    return AutonomousTriggerResult(
      kind: needsProject
          ? AutonomousTriggerKind.startInAuthorizedProject
          : AutonomousTriggerKind.startInConversationDir,
      taskType: taskType,
      likelyNeedsProject: needsProject,
    );
  }

  String _taskType(String lower) {
    if (_containsAny(lower, _codePatterns)) return 'code';
    if (_containsAny(lower, _docPatterns)) return 'docs';
    if (_containsAny(lower, _workflowPatterns)) return 'workflow';
    if (_containsAny(lower, _mediaPatterns)) return 'media';
    if (_containsAny(lower, _systemPatterns)) return 'system';
    if (_containsAny(lower, _filePatterns)) return 'file';
    return 'chat';
  }

  bool _looksProjectBound(String lower, String taskType) {
    if (taskType == 'code') return true;
    return lower.contains('项目') ||
        lower.contains('源码') ||
        lower.contains('工程') ||
        lower.contains('仓库') ||
        lower.contains('运行测试') ||
        lower.contains('flutter analyze') ||
        lower.contains('flutter test');
  }

  bool _containsAny(String value, List<String> patterns) {
    return patterns.any(value.contains);
  }
}

/// Completion guard for file deliverables in production work mode.
///
/// WorkAgentLoop never turns a model's prose into an attachment. When a request
/// explicitly asks for a file artifact, the production adapter must have a
/// real readable file before it can publish a successful completion.
class WorkArtifactDeliveryGuard {
  const WorkArtifactDeliveryGuard._();

  static const String missingArtifactMessage =
      '用户要求文件产物，但没有可读取的真实文件；未将说明文字伪装成附件。'
      '请通过 workspace.patch 写入并核对文件后再完成。';

  /// Returns whether [request] asks for a source-code file rather than merely
  /// asking the model to explain or review code.
  static bool requiresSourceArtifact(String request) {
    final text = request.trim().toLowerCase();
    if (text.isEmpty) return false;

    final source = RegExp(
      r'(?:\.(?:py|py3|js|jsx|ts|tsx|dart|java|kt|kts|swift|rs|go|rb|php|'
      r'c|cc|cpp|cxx|h|hpp|sh|bash|zsh|fish|sql)\b|'
      r'python|javascript|typescript|dart|java|kotlin|swift|rust|golang|'
      r'ruby|php|c\+\+|\bc\b|shell|bash|sql|源码|代码|脚本)',
      caseSensitive: false,
    ).hasMatch(text);
    if (!source) return false;

    return _containsCreationVerb(text);
  }

  /// Returns whether a request asks for a non-source file such as Markdown.
  /// A document is required only when the request also contains a creation or
  /// modification verb; read/review requests must remain ordinary analysis.
  static bool requiresFileArtifact(String request) {
    final text = request.trim().toLowerCase();
    if (text.isEmpty || !_containsCreationVerb(text)) return false;
    return RegExp(
      r'(?:文件|文档|报告|报表|清单|表格|附件|markdown|md文档|'
      r'\.(?:md|markdown|txt|csv|json|ya?ml|html?)\b)',
      caseSensitive: false,
    ).hasMatch(text);
  }

  static bool _containsCreationVerb(String text) => RegExp(
        r'(?:生成|创建|新建|写入|保存|导出|输出|编写|实现|开发|修改|修复|'
        r'更新|重构|制作|generate|create|write|save|export|output|implement|'
        r'develop|modify|fix|update|refactor|build|make)',
        caseSensitive: false,
      ).hasMatch(text);

  static String? failureFor({
    required String request,
    required bool hasReadableArtifact,
  }) {
    if ((!requiresSourceArtifact(request) && !requiresFileArtifact(request)) ||
        hasReadableArtifact) {
      return null;
    }
    return missingArtifactMessage;
  }
}

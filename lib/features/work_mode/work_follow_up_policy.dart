/// How a queued user request should be attached to the existing work task.
enum WorkFollowUpKind {
  continueTask,
  reviseArtifact,
  newArtifact,
  clarification,
}

class WorkFollowUpDecision {
  final WorkFollowUpKind kind;
  final String request;
  final String? artifactPath;
  final String? clarificationQuestion;
  final String reason;
  final bool autoRenameIfExists;

  const WorkFollowUpDecision({
    required this.kind,
    required this.request,
    this.artifactPath,
    this.clarificationQuestion,
    this.reason = '',
    this.autoRenameIfExists = false,
  });

  bool get isRevision => kind == WorkFollowUpKind.reviseArtifact;

  bool get isClarification => kind == WorkFollowUpKind.clarification;

  /// A descriptive alias for callers that treat this as a collision policy.
  bool get allowCollisionRename => autoRenameIfExists;
}

/// Decides whether a follow-up continues, revises an existing artifact, or
/// creates a new one. It intentionally has no access to message history: the
/// structured artifact list is the only source for an implicit old-file path.
class WorkFollowUpPolicy {
  const WorkFollowUpPolicy();

  WorkFollowUpDecision resolve({
    required String request,
    Iterable<String> lastArtifactPaths = const [],
  }) {
    final normalizedRequest = request.trim();
    if (normalizedRequest.isEmpty) {
      return const WorkFollowUpDecision(
        kind: WorkFollowUpKind.continueTask,
        request: '',
      );
    }
    final artifacts = _paths(lastArtifactPaths);
    final explicitPath = _explicitPath(normalizedRequest);
    final edit = _hasEditVerb(normalizedRequest);
    final reference = _hasArtifactReference(normalizedRequest);
    final newFile = _hasNewFileIntent(normalizedRequest);

    // "新建/创建" is the one case where an occupied name may be changed.
    // An edit request always wins over a generic file keyword.
    if (newFile && !edit && !reference) {
      return WorkFollowUpDecision(
        kind: WorkFollowUpKind.newArtifact,
        request: normalizedRequest,
        reason: '用户明确要求新建文件，重名时允许生成新路径。',
        autoRenameIfExists: true,
      );
    }
    // A path/reference by itself is not an instruction to overwrite. Read or
    // inspect follow-ups must remain ordinary continuations until an explicit
    // revision verb is present.
    if (!edit) {
      return WorkFollowUpDecision(
        kind: WorkFollowUpKind.continueTask,
        request: normalizedRequest,
        reason: '未出现文件修订或新建指代。',
      );
    }

    // An explicitly supplied absolute path is stronger than a basename-only
    // checkpoint. Do not let a stale relative artifact entry shadow the path
    // the user just named.
    if (explicitPath != null && _isAbsolutePath(explicitPath)) {
      final exact = artifacts
          .where((path) => path.toLowerCase() == explicitPath.toLowerCase())
          .toList(growable: false);
      if (exact.isEmpty) {
        return WorkFollowUpDecision(
          kind: WorkFollowUpKind.reviseArtifact,
          request: normalizedRequest,
          artifactPath: explicitPath,
          reason: '用户明确给出了修订路径。',
        );
      }
    }

    final matching = _matchingArtifacts(
      normalizedRequest,
      artifacts,
      explicitPath: explicitPath,
    );
    if (matching.length == 1) {
      return WorkFollowUpDecision(
        kind: WorkFollowUpKind.reviseArtifact,
        request: normalizedRequest,
        artifactPath: matching.single,
        reason: '使用结构化 lastArtifactPaths 中唯一匹配的原路径。',
      );
    }
    if (matching.length > 1) {
      return _clarification(
        normalizedRequest,
        matching,
        '存在多个可能的产物，不能猜测覆盖目标。',
      );
    }
    if (explicitPath != null && edit) {
      return WorkFollowUpDecision(
        kind: WorkFollowUpKind.reviseArtifact,
        request: normalizedRequest,
        artifactPath: explicitPath,
        reason: '用户明确给出了修订路径。',
      );
    }
    // “改写到新目标” (and similar ordinary continuation wording) does not
    // identify an existing artifact. Without a file/reference noun, keep the
    // old continuation semantics instead of inventing a clarification stop.
    if (edit && !reference && explicitPath == null) {
      return WorkFollowUpDecision(
        kind: WorkFollowUpKind.continueTask,
        request: normalizedRequest,
        reason: '修订动词未指向既有文件，按普通追问继续。',
      );
    }
    if (artifacts.isEmpty &&
        edit &&
        reference &&
        !_hasFileReferenceWord(normalizedRequest) &&
        explicitPath == null) {
      return WorkFollowUpDecision(
        kind: WorkFollowUpKind.continueTask,
        request: normalizedRequest,
        reason: '时间性结果指代没有结构化文件目标，保留原有连续执行语义。',
      );
    }
    if (edit || reference || explicitPath != null) {
      return _clarification(
        normalizedRequest,
        artifacts,
        artifacts.isEmpty ? '没有可继承的结构化产物路径，必须先确认目标。' : '修订措辞未唯一匹配结构化产物路径。',
      );
    }
    return WorkFollowUpDecision(
      kind: WorkFollowUpKind.continueTask,
      request: normalizedRequest,
    );
  }

  List<String> _paths(Iterable<String> values) {
    final paths = <String>[];
    for (final value in values) {
      final normalized = value.replaceAll('\\', '/').trim();
      if (normalized.isEmpty ||
          _hasControl(normalized) ||
          normalized.split('/').contains('..')) {
        continue;
      }
      if (!paths.any((existing) => _equivalentPath(existing, normalized))) {
        paths.add(normalized);
      }
    }
    return List<String>.unmodifiable(paths);
  }

  bool _equivalentPath(String left, String right) {
    if (left == right) return true;
    final leftAbsolute = _isAbsolutePath(left);
    final rightAbsolute = _isAbsolutePath(right);
    if (leftAbsolute == rightAbsolute) return false;
    final absolute = leftAbsolute ? left : right;
    final relative = leftAbsolute ? right : left;
    return absolute.endsWith('/$relative') ||
        absolute.split('/').last == relative;
  }

  bool _isAbsolutePath(String value) =>
      value.startsWith('/') || RegExp(r'^[A-Za-z]:/').hasMatch(value);

  List<String> _matchingArtifacts(
    String request,
    List<String> artifacts, {
    String? explicitPath,
  }) {
    final lower = request.toLowerCase().replaceAll('\\', '/');
    final fullMatches = <String>[];
    final basenameMatches = <String>[];
    for (final path in artifacts) {
      final normalized = path.toLowerCase();
      final base = normalized.split('/').last;
      final fullMatch = _isAbsolutePath(normalized)
          ? lower.contains(normalized)
          : explicitPath?.toLowerCase() == normalized;
      final baseMatch = base.isNotEmpty && _containsToken(lower, base);
      if (fullMatch) {
        fullMatches.add(path);
      } else if (baseMatch) {
        basenameMatches.add(path);
      }
    }
    final matches = fullMatches.isNotEmpty ? fullMatches : basenameMatches;
    // A bare “当前/上次/同一” is a reference, not a basename. If there is one
    // artifact it is safe; with several artifacts it must be clarified.
    if (matches.isEmpty &&
        artifacts.length == 1 &&
        _hasImplicitReference(request)) {
      return List<String>.from(artifacts);
    }
    return matches;
  }

  String? _explicitPath(String request) {
    final match = RegExp(
      // Keep the leading slash/drive prefix in the capture. A previous
      // basename-only matcher silently treated "修改 /work/report.md" as a
      // generic continuation and could never honor an explicit absolute
      // revision target.
      r'(?<![\w])((?:(?:[A-Za-z]:[\\/])|/)?[\w][\w./\\-]*\.(?:html?|md|markdown|dart|java|txt|'
      r'json|ya?ml|svg|css|js|ts|py|sh|bash|c|cc|cpp|h|hpp|pdf|docx?|xlsx?|'
      r'pptx?|csv|sql|log|png|jpe?g|zip))(?![\w./\\-])',
      caseSensitive: false,
    ).firstMatch(request);
    final value = match?.group(1)?.replaceAll('\\', '/');
    return value == null || value.contains('..') ? null : value;
  }

  bool _hasEditVerb(String request) => RegExp(
        r'(修改|修复|改写|改成|改|调整|优化|完善|更新|替换|覆盖|修订|'
        r'fix|modify|edit|revise|update|change|rewrite|patch)',
        caseSensitive: false,
      ).hasMatch(request);

  bool _hasArtifactReference(String request) => RegExp(
        r'(当前(?:文件|页面|产物)?|上次|上一个|刚才|之前|原文件|现有|这个(?:文件|页面|代码)?|'
        r'该(?:文件|页面|代码)?|同一(?:个)?文件|相同(?:的)?(?:个)?文件|附件|'
        r'\b(?:same|this|that|previous|last|existing|current|attachment)\b)',
        caseSensitive: false,
      ).hasMatch(request);

  bool _hasImplicitReference(String request) => RegExp(
        r'(当前|上次|上一个|刚才|之前|原文件|现有|这个|该|同一|相同|'
        r'\b(?:same|this|that|previous|last|existing|current)\b)',
        caseSensitive: false,
      ).hasMatch(request);

  bool _hasFileReferenceWord(String request) => RegExp(
        r'(文件|页面|代码|产物|附件|file|page|code|artifact|attachment)',
        caseSensitive: false,
      ).hasMatch(request);

  bool _hasNewFileIntent(String request) => RegExp(
        r'(新建|创建|生成(?:一个|一份)?|写一个|做一个|制作一个|实现(?:一个|一份)|另存为|'
        r'\b(?:new|create|generate|make)\b)',
        caseSensitive: false,
      ).hasMatch(request);

  WorkFollowUpDecision _clarification(
    String request,
    List<String> candidates,
    String reason,
  ) {
    final display = candidates.isEmpty
        ? '例如：/workspace/report.md'
        : candidates.map(_displayPath).join('、');
    return WorkFollowUpDecision(
      kind: WorkFollowUpKind.clarification,
      request: request,
      reason: reason,
      clarificationQuestion: '请明确要修改的文件路径（$display）？',
    );
  }

  String _displayPath(String path) {
    final normalized = path.replaceAll('\\', '/');
    return normalized.split('/').last.isEmpty
        ? normalized
        : normalized.split('/').last;
  }

  bool _containsToken(String text, String token) {
    if (token.isEmpty) return false;
    final escaped = RegExp.escape(token);
    return RegExp('(?<![\\w.-])$escaped(?![\\w.-])', caseSensitive: false)
        .hasMatch(text);
  }

  bool _hasControl(String value) =>
      value.contains(RegExp(r'[\u0000-\u001f\u007f]'));
}

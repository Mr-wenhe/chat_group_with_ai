import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/document/binary_document_parser.dart';
import 'package:chat_group/features/work_mode/work_discussion_state.dart';
import 'package:chat_group/features/work_mode/workspace_path_policy.dart';

/// Result of the final artifact contract check.
class WorkArtifactValidationResult {
  final bool valid;
  final String code;
  final String message;

  /// The first validated deliverable, kept for callers that need one path.
  final String? path;

  /// Every candidate that satisfied the contract this run. An ordinary task
  /// leaves this empty (it declares no file contract), while an artifact task
  /// reports all of its deliverables so delivery can ignore the intermediate
  /// files the same run also wrote.
  final List<String> deliveredPaths;

  /// Whether the request carried a file contract at all.
  final bool requiresArtifact;

  const WorkArtifactValidationResult.valid({
    this.path,
    this.deliveredPaths = const <String>[],
    this.requiresArtifact = false,
  })  : valid = true,
        code = 'ok',
        message = '交付产物已通过格式、位置、可读性和正文校验。';

  const WorkArtifactValidationResult.invalid(this.code, this.message)
      : valid = false,
        path = null,
        deliveredPaths = const <String>[],
        // A missing deliverable is still an artifact contract.
        requiresArtifact = true;
}

/// Completion guard for file deliverables in production work mode.
///
/// WorkAgentLoop never turns model prose into an attachment. A requested file
/// must be a real file recorded by the current task before completion can be
/// published.
class WorkArtifactDeliveryGuard {
  const WorkArtifactDeliveryGuard._();

  static const int maxValidatedDocxBytes = 10 * 1024 * 1024;
  static const int maxValidatedHtmlBytes = 10 * 1024 * 1024;
  static const Duration fileFreshnessTolerance = Duration(seconds: 2);

  static const String missingArtifactMessage =
      '用户要求文件产物，但没有可读取的真实文件；未将说明文字伪装成附件。'
      '请通过 workspace.patch 或 command.run 写入并核对文件后再完成。';

  static const String docxContractMessage =
      '用户明确要求 Word 文件，但没有找到本次生成、位于指定位置且可读取的真实 DOCX。'
      'Markdown 只能作为转换源，不能作为最终交付。';

  static const String htmlContractMessage =
      'HTML 产物必须是真实、可读取且包含完整 html/body 结构的文件；未将说明文字伪装成附件。';

  static const String unchangedRevisionMessage =
      '修订任务没有检测到目标文件内容变化，未将未修改的原文件标记为完成。';

  /// Returns whether [request] asks for a source-code file rather than merely
  /// asking the model to explain or review code.
  static bool requiresSourceArtifact(String request) {
    final text = request.trim().toLowerCase();
    if (text.isEmpty) return false;

    final source = RegExp(
      r'(?:\.(?:py|py3|js|jsx|ts|tsx|dart|java|kt|kts|swift|rs|go|rb|php|'
      r'c|cc|cpp|cxx|h|hpp|sh|bash|zsh|fish|sql)\b|'
      r'python|javascript|typescript|dart|java|kotlin|swift|rust|golang|'
      r'ruby|php|c\+\+|\bc\b|shell|bash|sql|html5?|网页|页面|源码|代码|脚本)',
      caseSensitive: false,
    ).hasMatch(text);
    if (!source) return false;

    return _containsCreationVerb(text);
  }

  /// Word is a distinct final format. A durable discussion contract keeps the
  /// requirement through terse continuations, while opening or reviewing an
  /// existing DOCX remains analysis.
  static bool requiresDocxArtifact(String request, {String? contractFormat}) {
    final format = contractFormat?.trim().toLowerCase();
    if (format == 'docx') {
      final text = request.trim().toLowerCase();
      if (text.isEmpty) return true;
      // A durable discussion contract survives terse continuations such as
      // “继续执行”. Keep the review/opening escape hatch, but do not let a
      // follow-up that omits the format silently downgrade the final output.
      return !_isReadOnlyDocumentRequest(text) || _containsCreationVerb(text);
    }
    final text = request.trim().toLowerCase();
    if (text.isEmpty || !_containsCreationVerb(text)) return false;
    return RegExp(
      r'(?:\bword\b|\bdocx?\b|word\s*文档|word\s*格式|docx?\s*文档|'
      r'\.docx?\b)',
      caseSensitive: false,
    ).hasMatch(text);
  }

  /// Returns the normalized final format recorded by the current discussion
  /// contract. Callers that reject text-only writes must use this value in
  /// addition to parsing the free-form request, because the discussion may
  /// have already resolved a format the request text does not repeat.
  static String? contractFormatForTask(AgentTask task) {
    final format =
        _contractFor(task)?['format']?.toString().trim().toLowerCase();
    return format == null || format.isEmpty ? null : format;
  }

  static bool isRevisionTask(AgentTask task) =>
      _decodeExecution(task.executionStateJson)['followUpKind'] ==
      'reviseArtifact';

  /// Returns whether a request asks for a non-source file. Read/review
  /// requests remain ordinary analysis.
  ///
  /// The Office family and PDF belong here even though they are binary: a
  /// workbook or slide deck is a deliverable the user has to receive as a file
  /// just like a Markdown document. Leaving them out made “生成一份 xlsx 排名表”
  /// count as a request with no artifact contract, so its completion was never
  /// validated against a real file.
  static bool requiresFileArtifact(String request) {
    final text = request.trim().toLowerCase();
    if (text.isEmpty || !_containsCreationVerb(text)) return false;
    return RegExp(
      r'(?:文件|文档|报告|报表|清单|表格|附件|markdown|md文档|'
      r'\bword\b|\bdocx?\b|\bxlsx?\b|\bpptx?\b|\bpdf\b|'
      r'html5?|网页|页面|网站|前端|'
      r'\.(?:md|markdown|txt|csv|json|ya?ml|html?|docx?|xlsx?|pptx?|pdf)\b)',
      caseSensitive: false,
    ).hasMatch(text);
  }

  static bool _containsCreationVerb(String text) => RegExp(
        r'(?:生成|创建|新建|写入|保存|导出|输出|编写|实现|开发|修改|修复|'
        r'更新|重构|制作|转换|转成|转为|generate|create|write|save|export|'
        r'output|implement|develop|modify|fix|update|refactor|convert|build|'
        r'make)',
        caseSensitive: false,
      ).hasMatch(text);

  static bool _isReadOnlyDocumentRequest(String text) => RegExp(
        r'(?:读取|读一下|查看|打开|分析|解析|检查|预览|阅读|展示|'
        r'\b(?:read|open|review|inspect|analy[sz]e|check|preview)\b)',
        caseSensitive: false,
      ).hasMatch(text);

  /// Validates durable artifact paths for the active task. A path must be
  /// inside the current path policy, be a regular file, and have a
  /// modification timestamp at or after this run. Word additionally requires
  /// a bounded, structurally valid DOCX with non-empty body text. Resuming
  /// the same logical task must not make its already-generated artifact stale.
  static Future<WorkArtifactValidationResult> validateTask({
    required AgentTask task,
    required WorkspacePathPolicy pathPolicy,
    String? workspaceRoot,
    DateTime? now,
  }) async {
    final contract = _contractFor(task);
    final needsDocx = requiresDocxArtifact(
      task.userRequest,
      contractFormat: contract?['format']?.toString(),
    );
    final needsFile = needsDocx ||
        isRevisionTask(task) ||
        requiresSourceArtifact(task.userRequest) ||
        requiresFileArtifact(task.userRequest);
    if (!needsFile) {
      return const WorkArtifactValidationResult.valid();
    }
    if (task.lastArtifactPaths.isEmpty) {
      return WorkArtifactValidationResult.invalid(
        needsDocx ? 'docxMissing' : 'artifactMissing',
        needsDocx ? docxContractMessage : missingArtifactMessage,
      );
    }

    final revisionFailure = _revisionChangeFailure(task);
    if (revisionFailure != null) {
      return WorkArtifactValidationResult.invalid(
        'artifactUnchanged',
        revisionFailure,
      );
    }

    final effectiveWorkspaceRoot = await _resolveWorkspaceRoot(
      workspaceRoot,
      isWindows: pathPolicy.isWindows,
    );
    final freshAfter = task.createdAt.subtract(fileFreshnessTolerance);
    final checkedAt = now ?? DateTime.now();
    final declaredFormats = declaredOutputFormats(task);
    // A run legitimately writes intermediate files next to its deliverable (a
    // script, a data dump, a conversion source). Every candidate is therefore
    // validated against the contract and the accepted ones are returned, so
    // callers can deliver the deliverables without guessing from the paths that
    // happened to change.
    final validatedPaths = <String>[];
    for (final rawPath in task.lastArtifactPaths.take(64)) {
      final raw = rawPath.trim();
      if (raw.isEmpty) continue;
      try {
        final lookupPath = _artifactLookupPath(
          raw,
          effectiveWorkspaceRoot,
          isWindows: pathPolicy.isWindows,
        );
        final resolved = await pathPolicy.resolveExisting(lookupPath);
        final requestedType = await FileSystemEntity.type(
          lookupPath,
          followLinks: false,
        );
        // WorkspacePathPolicy may report a harmless parent alias such as
        // macOS /var -> /private/var. Reject only an explicitly linked final
        // component, matching the attachment delivery boundary.
        if (!resolved.isFile ||
            requestedType == FileSystemEntityType.link ||
            resolved.isLink) {
          continue;
        }
        final file = File(resolved.path);
        final stat = await file.stat();
        if (stat.type != FileSystemEntityType.file ||
            stat.modified.isBefore(freshAfter) ||
            stat.modified.isAfter(checkedAt.add(fileFreshnessTolerance))) {
          continue;
        }
        if (!await _matchesContractLocation(
          contract,
          resolved,
          pathPolicy,
          workspaceRoot: effectiveWorkspaceRoot,
        )) {
          continue;
        }
        if (needsDocx) {
          if (!_hasExtension(resolved.path, 'docx') ||
              stat.size <= 0 ||
              stat.size > maxValidatedDocxBytes) {
            continue;
          }
          final bytes = await file.readAsBytes();
          final sections = BinaryDocumentParser.validateDocxForDelivery(
            Uint8List.fromList(bytes),
          );
          if (sections.isEmpty) continue;
          // Prose in contentScope is not a literal checklist: conjunctions,
          // synonyms and workflow instructions cannot define hard failures.
          // Content acceptance belongs to the executor's discussion contract.
        }
        if (_isHtmlPath(resolved.path)) {
          if (stat.size <= 0 || stat.size > maxValidatedHtmlBytes) continue;
          final bytes = await file.readAsBytes();
          if (!_isCompleteHtml(bytes)) continue;
        }
        if (declaredFormats.isNotEmpty &&
            !declaredFormats.any(
              (format) => _matchesDeclaredFormat(resolved.path, format),
            )) {
          continue;
        }
        validatedPaths.add(resolved.path);
        continue;
      } on Object {
        // A malformed or unauthorized candidate must not make another
        // candidate appear valid; raw filesystem details stay private.
        continue;
      }
    }
    if (validatedPaths.isNotEmpty) {
      return WorkArtifactValidationResult.valid(
        path: validatedPaths.first,
        deliveredPaths: List<String>.unmodifiable(validatedPaths),
        requiresArtifact: true,
      );
    }
    return WorkArtifactValidationResult.invalid(
      needsDocx
          ? 'docxInvalidOrStale'
          : task.userRequest.toLowerCase().contains('html')
              ? 'htmlInvalidOrStale'
              : 'artifactInvalidOrStale',
      needsDocx
          ? docxContractMessage
          : task.userRequest.toLowerCase().contains('html')
              ? htmlContractMessage
              : missingArtifactMessage,
    );
  }

  static String? failureFor({
    required String request,
    required bool hasReadableArtifact,
    String? contractFormat,
  }) {
    final needsDocx = requiresDocxArtifact(
      request,
      contractFormat: contractFormat,
    );
    if ((!needsDocx &&
            !requiresSourceArtifact(request) &&
            !requiresFileArtifact(request)) ||
        hasReadableArtifact) {
      return null;
    }
    return needsDocx ? docxContractMessage : missingArtifactMessage;
  }

  static Map<String, dynamic>? _contractFor(AgentTask task) {
    final decoded = WorkDiscussionState.decodeExecutionState(
      task.executionStateJson,
    );
    final contract = decoded.state?.deliverableContract;
    return contract == null ? null : Map<String, dynamic>.from(contract);
  }

  static Future<String?> _resolveWorkspaceRoot(
    String? raw, {
    required bool isWindows,
  }) async {
    final value = raw?.trim();
    if (value == null || value.isEmpty) return null;
    try {
      final resolved = await Directory(value).resolveSymbolicLinks();
      return WorkspacePathPolicy.normalizePath(
        resolved,
        isWindows: isWindows,
      );
    } on Object {
      try {
        return WorkspacePathPolicy.normalizePath(value, isWindows: isWindows);
      } on Object {
        return null;
      }
    }
  }

  static Future<bool> _matchesContractLocation(
    Map<String, dynamic>? contract,
    WorkspaceResolvedPath resolved,
    WorkspacePathPolicy pathPolicy, {
    String? workspaceRoot,
  }) async {
    final location = _normalizeContractLocation(
      contract?['location']?.toString().trim() ?? '',
    );
    final lowerLocation = location.toLowerCase();
    if (location.isEmpty || lowerLocation == 'unspecified') {
      return true;
    }
    if (location.split(RegExp(r'[\\/]')).contains('..')) return false;
    try {
      final normalizedActual = WorkspacePathPolicy.normalizePath(
        resolved.path,
        isWindows: pathPolicy.isWindows,
      );
      // Public discussion/event sanitization can replace an explicit output
      // path with a redaction token before the contract is persisted. The
      // token is not a usable filename; rely on the already-authorized
      // workspace boundary and the fresh DOCX checks instead of comparing it
      // literally with the generated artifact.
      if (_isRedactedLocation(location)) {
        final root = workspaceRoot?.trim();
        return root == null || root.isEmpty
            ? true
            : WorkspacePathPolicy.isWithinRoot(
                root,
                normalizedActual,
                isWindows: pathPolicy.isWindows,
              );
      }
      final absolute = _isAbsolute(location, pathPolicy.isWindows);
      if (lowerLocation == 'desktop') {
        final root = workspaceRoot?.trim();
        // The runner binds an explicit desktop request to the selected
        // desktop workspace. When that durable root is available, require the
        // artifact to remain inside it; the fallback keeps direct guard tests
        // and legacy callers compatible with their authorized-root fixture.
        return root == null || root.isEmpty
            ? true
            : WorkspacePathPolicy.isWithinRoot(
                root,
                normalizedActual,
                isWindows: pathPolicy.isWindows,
              );
      }
      final relativeLocation = _desktopPrefixedRelativePath(
        _stripProjectPrefix(location),
      );
      final baseRoot = workspaceRoot?.trim().isNotEmpty == true
          ? workspaceRoot!.trim()
          : resolved.authorizedRoot;
      final expected = absolute
          ? await _normalizeExistingContractPath(
              location,
              isWindows: pathPolicy.isWindows,
            )
          : WorkspacePathPolicy.normalizePath(
              '$baseRoot/${relativeLocation.replaceAll('\\', '/')}',
              isWindows: pathPolicy.isWindows,
            );
      // Discussion contracts may name a directory (for example, “项目下
      // doc/需求优化文档/”) instead of inventing a filename. Accept only
      // files inside that existing directory; explicit file paths remain an
      // exact match.
      final lastSegment = location.replaceAll('\\', '/').split('/').last;
      final locationLooksLikeFile =
          RegExp(r'\.[^./\\]+$').hasMatch(lastSegment);
      final locationIsDirectory =
          location.replaceAll('\\', '/').endsWith('/') ||
              !locationLooksLikeFile && await Directory(expected).exists();
      return locationIsDirectory
          ? WorkspacePathPolicy.isWithinRoot(
              expected,
              normalizedActual,
              isWindows: pathPolicy.isWindows,
            )
          : normalizedActual == expected;
    } on Object {
      return false;
    }
  }

  static Future<String> _normalizeExistingContractPath(
    String path, {
    required bool isWindows,
  }) async {
    try {
      // macOS exposes aliases such as /var -> /private/var. Resolve an
      // existing absolute contract path before comparing it with the path
      // policy's canonical candidate, while retaining lexical normalization
      // for a path that disappeared between validation steps.
      final resolved = await File(path).resolveSymbolicLinks();
      return WorkspacePathPolicy.normalizePath(resolved, isWindows: isWindows);
    } on Object {
      return WorkspacePathPolicy.normalizePath(path, isWindows: isWindows);
    }
  }

  static bool _isAbsolute(String value, bool isWindows) =>
      value.startsWith('/') ||
      isWindows && RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value);

  static String _desktopPrefixedRelativePath(String location) {
    final normalized = location.replaceAll('\\', '/');
    final match = RegExp(
      r'^(?:桌面|desktop)(?:/|$)',
      caseSensitive: false,
    ).matchAsPrefix(normalized);
    if (match == null) return location;
    final remainder = normalized.substring(match.end);
    return remainder.isEmpty ? 'desktop' : remainder;
  }

  static String _stripProjectPrefix(String location) {
    final normalized = location.replaceAll('\\', '/');
    return normalized.replaceFirst(
      RegExp(r'^项目(?:下|内)(?:/)?', caseSensitive: false),
      '',
    );
  }

  static String _normalizeContractLocation(String location) {
    // Discussion summaries may append a non-path confirmation note to the
    // durable directory contract. Keep the filesystem check strict while
    // removing only this known workflow annotation.
    return location
        .replaceFirst(
          RegExp(r'[（(]待群内最终确认[）)]\s*$', caseSensitive: false),
          '',
        )
        .trim();
  }

  static String _artifactLookupPath(
    String raw,
    String? workspaceRoot, {
    required bool isWindows,
  }) {
    if (_isAbsolute(raw, isWindows) ||
        workspaceRoot == null ||
        workspaceRoot.trim().isEmpty) {
      return raw;
    }
    // Preserve traversal segments for WorkspacePathPolicy to reject. Folding
    // `..` here would hide the boundary violation before authorization runs.
    return '${workspaceRoot.trim()}/${raw.replaceAll('\\', '/')}';
  }

  /// Output formats the request (or the durable discussion contract) names
  /// explicitly, as canonical file extensions without the dot.
  ///
  /// A request that names a format must be delivered in that format: without
  /// this check an intermediate file satisfies the presence contract, so
  /// “生成一份 xlsx 排名表” auto-completed as soon as its generator script was
  /// written.
  static Set<String> declaredOutputFormats(AgentTask task) {
    // A durable discussion contract is authoritative. A “Markdown 转 Word” task
    // must deliver only the DOCX, not also the Markdown it converted from.
    final contractFormat = contractFormatForTask(task);
    if (contractFormat != null) {
      final canonical = _canonicalFormat(contractFormat);
      if (canonical != null) return <String>{canonical};
    }
    final formats = <String>{};
    // Users write the format either bare (“一份 xlsx 表”) or as an extension
    // (“ranking.xlsx”), so both spellings have to be recognised. The extension
    // group is restricted to known formats: a generic `\.\w+` also matched
    // version numbers such as “v2.10” and produced the format “10”.
    for (final match in RegExp(
      r'\b(markdown|xlsx?|docx?|pptx?|pdf|html5?|csv|json|ya?ml|txt|word)\b|'
      r'\.(md|markdown|txt|csv|json|ya?ml|html?|docx?|xlsx?|pptx?|pdf)\b',
      caseSensitive: false,
    ).allMatches(task.userRequest)) {
      final raw = (match.group(1) ?? match.group(2))?.toLowerCase();
      if (raw == null || raw.isEmpty) continue;
      final canonical = _canonicalFormat(raw);
      if (canonical != null) formats.add(canonical);
    }
    return formats;
  }

  /// Maps every spelling used by the request parser, the discussion contract and
  /// the user's own wording onto one extension. Returns null for a word that is
  /// not an output format at all.
  static String? _canonicalFormat(String raw) => switch (raw.toLowerCase()) {
        'word' || 'doc' || 'docx' => 'docx',
        'xls' || 'xlsx' => 'xlsx',
        'ppt' || 'pptx' => 'pptx',
        'markdown' || 'md' => 'md',
        'html' || 'html5' || 'htm' => 'html',
        'yml' || 'yaml' => 'yaml',
        'pdf' || 'csv' || 'json' || 'txt' => raw.toLowerCase(),
        _ => null,
      };

  /// Whether a file satisfies one canonical format. `docx` also accepts the
  /// legacy `.doc`, and `html` accepts `.htm`, because both spellings are the
  /// same deliverable to the user.
  static bool _matchesDeclaredFormat(String path, String format) {
    if (_hasExtension(path, format)) return true;
    return switch (format) {
      'docx' => _hasExtension(path, 'doc'),
      'html' => _hasExtension(path, 'htm'),
      _ => false,
    };
  }

  static bool _hasExtension(String path, String extension) =>
      path.replaceAll('\\', '/').toLowerCase().endsWith('.$extension');

  static bool _isRedactedLocation(String location) =>
      location.contains('[REDACTED]') || location.contains('[本地路径]');

  static bool _isHtmlPath(String path) =>
      RegExp(r'\.html?$', caseSensitive: false).hasMatch(path);

  static bool _isCompleteHtml(List<int> bytes) {
    final text = String.fromCharCodes(bytes).toLowerCase();
    final htmlOpen = RegExp(r'<html\b').firstMatch(text)?.start ?? -1;
    final bodyOpen = RegExp(r'<body\b').firstMatch(text)?.start ?? -1;
    final bodyClose = RegExp(r'</body\s*>').firstMatch(text)?.start ?? -1;
    final htmlClose = RegExp(r'</html\s*>').firstMatch(text)?.start ?? -1;
    return htmlOpen >= 0 &&
        bodyOpen > htmlOpen &&
        bodyClose > bodyOpen &&
        htmlClose > bodyClose;
  }

  static String? _revisionChangeFailure(AgentTask task) {
    final execution = _decodeExecution(task.executionStateJson);
    if (execution['followUpKind'] != 'reviseArtifact') return null;
    final target = execution['revisionTargetPath']?.toString().trim() ?? '';
    final rawChanges = execution['artifactChanges'];
    if (rawChanges is! Map) return unchangedRevisionMessage;
    for (final entry in rawChanges.entries) {
      final path = entry.key.toString();
      if (target.isNotEmpty && !_equivalentPath(path, target)) continue;
      if (entry.value is Map && (entry.value as Map)['changed'] == true) {
        return null;
      }
    }
    return unchangedRevisionMessage;
  }

  static Map<String, dynamic> _decodeExecution(String raw) {
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
    } on Object {
      return {};
    }
  }

  static bool _equivalentPath(String left, String right) {
    final a = left.replaceAll('\\', '/').toLowerCase();
    final b = right.replaceAll('\\', '/').toLowerCase();
    return a == b || a.endsWith('/$b') || b.endsWith('/$a');
  }
}

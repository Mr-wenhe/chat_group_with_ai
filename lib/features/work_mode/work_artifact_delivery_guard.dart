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

  /// The largest deliverable the guard will validate.
  ///
  /// This mirrors the ceiling for a single chat attachment rather than sitting
  /// below it: a 10 MB ceiling rejected real deliverables whose size was never
  /// the user's problem — an HTML report with embedded images, for instance.
  /// Reading and parsing stays bounded, and the archive parsers in
  /// [BinaryDocumentParser] keep their own expansion limits.
  static const int maxValidatedDocxBytes = 50 * 1024 * 1024;
  static const int maxValidatedHtmlBytes = 50 * 1024 * 1024;
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
  ///
  /// A bare language name is the only ambiguous signal; see
  /// [_mentionsSourceArtifact] for how “生成一份 Python 学习报告” stays a
  /// document request.
  static bool requiresSourceArtifact(String request) {
    final text = request.trim().toLowerCase();
    if (text.isEmpty) return false;
    if (!_mentionsSourceArtifact(text)) return false;

    return _containsCreationVerb(text);
  }

  /// Whether [text] asks for source code rather than a document about some
  /// language.
  ///
  /// An extension (`main.dart`) or a source noun (`脚本`, `页面`) names the
  /// artefact itself, so it always counts. A bare language name (`Python`) does
  /// not: “生成一份 Python 学习报告” asks for a report, and reading `Python` as a
  /// source signal let its generator script stand in for that report.
  static bool _mentionsSourceArtifact(String text) =>
      _sourceExtension.hasMatch(text) ||
      !_documentArtifactNoun.hasMatch(text) &&
          (_sourceArtifactNoun.hasMatch(text) ||
              _bareSourceFormatWord.hasMatch(text));

  /// A source file named by its extension, in any alias spelling.
  static final RegExp _sourceExtension = RegExp(
    r'\.(?:py|py3|pyw|ipynb|js|mjs|cjs|jsx|ts|tsx|dart|java|kt|kts|'
    r'swift|rs|go|rb|php|c|cc|cpp|cxx|h|hpp|sh|bash|zsh|fish|sql)\b',
    caseSensitive: false,
  );

  /// A noun that names the artefact itself, so the source reading is explicit.
  static final RegExp _sourceArtifactNoun = RegExp(
    r'(?:网页|页面|源码|代码|脚本)',
    caseSensitive: false,
  );

  /// A format or language written as a word rather than as an extension.
  static final RegExp _bareSourceFormatWord = RegExp(
    r'(?:python|javascript|typescript|dart|java|kotlin|swift|rust|golang|'
    r'ruby|php|c\+\+|\bc\b|shell|bash|sql|html5?)',
    caseSensitive: false,
  );

  /// A noun that names a document deliverable. A language name next to one of
  /// these is the document's subject, not its format.
  static final RegExp _documentArtifactNoun = RegExp(
    r'(?:报告|文档|报表|表格|清单|说明|总结|教程|课件|笔记|方案|手册|'
    r'指南|纪要|论文|简历|讲义)',
    caseSensitive: false,
  );

  /// Word is a distinct final format. A durable discussion contract keeps the
  /// requirement through terse continuations, while opening or reviewing an
  /// existing DOCX remains analysis.
  static bool requiresDocxArtifact(String request, {String? contractFormat}) {
    final rawFormat = contractFormat?.trim().toLowerCase();
    final format = rawFormat == null ? null : _canonicalFormat(rawFormat);
    if (format != null && format != 'docx') return false;
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

  /// Canonical formats that are source code rather than a deliverable.
  ///
  /// A run normally writes a generator script next to its deliverable, so a
  /// source file must never be accepted in place of the requested output:
  /// “生成一份分析报告” delivered `build_report.py`, because a contract without
  /// a named format accepted any fresh file.
  static const Set<String> sourceFormats = <String>{
    'py',
    'ipynb',
    'js',
    'jsx',
    'ts',
    'tsx',
    'dart',
    'java',
    'kt',
    'swift',
    'rs',
    'go',
    'rb',
    'php',
    'c',
    'cpp',
    'h',
    'hpp',
    'sh',
    'sql',
  };

  /// Whether [path] is source code rather than a deliverable document.
  ///
  /// The extension is normalized through [formatAliases] first: `.mjs`, `.cjs`,
  /// `.pyw` or `.bash` are the same source file as `.js`, `.py` or `.sh`, and
  /// matching their raw spelling let a generator script stand in for the
  /// requested deliverable.
  static bool isSourceArtifactPath(String path) {
    final extension = extensionOf(path);
    if (extension == null) return false;
    return isSourceFormat(formatAliases[extension] ?? extension);
  }

  /// Whether a canonical format is source code rather than a deliverable.
  static bool isSourceFormat(String format) => sourceFormats.contains(format);

  /// The lowercase extension of [path] without its dot, or null when the name
  /// carries none.
  static String? extensionOf(String path) {
    final name = path.replaceAll('\\', '/').split('/').last;
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return null;
    return name.substring(dot + 1).toLowerCase();
  }

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
    // Whether a contract exists is a deliberately broad question: a request
    // that mentions a format in passing (“生成一份报告，包含 png 图表”) still has
    // to deliver a real file. What keeps that mention from over-constraining
    // the output is [_formatsNamedBy], which is the narrower scan used for the
    // format filter. Answering this question with that narrower scan dropped
    // the contract for “把 notes.txt 更新为 v2” and silently disabled
    // auto-completion for the file it had just written.
    if (_mentionsAnyFormat(text)) return true;
    // A request can ask for a file without naming any format at all
    // (“生成一份报告”). Those still carry a contract; only the format filter is
    // unavailable, so the source rule has to keep the generator script out.
    return RegExp(
      r'(?:文件|文档|报告|报表|清单|表格|附件|markdown|md文档)',
      caseSensitive: false,
    ).hasMatch(text);
  }

  /// Whether the request mentions any recognised format at all, however it is
  /// introduced.
  ///
  /// A token that doubles as an ordinary word still counts only in its
  /// extension form, so “生成一段 c 语言的说明文字” stays an ordinary answer
  /// rather than becoming a file task.
  static bool _mentionsAnyFormat(String text) {
    for (final match in RegExp(r'[a-z0-9]+').allMatches(text)) {
      final token = match.group(0)!;
      if (!formatAliases.containsKey(token)) continue;
      final isExtension = match.start > 0 && text[match.start - 1] == '.';
      if (!isExtension && _ambiguousBareTokens.contains(token)) continue;
      return true;
    }
    return _cjkFormatAliases.keys.any(text.contains) ||
        _cjkCategoryAliases.keys.any(text.contains);
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
    final request = WorkDiscussionState.currentRequestScope(task);
    final needsDocx = requiresDocxArtifact(
      request,
      contractFormat: contract?['format']?.toString(),
    );
    final needsFile = needsDocx ||
        isRevisionTask(task) ||
        requiresSourceArtifact(request) ||
        requiresFileArtifact(request);
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
    // A contract only a source request may be satisfied by source code. Every
    // other contract has to receive a real deliverable: “生成一份分析报告” used to
    // deliver `build_report.py`, because a request that names no format left the
    // presence contract with nothing to check.
    final sourceMayStandIn = requiresSourceArtifact(request) &&
        declaredFormats.every(isSourceFormat);
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
        if (!sourceMayStandIn && isSourceArtifactPath(resolved.path)) {
          continue;
        }
        if (needsDocx) {
          if (extensionOf(resolved.path) != 'docx' ||
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
          : request.toLowerCase().contains('html')
              ? 'htmlInvalidOrStale'
              : 'artifactInvalidOrStale',
      needsDocx
          ? docxContractMessage
          : request.toLowerCase().contains('html')
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

  /// Every spelling a request can use for a deliverable format, mapped onto one
  /// canonical format.
  ///
  /// Keys are an extension without its dot, a format word, or a language name.
  /// Spellings inside one family share a canonical value, because they are the
  /// same deliverable to the user: a Word request is satisfied by `.docx`,
  /// `.doc` or `.docm`, and a web-page request by `.html` or `.htm`.
  static const Map<String, String> formatAliases = <String, String>{
    'markdown': 'md',
    'md': 'md',
    'txt': 'txt',
    'csv': 'csv',
    'tsv': 'tsv',
    'json': 'json',
    'yaml': 'yaml',
    'yml': 'yaml',
    'xml': 'xml',
    'html': 'html',
    'html5': 'html',
    'htm': 'html',
    'word': 'docx',
    'doc': 'docx',
    'docx': 'docx',
    'docm': 'docx',
    'excel': 'xlsx',
    'xls': 'xlsx',
    'xlsx': 'xlsx',
    'xlsm': 'xlsx',
    'powerpoint': 'pptx',
    'ppt': 'pptx',
    'pptx': 'pptx',
    'pptm': 'pptx',
    'pdf': 'pdf',
    'png': 'png',
    'apng': 'png',
    'jpg': 'jpg',
    'jpeg': 'jpg',
    'jpe': 'jpg',
    'gif': 'gif',
    'webp': 'webp',
    'svg': 'svg',
    'bmp': 'bmp',
    'ico': 'ico',
    'tif': 'tiff',
    'tiff': 'tiff',
    'heic': 'heic',
    'mp3': 'mp3',
    'wav': 'wav',
    'm4a': 'm4a',
    'aac': 'aac',
    'flac': 'flac',
    'ogg': 'ogg',
    'mp4': 'mp4',
    'mov': 'mov',
    'avi': 'avi',
    'mkv': 'mkv',
    'webm': 'webm',
    'zip': 'zip',
    'tar': 'tar',
    'gz': 'gz',
    '7z': '7z',
    'rar': 'rar',
    'epub': 'epub',
    'mobi': 'mobi',
    'rtf': 'rtf',
    'odt': 'odt',
    'ods': 'ods',
    'odp': 'odp',
    'python': 'py',
    'py': 'py',
    'py3': 'py',
    'pyw': 'py',
    'ipynb': 'ipynb',
    'javascript': 'js',
    'js': 'js',
    'mjs': 'js',
    'cjs': 'js',
    'jsx': 'jsx',
    'typescript': 'ts',
    'ts': 'ts',
    'tsx': 'tsx',
    'dart': 'dart',
    'java': 'java',
    'kotlin': 'kt',
    'kt': 'kt',
    'kts': 'kt',
    'swift': 'swift',
    'rust': 'rs',
    'rs': 'rs',
    'golang': 'go',
    'go': 'go',
    'ruby': 'rb',
    'rb': 'rb',
    'php': 'php',
    'c': 'c',
    'cc': 'cpp',
    'cpp': 'cpp',
    'cxx': 'cpp',
    'h': 'h',
    'hpp': 'hpp',
    'shell': 'sh',
    'bash': 'sh',
    'sh': 'sh',
    'zsh': 'sh',
    'fish': 'sh',
    'sql': 'sql',
  };

  /// Spellings that do name a format but are ordinary words far more often.
  /// They count only in their extension form (`.go`, `.c`).
  static const Set<String> _ambiguousBareTokens = <String>{
    'c',
    'cc',
    'h',
    'sh',
    'go',
    'rs',
  };

  /// Chinese spellings that name a deliverable format without an extension.
  static const Map<String, String> _cjkFormatAliases = <String, String>{
    '幻灯片': 'pptx',
    '演示文稿': 'pptx',
  };

  /// Chinese category words that only imply a format.
  ///
  /// “前端” and “页面” describe a kind of deliverable rather than naming one, so
  /// they never override an explicitly named format: “生成一个 TSX 前端页面” has
  /// to deliver `App.tsx`, and an inferred `html` constraint excluded it.
  static const Map<String, String> _cjkCategoryAliases = <String, String>{
    '网页': 'html',
    '页面': 'html',
    '网站': 'html',
    '前端': 'html',
  };

  /// Introducers that mark the following token as an input, a conversion source
  /// or a piece of the deliverable's content, rather than its format.
  static final RegExp _ingredientIntroducer = RegExp(
    r'(?:包含|包括|含|附上|附带|带上|带有|加入|嵌入|插入|参考|依据|基于|'
    r'读取|读|打开|分析|解析|结合|使用|利用|把|将|用|以|从|由|按|根据)\s*$',
  );

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
    return _formatsNamedBy(WorkDiscussionState.currentRequestScope(task));
  }

  /// Formats the request names as an output.
  ///
  /// Users write a format either bare (“一份 xlsx 表”) or as an extension
  /// (“ranking.xlsx”), so both spellings count. Only the alias table decides
  /// what a token means, which is what keeps a version number such as “v2.10”
  /// from being read as the format “10”. Two kinds of mention are still not an
  /// output: a token the alias table knows only as an extension (a bare `go` or
  /// `c` is ordinary prose), and a token introduced as an ingredient —
  /// “生成一份报告，包含 png 图表”, “把 chart.png 转成 pdf”. Treating either as
  /// the deliverable's format rejects the very file the user asked for.
  static Set<String> _formatsNamedBy(String request) {
    final text = request.toLowerCase();
    final formats = <String>{};
    for (final match in RegExp(r'[a-z0-9]+').allMatches(text)) {
      final token = match.group(0)!;
      final canonical = formatAliases[token];
      if (canonical == null) continue;
      final isExtension = match.start > 0 && text[match.start - 1] == '.';
      if (!isExtension && _ambiguousBareTokens.contains(token)) continue;
      // A bare language name is only the deliverable's format when the request
      // asks for source code at all: “生成一份 Python 学习报告” delivers a
      // report, and constraining it to {py} rejected that report.
      if (!isExtension &&
          isSourceFormat(canonical) &&
          !_mentionsSourceArtifact(text)) {
        continue;
      }
      // The introducer governs the whole mention. For `chart.png` that means
      // reading backwards past the file name, not just past the extension:
      // “把 chart.png 转成 pdf” introduces a source file, not a PNG output.
      var mentionStart = match.start;
      if (isExtension) {
        while (mentionStart > 0 &&
            _fileNameCharacters.hasMatch(text[mentionStart - 1])) {
          mentionStart--;
        }
      }
      if (_ingredientIntroducer.hasMatch(text.substring(0, mentionStart))) {
        continue;
      }
      formats.add(canonical);
    }
    for (final entry in _cjkFormatAliases.entries) {
      final index = text.indexOf(entry.key);
      if (index < 0) continue;
      if (_ingredientIntroducer.hasMatch(text.substring(0, index))) continue;
      formats.add(entry.value);
    }
    // Category words are a fallback, not a second constraint: they apply only
    // when the request names no format of its own and does not ask for a
    // document about the category (“生成一份网页性能分析报告” delivers a report,
    // and an inferred `html` constraint rejected it).
    if (formats.isEmpty && !_documentArtifactNoun.hasMatch(text)) {
      for (final entry in _cjkCategoryAliases.entries) {
        final index = text.indexOf(entry.key);
        if (index < 0) continue;
        if (_ingredientIntroducer.hasMatch(text.substring(0, index))) continue;
        formats.add(entry.value);
      }
    }
    return formats;
  }

  /// Characters that can belong to a file name, used to find where a mention
  /// carrying an extension actually starts.
  static final RegExp _fileNameCharacters = RegExp(r'[a-z0-9_.\-]');

  /// Maps every spelling used by the request parser, the discussion contract and
  /// the user's own wording onto one canonical format. Returns null for a word
  /// that is not an output format at all.
  static String? _canonicalFormat(String raw) =>
      formatAliases[raw.trim().toLowerCase()];

  /// Whether a file satisfies one canonical format. Family aliases such as
  /// `.doc` for `docx` are covered by [formatAliases], because all of them are
  /// the same deliverable to the user.
  static bool _matchesDeclaredFormat(String path, String format) {
    final extension = extensionOf(path);
    return extension != null && formatAliases[extension] == format;
  }

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

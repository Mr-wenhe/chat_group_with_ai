part of 'work_role_router.dart';

enum WorkRoleRouteSource {
  explicitMention,
  privateChat,
  handoff,
  model,
  deterministicFallback,
  candidateSelection,
  unavailable,
}

enum WorkRoleStageKind { product, frontend, development, testing, general }

/// The user-facing contract extracted before a role can be selected.
///
/// This is deliberately a small value object rather than a second task model.
/// Later work-mode stages can persist it with the existing task checkpoint.
class WorkDeliverableContract {
  final String deliverableType;
  final String format;
  final String location;
  final String contentScope;
  final String? explicitExecutorId;
  final String revisionTarget;
  final int requestRevision;

  const WorkDeliverableContract({
    required this.deliverableType,
    required this.format,
    required this.location,
    required this.contentScope,
    this.explicitExecutorId,
    this.revisionTarget = '',
    this.requestRevision = 1,
  });

  bool get hasExplicitFormat => format != 'unspecified';

  bool get targetsDesktop => location == 'desktop';

  bool get isRevision => revisionTarget.trim().isNotEmpty;

  WorkDeliverableContract copyWith({String? explicitExecutorId}) =>
      WorkDeliverableContract(
        deliverableType: deliverableType,
        format: format,
        location: location,
        contentScope: contentScope,
        explicitExecutorId: explicitExecutorId ?? this.explicitExecutorId,
        revisionTarget: revisionTarget,
        requestRevision: requestRevision,
      );

  Map<String, dynamic> toJson() => {
        'deliverableType': deliverableType,
        'format': format,
        'location': location,
        'contentScope': contentScope,
        'explicitExecutorId': explicitExecutorId,
        'revisionTarget': revisionTarget,
        'requestRevision': requestRevision,
      };
}

String _effectiveDeliverableFormat(String? override, String inferred) {
  final normalized = override?.trim().toLowerCase();
  // A renewed discussion may retain the original request text; its persisted
  // deliverable format is authoritative for the active phase.
  return const {'docx', 'html', 'markdown', 'pdf'}.contains(normalized)
      ? normalized!
      : inferred;
}

/// Structured output accepted from the short model-based routing request.
class WorkRoleModelDecision {
  final String characterId;
  final String publicReason;
  final double confidence;
  final bool needsHandoff;

  const WorkRoleModelDecision({
    required this.characterId,
    required this.publicReason,
    required this.confidence,
    required this.needsHandoff,
  });

  factory WorkRoleModelDecision.fromJson(Map<String, dynamic> json) {
    final id = _modelText(json['characterId'] ?? json['roleId']);
    final reason = _modelText(json['publicReason'] ?? json['reason']);
    final confidence = json['confidence'];
    if (id.isEmpty || reason.isEmpty || confidence is! num) {
      throw const FormatException('模型角色路由结果缺少必需字段');
    }
    return WorkRoleModelDecision(
      characterId: id,
      publicReason: reason,
      confidence: confidence.toDouble(),
      needsHandoff: json['needsHandoff'] == true || json['handoff'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
        'characterId': characterId,
        'publicReason': publicReason,
        'confidence': confidence,
        'needsHandoff': needsHandoff,
      };
}

/// Input exposed to a routing model contains only public persona metadata.
class WorkRoleRoutingContext {
  final String request;
  final String conversationId;
  final List<AICharacter> characters;
  final List<CharacterSkill> skills;
  final List<String> candidateCharacterIds;
  final List<WorkRoleStageKind> inferredStages;
  final WorkDeliverableContract? deliverableContract;

  WorkRoleRoutingContext({
    required this.request,
    required this.conversationId,
    required Iterable<AICharacter> characters,
    Iterable<CharacterSkill> skills = const [],
    Iterable<String> candidateCharacterIds = const [],
    Iterable<WorkRoleStageKind> inferredStages = const [],
    this.deliverableContract,
  })  : characters = List.unmodifiable(
          characters.map(_publicCharacter),
        ),
        skills = List.unmodifiable(skills),
        candidateCharacterIds = List.unmodifiable(candidateCharacterIds),
        inferredStages = List.unmodifiable(inferredStages);
}

typedef WorkRoleModelSelector = FutureOr<Object?> Function(
  WorkRoleRoutingContext context,
);

/// Public result for both model and deterministic routing paths.
class WorkRoleRouteResult {
  final String? characterId;
  final WorkRoleRouteSource source;
  final String publicReason;
  final double confidence;
  final bool needsHandoff;
  final List<WorkHandoffStage> stages;
  final WorkHandoffState? handoffState;
  final WorkDeliverableContract? deliverableContract;
  final List<String> candidateCharacterIds;
  final List<String> discussionCharacterIds;
  final List<String> consultedCharacterIds;

  /// Mention diagnostics are kept separate from [publicReason] so a later
  /// discussion state can wait for clarification without parsing UI text.
  final List<String> unknownMentionNames;
  final List<String> ambiguousMentionNames;
  final List<String> ambiguousExecutorIds;
  final bool needsExecutorSelection;

  WorkRoleRouteResult({
    required this.characterId,
    required this.source,
    required this.publicReason,
    required this.confidence,
    required this.needsHandoff,
    this.stages = const [],
    this.handoffState,
    this.deliverableContract,
    Iterable<String> candidateCharacterIds = const [],
    Iterable<String> discussionCharacterIds = const [],
    Iterable<String> consultedCharacterIds = const [],
    Iterable<String> unknownMentionNames = const [],
    Iterable<String> ambiguousMentionNames = const [],
    Iterable<String> ambiguousExecutorIds = const [],
    this.needsExecutorSelection = false,
  })  : candidateCharacterIds = List.unmodifiable(candidateCharacterIds),
        discussionCharacterIds = List.unmodifiable(discussionCharacterIds),
        consultedCharacterIds = List.unmodifiable(consultedCharacterIds),
        unknownMentionNames = List.unmodifiable(unknownMentionNames),
        ambiguousMentionNames = List.unmodifiable(ambiguousMentionNames),
        ambiguousExecutorIds = List.unmodifiable(ambiguousExecutorIds);

  bool get isSuccess => characterId != null && publicReason.trim().isNotEmpty;

  String? get selectedCharacterId => characterId;

  String get reason => publicReason;

  bool get requiresHandoff => needsHandoff;

  bool get isWaitingForExecutor => needsExecutorSelection;

  bool get needsMentionClarification =>
      unknownMentionNames.isNotEmpty ||
      ambiguousMentionNames.isNotEmpty ||
      ambiguousExecutorIds.isNotEmpty;
}

class _StagePlanResult {
  final List<WorkHandoffStage> stages;
  final String? failure;

  const _StagePlanResult.success(this.stages) : failure = null;

  const _StagePlanResult.failed(this.failure) : stages = const [];

  bool get isSuccess => failure == null;
}

AICharacter _publicCharacter(AICharacter character) => AICharacter(
      id: character.id,
      name: character.name,
      avatar: character.avatar,
      age: character.age,
      role: character.role,
      personalityTags: List<String>.from(character.personalityTags),
      systemPrompt: character.systemPrompt,
      apiKey: '',
      apiProvider: character.apiProvider,
      modelName: character.modelName,
      customBaseUrl: '',
      apiConfigId: '',
      agenticEnabled: character.agenticEnabled,
      skillIds: List<String>.from(character.skillIds),
      toolPermissions: List.from(character.toolPermissions),
      gender: character.gender,
      hasKnownGender: character.hasKnownGender,
    );

WorkDeliverableContract _deliverableContract(
  String request, {
  String? explicitExecutorId,
  required int requestRevision,
}) {
  final lower = request.toLowerCase();
  final pathMatches = RegExp(
    r'(?<![\w./\\-])((?:[A-Za-z]:[\\/]|/)?[\w\u3400-\u9fff][\w\u3400-\u9fff./\\-]*\.(?:docx?|html?|md|markdown|pdf|txt|json|ya?ml|css|js|ts|dart|py))(?![\w/\\-]|\.(?=\S))',
    caseSensitive: false,
  ).allMatches(request).toList(growable: false);
  final paths = pathMatches.map((match) => match.group(1)!).toList();
  final sourcePath = paths.isEmpty ? null : paths.first;
  final explicitOutputPath = _explicitOutputPath(request, pathMatches);
  final isTestingRequest = RegExp(
    r'测试|验证|回归|qa|quality assurance|test|验收',
    caseSensitive: false,
  ).hasMatch(lower.replaceAll('验收标准', ''));
  final explicitQaOnly =
      RegExp(r'qa[- ]only', caseSensitive: false).hasMatch(lower);
  final outputPathFormat = explicitOutputPath == null
      ? 'unspecified'
      : _requestedFormat('', explicitOutputPath);
  final hasHtmlSourcePath = pathMatches.any(
    (match) =>
        RegExp(r'\.html?$', caseSensitive: false).hasMatch(match.group(1)!),
  );
  final isTestingSourceReference = isTestingRequest &&
      hasHtmlSourcePath &&
      (explicitQaOnly || !_hasFrontendImplementationBeforeTesting(lower));
  final qaReportPath = isTestingSourceReference
      ? paths.cast<String?>().lastWhere(
            (path) =>
                path != null &&
                RegExp(r'\.(?:md|markdown)$', caseSensitive: false)
                    .hasMatch(path),
            orElse: () => null,
          )
      : null;
  // A renewed QA request may retain an earlier developer HTML path in its
  // audit text.  When the same request names a Markdown report, that report
  // is the active deliverable even if the stale HTML path looked explicit.
  final qaReportIsActive = isTestingSourceReference && qaReportPath != null;
  final format = qaReportIsActive
      ? 'markdown'
      : outputPathFormat == 'unspecified'
          ? isTestingSourceReference
              ? 'unspecified'
              : _requestedFormat(lower, sourcePath)
          : outputPathFormat;
  final outputPath = qaReportIsActive
      ? qaReportPath
      : explicitOutputPath == null
          ? _outputPathForFormat(paths, format)
          : _outputPathForFormat([explicitOutputPath], format) ??
              explicitOutputPath;
  final document = format == 'docx' ||
      format == 'pdf' ||
      format == 'markdown' ||
      RegExp(r'文档|报告|prd|需求', caseSensitive: false).hasMatch(lower);
  final source = format == 'html' ||
      RegExp(r'代码|脚本|源码|程序|网页|网站', caseSensitive: false).hasMatch(lower);
  final contractLocation = _contractLocationForOutput(
    outputPath,
    request: lower,
  );
  final revision = RegExp(
    r'修改|更新|修复|重构|继续完善|刚才|上次|同一文件|相同文件|same file|previous',
    caseSensitive: false,
  ).hasMatch(lower);
  return WorkDeliverableContract(
    deliverableType: document
        ? 'document'
        : source
            ? 'source'
            : 'generic',
    format: format,
    location: contractLocation ??
        (RegExp(r'桌面|desktop', caseSensitive: false).hasMatch(lower)
            ? 'desktop'
            : 'unspecified'),
    contentScope:
        request.length <= 4000 ? request : '${request.substring(0, 3999)}…',
    explicitExecutorId: explicitExecutorId,
    revisionTarget: revision ? (contractLocation ?? 'same-output') : '',
    requestRevision: requestRevision,
  );
}

String? _explicitOutputPath(String request, List<RegExpMatch> pathMatches) {
  final outputAction = RegExp(
    r'生成|创建|新建|产出|输出|写入|保存|导出|上传|更新|修改|修复|\b(?:generate|create|produce|output|write|save|export|upload|update|modify|fix|deliver|attach)\w*\b',
    caseSensitive: false,
  );
  final existingReference = RegExp(
    r'\b(?:already|existing|previous|original|source|input|reference|attachment|attached)\b|附件|现有|已有|原始|参考|被测',
    caseSensitive: false,
  );
  var previousPathEnd = 0;
  for (final match in pathMatches) {
    // Keep each path's instruction local so an earlier "create" cannot turn
    // a later input attachment into an output. The first requested output is
    // the active stage; later paths may describe conditional follow-up work.
    final pathContext = request.substring(previousPathEnd, match.start);
    previousPathEnd = match.end;
    if (outputAction.hasMatch(pathContext) &&
        !existingReference.hasMatch(pathContext)) {
      return match.group(1);
    }
  }
  return null;
}

String? _contractLocationForOutput(
  String? outputPath, {
  required String request,
}) {
  if (outputPath == null || outputPath.trim().isEmpty) return null;
  final normalized = outputPath.replaceAll('\\', '/');
  // An explicit `桌面/` or `Desktop/` prefix identifies the platform desktop,
  // whose bound workspace is already the desktop root. Store the remainder so
  // the completion guard does not incorrectly look for Desktop/Desktop/file.
  final desktopPrefix = RegExp(
    r'^(?:桌面|desktop)(?:/|$)',
    caseSensitive: false,
  ).matchAsPrefix(normalized);
  if (desktopPrefix != null &&
      RegExp(r'桌面|desktop', caseSensitive: false).hasMatch(request)) {
    final remainder = normalized.substring(desktopPrefix.end);
    return remainder.isEmpty ? 'desktop' : remainder;
  }
  return outputPath;
}

String? _outputPathForFormat(List<String> paths, String format) {
  if (paths.isEmpty) return null;
  final extension = switch (format) {
    'docx' => RegExp(r'\.docx?$', caseSensitive: false),
    'html' => RegExp(r'\.html?$', caseSensitive: false),
    'markdown' => RegExp(r'\.(?:md|markdown)$', caseSensitive: false),
    'pdf' => RegExp(r'\.pdf$', caseSensitive: false),
    _ => null,
  };
  if (extension == null) return paths.first;
  for (final rawPath in paths.reversed) {
    // The permissive CJK path matcher can begin at a prose word before an
    // explicit `桌面/` or `Desktop/` marker. Prefer the actual marked path so
    // phrases such as “文档并保存到桌面/需求文档.docx” do not become a bogus
    // filename containing the preceding sentence.
    final path = _trimEmbeddedDesktopPath(rawPath, extension);
    if (extension.hasMatch(path)) return path;
  }
  // A source-only conversion request (for example proposal.md → Word) has no
  // explicit final filename. Let the desktop/conversation workspace choose a
  // DOCX name instead of binding the output contract to the Markdown source.
  return null;
}

String _trimEmbeddedDesktopPath(String path, RegExp extension) {
  final marker = RegExp(
    r'(?:桌面|desktop)[\/][\w\u3400-\u9fff][\w\u3400-\u9fff./\-]*$',
    caseSensitive: false,
  ).firstMatch(path);
  if (marker != null && extension.hasMatch(marker.group(0)!)) {
    return marker.group(0)!;
  }
  return path;
}

String _requestedFormat(String lower, String? path) {
  final extension = path?.split('.').last.toLowerCase();
  if (extension == 'doc' ||
      extension == 'docx' ||
      RegExp(r'\.docx?\b', caseSensitive: false).hasMatch(lower) ||
      RegExp(r'word\s*(?:文档|document|docx)?', caseSensitive: false)
          .hasMatch(lower)) {
    return 'docx';
  }
  if (extension == 'html' ||
      extension == 'htm' ||
      RegExp(r'\.html?\b', caseSensitive: false).hasMatch(lower) ||
      RegExp(r'html?|网页|网站', caseSensitive: false).hasMatch(lower)) {
    return 'html';
  }
  if (extension == 'md' ||
      extension == 'markdown' ||
      RegExp(r'\.(?:md|markdown)\b', caseSensitive: false).hasMatch(lower) ||
      RegExp(r'markdown|\bmd\b', caseSensitive: false).hasMatch(lower)) {
    return 'markdown';
  }
  if (extension == 'pdf' ||
      RegExp(r'\.pdf\b', caseSensitive: false).hasMatch(lower) ||
      RegExp(r'\bpdf\b', caseSensitive: false).hasMatch(lower)) {
    return 'pdf';
  }
  return 'unspecified';
}

part of 'work_role_router.dart';

_StagePlanResult _stagePlan(
  String request,
  List<WorkRoleStageKind> kinds,
  List<AICharacter> candidates,
  List<CharacterSkill> skills, {
  String? forcedFirstRoleId,
  List<String> explicitRoleIds = const [],
}) {
  final used = <String>{};
  final stages = <WorkHandoffStage>[];
  for (var index = 0; index < kinds.length; index++) {
    final kind = kinds[index];
    AICharacter? selected;
    if (index == 0 && forcedFirstRoleId != null) {
      selected = WorkRoleRouter._findUnique(candidates, forcedFirstRoleId);
      if (selected == null || !_isSuitable(selected, kind, skills)) {
        return _StagePlanResult.failed(
          '角色「${selected?.name ?? forcedFirstRoleId}」不具备${_stageLabel(kind)}所需的职业或 Skill 能力。',
        );
      }
    } else if (explicitRoleIds.length > index) {
      final explicit = WorkRoleRouter._findUnique(
        candidates,
        explicitRoleIds[index],
      );
      if (explicit == null || !_isSuitable(explicit, kind, skills)) {
        return _StagePlanResult.failed(
          '被 @ 的角色「${explicitRoleIds[index]}」不具备${_stageLabel(kind)}所需能力，没有静默换人。',
        );
      }
      selected = explicit;
    } else {
      selected = _bestCandidate(candidates, kind, skills, used);
    }
    if (selected == null || used.contains(selected.id)) {
      return _StagePlanResult.failed(
        '没有活跃角色具备${_stageLabel(kind)}所需的职业或 Skill 能力。',
      );
    }
    used.add(selected.id);
    stages.add(_stageFor(kind, selected.id));
  }
  return _StagePlanResult.success(stages);
}

List<WorkRoleStageKind> _inferStages(
  String request, {
  required String deliverableFormat,
}) {
  final lower = request.toLowerCase();
  final forTesting = lower.replaceAll('验收标准', '');
  final result = <WorkRoleStageKind>[];
  final isDocumentDeliverable =
      const {'docx', 'pdf', 'markdown'}.contains(deliverableFormat);
  final isProductRequest = RegExp(
    r'需求|产品|prd|roadmap|用户故事|需求文档|product|strategy',
    caseSensitive: false,
  ).hasMatch(lower);
  final isFrontendRequest = RegExp(
    r'html?|前端|frontend|front[- ]end|网页|网站|web 页面|web page|css|javascript|typescript',
    caseSensitive: false,
  ).hasMatch(lower);
  final isTestingRequest = RegExp(
    r'测试|验证|回归|qa|quality assurance|test|验收',
    caseSensitive: false,
  ).hasMatch(forTesting);
  final isTestingOnlySourceReference = isTestingRequest &&
      deliverableFormat == 'unspecified' &&
      isFrontendRequest &&
      !_hasFrontendImplementationBeforeTesting(lower);
  // Only an explicit product deliverable creates a preceding product stage.
  // "根据需求做 HTML" describes the context, not a product handoff.
  final explicitProductStage = RegExp(
    r'(?:写|撰写|输出|出具|编写|制定|生成).{0,8}(?:需求文档|产品方案|prd)|(?:write|create|produce)\s+(?:a\s+)?(?:prd|requirements document)',
    caseSensitive: false,
  ).hasMatch(lower);
  if (isProductRequest &&
      (explicitProductStage ||
          (!isTestingRequest &&
              (isDocumentDeliverable || !isFrontendRequest)))) {
    result.add(WorkRoleStageKind.product);
  }
  // A source document mentioned in the request must not hide an explicitly
  // requested HTML implementation stage.
  if (isFrontendRequest &&
      !isDocumentDeliverable &&
      !isTestingOnlySourceReference) {
    result.add(WorkRoleStageKind.frontend);
  } else if (!isDocumentDeliverable &&
      !isTestingOnlySourceReference &&
      RegExp(
        r'代码|编码|开发|编程|实现|修复|flutter|dart|javascript|typescript|python|coding|developer|engineer|bug',
        caseSensitive: false,
      ).hasMatch(lower)) {
    result.add(WorkRoleStageKind.development);
  }
  if (isTestingRequest) {
    result.add(WorkRoleStageKind.testing);
  }
  return result.isEmpty ? [WorkRoleStageKind.general] : result;
}

bool _hasFrontendImplementationBeforeTesting(String request) {
  final testingStart = RegExp(
    r'测试|验证|回归|qa|quality assurance|test|验收',
    caseSensitive: false,
  ).firstMatch(request)?.start;
  final implementation = RegExp(
    r'(?:(?:做|开发|实现|构建|编写|制作|生成|修复|修改)|\b(?:build|create|develop|implement|make|generate|write|fix|repair)\w*\b).{0,48}?(?:html?|frontend|front[- ]end|前端|网页|网站|web 页面|web page|css|javascript|typescript)|(?:html?|网页|网站|web 页面|web page).{0,48}(?:修复|修改|fix|repair)',
    caseSensitive: false,
  ).firstMatch(request);
  return implementation != null &&
      (testingStart == null || implementation.start < testingStart);
}

WorkHandoffStage _stageFor(WorkRoleStageKind kind, String roleId) {
  return switch (kind) {
    WorkRoleStageKind.product => WorkHandoffStage(
        id: 'product',
        label: '产品需求',
        roleId: roleId,
        deliverables: const ['需求文档', '验收标准'],
        completionCriteria: const ['目标、范围和验收标准已明确'],
      ),
    WorkRoleStageKind.frontend => WorkHandoffStage(
        id: 'frontend',
        label: '前端实现',
        roleId: roleId,
        deliverables: const ['可运行网页', '变更说明'],
        completionCriteria: const ['前端文件已写入并完成轻量检查'],
      ),
    WorkRoleStageKind.development => WorkHandoffStage(
        id: 'development',
        label: '开发实现',
        roleId: roleId,
        deliverables: const ['可运行实现', '变更说明'],
        completionCriteria: const ['代码已写入并完成轻量检查'],
      ),
    WorkRoleStageKind.testing => WorkHandoffStage(
        id: 'testing',
        label: '测试验证',
        roleId: roleId,
        deliverables: const ['测试结果', '缺陷清单'],
        completionCriteria: const ['测试结果和未验证项已记录'],
      ),
    WorkRoleStageKind.general => WorkHandoffStage(
        id: 'general',
        label: '执行任务',
        roleId: roleId,
        deliverables: const ['任务结果'],
        completionCriteria: const ['用户目标已完成'],
      ),
  };
}

WorkRoleStageKind _stageKind(String stageId) => switch (stageId) {
      'product' => WorkRoleStageKind.product,
      'frontend' => WorkRoleStageKind.frontend,
      'development' => WorkRoleStageKind.development,
      'testing' => WorkRoleStageKind.testing,
      _ => WorkRoleStageKind.general,
    };

AICharacter? _bestCandidate(
  List<AICharacter> candidates,
  WorkRoleStageKind kind,
  List<CharacterSkill> skills,
  Set<String> used,
) {
  AICharacter? best;
  var bestScore = 0;
  for (final candidate in candidates) {
    if (used.contains(candidate.id)) continue;
    final score = _score(candidate, kind, skills);
    if (score > bestScore) {
      best = candidate;
      bestScore = score;
    }
  }
  return best;
}

bool _isSuitable(
  AICharacter character,
  WorkRoleStageKind kind,
  List<CharacterSkill> skills,
) =>
    kind == WorkRoleStageKind.general || _score(character, kind, skills) > 0;

int _score(
  AICharacter character,
  WorkRoleStageKind kind,
  List<CharacterSkill> skills,
) {
  if (kind == WorkRoleStageKind.general) return 1;
  final profile = _profile(character, skills);
  var score = 0;
  for (final keyword in _keywords(kind)) {
    if (profile.contains(keyword)) score++;
  }
  return score;
}

String _profile(AICharacter character, List<CharacterSkill> skills) {
  final selectedSkills = skills.where(
    (skill) =>
        !skill.isGlobal &&
        (skill.characterId == character.id ||
            character.skillIds.contains(skill.id)),
  );
  return [
    // A display name, personality tag, or global skill is not a profession.
    // Only configured role/duty text and role-bound skills can qualify a task.
    character.role,
    character.systemPrompt,
    for (final skill in selectedSkills) skill.name,
    for (final skill in selectedSkills) skill.domain,
    for (final skill in selectedSkills) skill.description,
    for (final skill in selectedSkills) ...skill.instructions,
  ].join(' ').toLowerCase();
}

List<String> _keywords(WorkRoleStageKind kind) => switch (kind) {
      WorkRoleStageKind.product => const [
          '产品',
          '需求',
          'prd',
          'roadmap',
          '用户故事',
          'product',
          'strategy',
          '规划',
        ],
      WorkRoleStageKind.frontend => const [
          '前端',
          'html',
          'html5',
          'frontend',
          'front-end',
          'web',
          '网页',
          '网站',
          'css',
          'javascript',
          'typescript',
        ],
      WorkRoleStageKind.development => const [
          '开发',
          '代码',
          '编码',
          '编程',
          '实现',
          'flutter',
          'dart',
          'javascript',
          'typescript',
          'python',
          'coding',
          'developer',
          'engineer',
          'bug',
        ],
      WorkRoleStageKind.testing => const [
          '测试',
          '验证',
          '回归',
          'qa',
          'quality',
          'test',
          '验收',
        ],
      WorkRoleStageKind.general => const [],
    };

String _stageLabel(WorkRoleStageKind kind) => switch (kind) {
      WorkRoleStageKind.product => '产品需求',
      WorkRoleStageKind.frontend => '前端实现',
      WorkRoleStageKind.development => '开发',
      WorkRoleStageKind.testing => '测试',
      WorkRoleStageKind.general => '通用任务',
    };

class _WorkRoleMentionIntent {
  final bool mentionsAll;
  final List<String> explicitMentionedIds;
  final List<String> discussionCharacterIds;
  final List<String> consultedCharacterIds;
  final List<String> ambiguousExecutorIds;
  final String? explicitExecutorId;

  const _WorkRoleMentionIntent({
    required this.mentionsAll,
    required this.explicitMentionedIds,
    required this.discussionCharacterIds,
    required this.consultedCharacterIds,
    required this.ambiguousExecutorIds,
    this.explicitExecutorId,
  });
}

/// Extracts the work-mode meaning of mentions without changing the shared
/// chat parser. `@all` is a discussion audience; a trailing `由 @角色 执行`
/// clause is the only assignment that can override that audience.
_WorkRoleMentionIntent _workRoleMentionIntent(
  String request,
  List<AICharacter> characters,
) {
  final byName = <String, List<String>>{};
  for (final character in characters) {
    byName.putIfAbsent(character.name, () => <String>[]).add(character.id);
  }
  final mentions = <({String id, int start, int end})>[];
  var mentionsAll = false;
  final mentionPattern = RegExp(r'@([^@\s，。！？!?、；;：:,.]+)');
  for (final match in mentionPattern.allMatches(request)) {
    if (match.start > 0 &&
        RegExp(r'^[A-Za-z0-9_./%+\-]$').hasMatch(request[match.start - 1])) {
      continue;
    }
    final rawName = match.group(1);
    if (rawName == null) continue;
    final name = resolveKnownMentionName(rawName, byName);
    final nameLength = name?.length ?? 0;
    if (name == null) continue;
    if (isMentionAllToken(name)) {
      mentionsAll = true;
      continue;
    }
    final ids = byName[name] ?? const <String>[];
    if (ids.length == 1) {
      // Keep the action after a Chinese name in the clause. This lets
      // `@小产输出` mean the same thing as `@小产 输出` and prevents the
      // action from hiding the final-executor marker.
      mentions.add(
        (id: ids.single, start: match.start, end: match.start + 1 + nameLength),
      );
    }
  }

  final finalExecutorIds = <String>[];
  final consultedIds = <String>[];
  for (final target in mentions) {
    final prefix = request.substring(0, target.start).trimRight().toLowerCase();
    final suffix = request.substring(target.end).trimLeft().toLowerCase();
    final finalMarker = RegExp(
      r'(?:(?:最终|最后)(?:由)?|由|交给|指定|执行人|负责人|最终输出|最后输出|'
      r'\b(?:finally|executed by|output by|owned by)\b)\s*$',
      caseSensitive: false,
    ).hasMatch(prefix);
    final finalAction = RegExp(
      r'^(?:输出|出具|交付|生成|制作|完成(?:任务|文档|结果)?|'
      r'负责(?:最终|整体|输出)?|执行(?:整个|最终)?任务|'
      r'output|deliver|produce|complete|own the final)',
      caseSensitive: false,
    ).hasMatch(suffix);
    if (finalMarker && finalAction) {
      if (!finalExecutorIds.contains(target.id)) {
        finalExecutorIds.add(target.id);
      }
      continue;
    }
    int? nextStart;
    for (final candidate in mentions) {
      if (candidate.start > target.start) {
        nextStart = candidate.start;
        break;
      }
    }
    final clause = request
        .substring(target.end, nextStart ?? request.length)
        .trim()
        .toLowerCase();
    if (_looksLikeConsultation(clause) && !consultedIds.contains(target.id)) {
      consultedIds.add(target.id);
    }
  }

  final finalExecutor =
      finalExecutorIds.length == 1 ? finalExecutorIds.single : null;
  final explicitIds = <String>[];
  if (finalExecutor != null) {
    explicitIds.add(finalExecutor);
  } else if (!mentionsAll) {
    for (final target in mentions) {
      if (!consultedIds.contains(target.id) &&
          !explicitIds.contains(target.id)) {
        explicitIds.add(target.id);
      }
    }
  }
  final discussionIds = <String>[];
  if (mentionsAll) {
    for (final character in characters) {
      if (!discussionIds.contains(character.id)) {
        discussionIds.add(character.id);
      }
    }
  }
  for (final id in consultedIds) {
    if (!discussionIds.contains(id)) {
      discussionIds.add(id);
    }
  }
  final assigned = finalExecutor ??
      (!mentionsAll && consultedIds.isEmpty && explicitIds.length == 1
          ? explicitIds.single
          : null);
  return _WorkRoleMentionIntent(
    mentionsAll: mentionsAll,
    explicitMentionedIds: List.unmodifiable(explicitIds),
    discussionCharacterIds: List.unmodifiable(discussionIds),
    consultedCharacterIds: List.unmodifiable(consultedIds),
    ambiguousExecutorIds: List.unmodifiable(
      finalExecutorIds.length > 1 ? finalExecutorIds : const <String>[],
    ),
    explicitExecutorId: assigned,
  );
}

bool _looksLikeConsultation(String clause) {
  if (clause.isEmpty) return false;
  final leadingConsultation = RegExp(
    r'^(?:请)?(?:咨询|评估|判断|分析|看看|审查|审核|评审|review|assess|evaluate|advise|suggest|'
    r'能否|是否|可行性?|建议|意见|怎么看|补充|说说|你觉得|你能|你可以|'
    r'can you|could you|please|what do you think)',
    caseSensitive: false,
  ).hasMatch(clause);
  final question = RegExp(
    r'[?？]|能否|能不能|是否|可行|(?:吗|呢)\s*[?？]?$',
    caseSensitive: false,
  ).hasMatch(clause);
  return leadingConsultation || question;
}

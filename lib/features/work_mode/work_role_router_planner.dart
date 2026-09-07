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

List<WorkRoleStageKind> _inferStages(String request) {
  final lower = request.toLowerCase();
  final forTesting = lower.replaceAll('验收标准', '');
  final result = <WorkRoleStageKind>[];
  if (RegExp(
    r'需求|产品|prd|roadmap|用户故事|需求文档|product|strategy',
    caseSensitive: false,
  ).hasMatch(lower)) {
    result.add(WorkRoleStageKind.product);
  }
  if (RegExp(
    r'代码|编码|开发|编程|实现|修复|flutter|dart|javascript|typescript|python|coding|developer|engineer|bug',
    caseSensitive: false,
  ).hasMatch(lower)) {
    result.add(WorkRoleStageKind.development);
  }
  if (RegExp(
    r'测试|验证|回归|qa|quality assurance|test|验收',
    caseSensitive: false,
  ).hasMatch(forTesting)) {
    result.add(WorkRoleStageKind.testing);
  }
  return result.isEmpty ? [WorkRoleStageKind.general] : result;
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
        skill.isGlobal ||
        skill.characterId == character.id ||
        character.skillIds.contains(skill.id),
  );
  return [
    character.name,
    character.role,
    character.systemPrompt,
    ...character.personalityTags,
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
      WorkRoleStageKind.development => '开发',
      WorkRoleStageKind.testing => '测试',
      WorkRoleStageKind.general => '通用任务',
    };

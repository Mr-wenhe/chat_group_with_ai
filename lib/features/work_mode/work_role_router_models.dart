part of 'work_role_router.dart';

enum WorkRoleRouteSource {
  explicitMention,
  privateChat,
  handoff,
  model,
  deterministicFallback,
  unavailable,
}

enum WorkRoleStageKind { product, development, testing, general }

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

  WorkRoleRoutingContext({
    required this.request,
    required this.conversationId,
    required Iterable<AICharacter> characters,
    Iterable<CharacterSkill> skills = const [],
    Iterable<String> candidateCharacterIds = const [],
    Iterable<WorkRoleStageKind> inferredStages = const [],
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

  const WorkRoleRouteResult({
    required this.characterId,
    required this.source,
    required this.publicReason,
    required this.confidence,
    required this.needsHandoff,
    this.stages = const [],
    this.handoffState,
  });

  bool get isSuccess => characterId != null && publicReason.trim().isNotEmpty;

  String? get selectedCharacterId => characterId;

  String get reason => publicReason;

  bool get requiresHandoff => needsHandoff;
}

class _StagePlanResult {
  final List<WorkHandoffStage> stages;
  final String? failure;

  const _StagePlanResult.success(this.stages) : failure = null;

  const _StagePlanResult.failed(this.failure) : stages = const [];

  bool get isSuccess => failure == null;
}

import 'dart:convert';

import 'package:chat_group/core/models/agent_task.dart';

/// The small, durable description passed from one work role to the next.
class WorkHandoffStage {
  final String id;
  final String label;
  final String roleId;
  final List<String> deliverables;
  final List<String> completionCriteria;

  WorkHandoffStage({
    required String id,
    required String label,
    required String roleId,
    Iterable<String> deliverables = const [],
    Iterable<String> completionCriteria = const [],
  })  : id = _requiredText(id, 'stage id'),
        label = _requiredText(label, 'stage label'),
        roleId = _requiredText(roleId, 'role id'),
        deliverables = _cleanList(deliverables),
        completionCriteria = _cleanList(completionCriteria);

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'roleId': roleId,
        'deliverables': deliverables,
        'completionCriteria': completionCriteria,
      };

  factory WorkHandoffStage.fromJson(Map<String, dynamic> json) {
    return WorkHandoffStage(
      id: _readText(json['id'] ?? json['stage']),
      label: _readText(json['label'] ?? json['name'] ?? json['id']),
      roleId: _readText(json['roleId'] ?? json['characterId']),
      deliverables: _readStrings(json['deliverables'] ?? json['artifacts']),
      completionCriteria: _readStrings(
        json['completionCriteria'] ?? json['completionConditions'],
      ),
    );
  }
}

enum WorkHandoffStatus { active, awaitingReceiver, completed }

/// Persisted handoff state. It contains no file body or model-private text.
class WorkHandoffState {
  static const int schemaVersion = 1;

  final String conversationId;
  final List<WorkHandoffStage> stages;
  final int currentStageIndex;
  final List<String> deliveredArtifacts;
  final WorkHandoffStatus status;
  final String lastSummary;

  WorkHandoffState({
    required String conversationId,
    required Iterable<WorkHandoffStage> stages,
    this.currentStageIndex = 0,
    Iterable<String> deliveredArtifacts = const [],
    this.status = WorkHandoffStatus.active,
    String lastSummary = '',
  })  : conversationId = _requiredText(conversationId, 'conversation id'),
        stages = List.unmodifiable(stages),
        deliveredArtifacts = _cleanList(deliveredArtifacts),
        lastSummary = _clip(lastSummary) {
    if (this.stages.isEmpty) {
      throw ArgumentError.value(stages, 'stages', '至少需要一个接力阶段');
    }
    if (currentStageIndex < 0 || currentStageIndex >= this.stages.length) {
      throw RangeError.range(
        currentStageIndex,
        0,
        this.stages.length - 1,
        'currentStageIndex',
      );
    }
    if (status == WorkHandoffStatus.completed && !isLastStage) {
      throw ArgumentError.value(status, 'status', '未到最后阶段不能标记完成');
    }
  }

  WorkHandoffState.initial({
    required String conversationId,
    required Iterable<WorkHandoffStage> stages,
  }) : this(
          conversationId: conversationId,
          stages: stages,
        );

  WorkHandoffStage get currentStage => stages[currentStageIndex];

  String get currentRoleId => currentStage.roleId;

  String? get receivingRoleId =>
      isLastStage ? null : stages[currentStageIndex + 1].roleId;

  String get stage => currentStage.id;

  String get stageLabel => currentStage.label;

  List<String> get stageIds =>
      stages.map((item) => item.id).toList(growable: false);

  List<String> get deliverables => currentStage.deliverables;

  List<String> get completionCriteria => currentStage.completionCriteria;

  bool get isLastStage => currentStageIndex == stages.length - 1;

  bool get isComplete => status == WorkHandoffStatus.completed;

  bool get isAwaitingReceiver => status == WorkHandoffStatus.awaitingReceiver;

  bool get needsHandoff => !isComplete && !isLastStage;

  /// Marks the next role as the active owner after the prior lease is gone.
  WorkHandoffState activateReceiver() {
    if (!isAwaitingReceiver) return this;
    return WorkHandoffState(
      conversationId: conversationId,
      stages: stages,
      currentStageIndex: currentStageIndex,
      deliveredArtifacts: deliveredArtifacts,
      status: WorkHandoffStatus.active,
      lastSummary: lastSummary,
    );
  }

  /// Moves to the next role only after the previous role's lease is released.
  WorkHandoffState advanceAfterStage({
    required bool previousRoleReleased,
    Iterable<String> deliveredArtifacts = const [],
    String summary = '',
  }) {
    if (!previousRoleReleased) {
      throw StateError('前一角色尚未释放执行锁，不能开始角色接力。');
    }
    final artifacts = _mergeLists(this.deliveredArtifacts, deliveredArtifacts);
    if (isLastStage) {
      return WorkHandoffState(
        conversationId: conversationId,
        stages: stages,
        currentStageIndex: currentStageIndex,
        deliveredArtifacts: artifacts,
        status: WorkHandoffStatus.completed,
        lastSummary: summary,
      );
    }
    return WorkHandoffState(
      conversationId: conversationId,
      stages: stages,
      currentStageIndex: currentStageIndex + 1,
      deliveredArtifacts: artifacts,
      status: WorkHandoffStatus.awaitingReceiver,
      lastSummary: summary,
    );
  }

  /// Alias used by coordinator callers that describe the same boundary as a
  /// completed stage rather than an explicit handoff.
  WorkHandoffState advance({
    required bool previousRoleReleased,
    Iterable<String> deliveredArtifacts = const [],
    String summary = '',
  }) =>
      advanceAfterStage(
        previousRoleReleased: previousRoleReleased,
        deliveredArtifacts: deliveredArtifacts,
        summary: summary,
      );

  Map<String, dynamic> toJson() => {
        'schemaVersion': schemaVersion,
        'conversationId': conversationId,
        'stage': stage,
        'stageLabel': stageLabel,
        'currentStageIndex': currentStageIndex,
        'currentRoleId': currentRoleId,
        'receivingRoleId': receivingRoleId,
        'deliverables': deliverables,
        'completionCriteria': completionCriteria,
        'deliveredArtifacts': deliveredArtifacts,
        'status': status.name,
        'lastSummary': lastSummary,
        'stages': stages.map((item) => item.toJson()).toList(growable: false),
      };

  String toJsonString() => jsonEncode(toJson());

  factory WorkHandoffState.fromJson(
    Map<String, dynamic> json, {
    String? expectedConversationId,
  }) {
    final conversationId = _readText(json['conversationId']);
    if (expectedConversationId != null &&
        conversationId != expectedConversationId) {
      throw const FormatException('角色接力 conversationId 不匹配');
    }
    final rawStages = json['stages'];
    final stages = rawStages is List
        ? rawStages
            .whereType<Map>()
            .map((item) => WorkHandoffStage.fromJson(
                  Map<String, dynamic>.from(item),
                ))
            .toList(growable: false)
        : <WorkHandoffStage>[];
    final fallbackStages = stages.isEmpty ? _legacyStage(json) : stages;
    final status = _status(json['status']);
    return WorkHandoffState(
      conversationId: conversationId,
      stages: fallbackStages,
      currentStageIndex: _readIndex(json['currentStageIndex'], fallbackStages),
      deliveredArtifacts:
          _readStrings(json['deliveredArtifacts'] ?? json['artifacts']),
      status: status,
      lastSummary:
          _readText(json['lastSummary'] ?? json['summary'], optional: true),
    );
  }

  factory WorkHandoffState.fromJsonString(
    String raw, {
    String? expectedConversationId,
  }) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) throw const FormatException('角色接力状态不是 JSON object');
    return WorkHandoffState.fromJson(
      Map<String, dynamic>.from(decoded),
      expectedConversationId: expectedConversationId,
    );
  }

  static WorkHandoffState? fromTask(AgentTask task) {
    final execution = _decodeMap(task.executionStateJson);
    final summary = _decodeMap(task.contextSummary);
    // Check every compatible checkpoint location. Older loop checkpoints may
    // have passed execution metadata through a stricter private-field filter
    // and lost the nested conversationId, while the canonical contextSummary
    // still contains a complete handoff. One malformed copy must not hide a
    // valid recovery copy.
    for (final raw in <Object?>[
      execution['roleHandoff'],
      execution['handoff'],
      summary['roleHandoff'],
      summary['handoff'],
    ]) {
      if (raw is! Map) continue;
      try {
        return WorkHandoffState.fromJson(
          Map<String, dynamic>.from(raw),
          expectedConversationId: task.groupId,
        );
      } on Object {
        // Try the next checkpoint representation.
      }
    }
    return null;
  }

  /// Writes the state into existing checkpoints without adding another Hive
  /// field, preserving Task 15's queue and approval keys.
  static void persistToTask(AgentTask task, WorkHandoffState state) {
    if (task.groupId != state.conversationId) {
      throw ArgumentError.value(state, 'state', '角色接力必须属于当前 conversationId');
    }
    final handoff = state.toJson();
    final execution = _decodeMap(task.executionStateJson);
    execution['roleHandoff'] = handoff;
    task.executionStateJson = jsonEncode(execution);
    task.assignedCharacterIds = <String>{
      ...task.assignedCharacterIds,
      for (final stage in state.stages) stage.roleId,
    }.toList(growable: false);

    final context = _decodeMap(task.contextSummary)
      ..['conversationId'] = task.groupId
      ..['roleHandoff'] = handoff;
    task.contextSummary = jsonEncode(context);
  }

  static WorkHandoffStatus _status(Object? value) {
    if (value == WorkHandoffStatus.completed.name) {
      return WorkHandoffStatus.completed;
    }
    if (value == WorkHandoffStatus.awaitingReceiver.name) {
      return WorkHandoffStatus.awaitingReceiver;
    }
    return WorkHandoffStatus.active;
  }

  static int _readIndex(Object? value, List<WorkHandoffStage> stages) {
    final index = value is num ? value.toInt() : 0;
    if (index < 0 || index >= stages.length) {
      throw const FormatException('角色接力阶段索引无效');
    }
    return index;
  }

  static List<WorkHandoffStage> _legacyStage(Map<String, dynamic> json) {
    final roleId = _readText(json['currentRoleId'] ?? json['target']);
    return [
      WorkHandoffStage(
        id: _readText(json['stage'] ?? 'handoff'),
        label: _readText(json['stageLabel'] ?? '角色接力'),
        roleId: roleId,
        deliverables: _readStrings(json['deliverables'] ?? json['artifacts']),
        completionCriteria: _readStrings(
          json['completionCriteria'] ?? json['completionConditions'],
        ),
      ),
    ];
  }
}

String _requiredText(String value, String field) {
  final normalized = value.trim();
  if (normalized.isEmpty) throw ArgumentError.value(value, field, '不能为空');
  return normalized;
}

String _readText(Object? value, {bool optional = false}) {
  if (value is String && (optional || value.trim().isNotEmpty)) {
    return _clip(value);
  }
  if (optional) return '';
  throw const FormatException('角色接力状态缺少文本字段');
}

List<String> _readStrings(Object? value) =>
    value is List ? _cleanList(value.whereType<String>()) : const <String>[];

List<String> _cleanList(Iterable<String> values) {
  final seen = <String>{};
  return values
      .map(_clip)
      .where((value) => value.isNotEmpty && seen.add(value))
      .take(64)
      .toList(growable: false);
}

List<String> _mergeLists(Iterable<String> first, Iterable<String> second) =>
    _cleanList([...first, ...second]);

String _clip(String value) {
  final normalized = value.trim();
  return normalized.length <= 512
      ? normalized
      : '${normalized.substring(0, 511)}…';
}

Map<String, dynamic> _decodeMap(String raw) {
  try {
    final decoded = jsonDecode(raw);
    return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
  } on Object {
    return <String, dynamic>{};
  }
}

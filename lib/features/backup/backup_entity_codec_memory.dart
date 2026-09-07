part of 'backup_entity_codec.dart';

class _BackupEntityMemoryCodec {
  static Map<String, dynamic> groupMemory(GroupMemory item) => {
        'groupId': item.groupId,
        'topicSummary': item.topicSummary,
        'lastSummaryAt': _date(item.lastSummaryAt),
      };

  static GroupMemory decodeGroupMemory(Map<String, dynamic> json) =>
      GroupMemory(
        groupId: _string(json, 'groupId'),
        topicSummary: json['topicSummary']?.toString() ?? '',
        lastSummaryAt: _dateTime(json, 'lastSummaryAt'),
      );

  static Map<String, dynamic> characterMemory(CharacterMemory item) => {
        'id': item.id,
        'groupId': item.groupId,
        'characterId': item.characterId,
        'facts': item.facts,
        'relationshipNotes': item.relationshipNotes,
        'personaGrowth': item.personaGrowth,
        'lastUpdatedAt': _date(item.lastUpdatedAt),
        'createdAt': _date(item.createdAt),
      };

  static CharacterMemory decodeCharacterMemory(Map<String, dynamic> json) =>
      CharacterMemory(
        id: _string(json, 'id'),
        groupId: _string(json, 'groupId'),
        characterId: _string(json, 'characterId'),
        facts: _strings(json['facts']),
        relationshipNotes: _strings(json['relationshipNotes']),
        personaGrowth: _strings(json['personaGrowth']),
        lastUpdatedAt: _dateTime(json, 'lastUpdatedAt'),
        createdAt: _dateTime(json, 'createdAt'),
      );

  static Map<String, dynamic> relationship(RelationshipState item) => {
        'id': item.id,
        'groupId': item.groupId,
        'sourceCharacterId': item.sourceCharacterId,
        'targetId': item.targetId,
        'targetType': item.targetType.name,
        'affinity': item.affinity,
        'trust': item.trust,
        'friction': item.friction,
        'familiarity': item.familiarity,
        'recentMood': item.recentMood.name,
        'notes': item.notes,
        'lastInteractionAt': _date(item.lastInteractionAt),
        'createdAt': _date(item.createdAt),
        'stage': item.stage.name,
        'revision': item.revision,
        'lastEventId': item.lastEventId,
        'updatedAt': _date(item.updatedAt),
      };

  static Map<String, dynamic> userProfile(UserProfile item) => {
        'id': item.id,
        'displayName': item.displayName,
        'preferredAddress': item.preferredAddress,
        'avatar': item.avatar,
        'pronouns': item.pronouns,
        'age': item.age,
        'bio': item.bio,
        'personality': item.personality,
        'interests': item.interests,
        'importantBackground': item.importantBackground,
        'updatedAt': _date(item.updatedAt),
        'createdAt': _date(item.createdAt),
      };

  static Map<String, dynamic> permanentMemory(
    PermanentMemory item, {
    List<String>? sourceMessageIds,
    List<String>? subjectIds,
    List<String>? participantIds,
    List<String>? supersedesIds,
  }) =>
      {
        'id': item.id,
        'observerCharacterId': item.observerCharacterId,
        'kind': item.kind.name,
        'content': item.content,
        'subjectIds': subjectIds ?? item.subjectIds,
        'status': item.status.name,
        'importance': item.importance,
        'confidence': item.confidence,
        'explicitlyRequested': item.explicitlyRequested,
        'pinned': item.pinned,
        'supersedesIds': supersedesIds ?? item.supersedesIds,
        'originType': item.originType.name,
        'originConversationId': item.originConversationId,
        'originNameSnapshot': item.originNameSnapshot,
        'sourceMessageIds': sourceMessageIds ?? item.sourceMessageIds,
        'participantIds': participantIds ?? item.participantIds,
        'occurredAt': _date(item.occurredAt),
        'createdAt': _date(item.createdAt),
        'updatedAt': _date(item.updatedAt),
        'invalidationReason': item.invalidationReason,
      };

  static Map<String, dynamic> relationshipEvent(
    RelationshipEvent item, {
    List<String>? sourceMessageIds,
  }) =>
      {
        'id': item.id,
        'sourceCharacterId': item.sourceCharacterId,
        'targetType': item.targetType.name,
        'targetId': item.targetId,
        'reason': item.reason,
        'affinityBefore': item.affinityBefore,
        'affinityAfter': item.affinityAfter,
        'trustBefore': item.trustBefore,
        'trustAfter': item.trustAfter,
        'frictionBefore': item.frictionBefore,
        'frictionAfter': item.frictionAfter,
        'familiarityBefore': item.familiarityBefore,
        'familiarityAfter': item.familiarityAfter,
        'moodBefore': item.moodBefore.name,
        'moodAfter': item.moodAfter.name,
        'stageBefore': item.stageBefore.name,
        'stageAfter': item.stageAfter.name,
        'originConversationId': item.originConversationId,
        'originNameSnapshot': item.originNameSnapshot,
        'sourceMessageIds': sourceMessageIds ?? item.sourceMessageIds,
        'revision': item.revision,
        'occurredAt': _date(item.occurredAt),
        'confidence': item.confidence,
        'createdBy': item.createdBy.name,
        'createdAt': _date(item.createdAt),
        'notesBefore': item.notesBefore,
        'notesAfter': item.notesAfter,
      };

  static RelationshipState decodeRelationship(Map<String, dynamic> json) =>
      RelationshipState(
        id: _string(json, 'id'),
        groupId: _string(json, 'groupId'),
        sourceCharacterId: _string(json, 'sourceCharacterId'),
        targetId: _string(json, 'targetId'),
        targetType: _enum(json, 'targetType', RelationshipTargetType.values),
        affinity: _integer(json, 'affinity'),
        trust: _integer(json, 'trust'),
        friction: _integer(json, 'friction'),
        familiarity: _integer(json, 'familiarity'),
        recentMood: _enum(json, 'recentMood', RelationshipMood.values),
        notes: json['notes']?.toString() ?? '',
        lastInteractionAt: _dateTime(json, 'lastInteractionAt'),
        createdAt: _dateTime(json, 'createdAt'),
        stage: _optionalEnum(
              json['stage'],
              RelationshipStage.values,
            ) ??
            RelationshipStage.stranger,
        revision: (json['revision'] as num?)?.toInt() ?? 0,
        lastEventId: json['lastEventId']?.toString(),
        updatedAt: _optionalDate(json['updatedAt']) ??
            _dateTime(json, 'lastInteractionAt'),
      );

  static UserProfile decodeUserProfile(Map<String, dynamic> json) =>
      UserProfile(
        id: _string(json, 'id'),
        displayName: _string(json, 'displayName'),
        preferredAddress: _string(json, 'preferredAddress'),
        avatar: _string(json, 'avatar'),
        pronouns: json['pronouns']?.toString() ?? '',
        age: (json['age'] as num?)?.toInt(),
        bio: _string(json, 'bio'),
        personality: _strings(json['personality']),
        interests: _strings(json['interests']),
        importantBackground: _strings(json['importantBackground']),
        updatedAt: _dateTime(json, 'updatedAt'),
        createdAt: _dateTime(json, 'createdAt'),
      );

  static PermanentMemory decodePermanentMemory(
    Map<String, dynamic> json,
  ) =>
      PermanentMemory(
        id: _string(json, 'id'),
        observerCharacterId: _string(json, 'observerCharacterId'),
        kind: _enum(json, 'kind', MemoryKind.values),
        content: _string(json, 'content'),
        subjectIds: _strings(json['subjectIds']),
        status: _enum(json, 'status', MemoryStatus.values),
        importance: (json['importance'] as num?)?.toInt() ?? 50,
        confidence: (json['confidence'] as num?)?.toDouble() ?? 1.0,
        explicitlyRequested: json['explicitlyRequested'] as bool? ?? false,
        pinned: json['pinned'] as bool? ?? false,
        supersedesIds: _strings(json['supersedesIds']),
        originType: _enum(json, 'originType', MemoryOriginType.values),
        originConversationId: json['originConversationId']?.toString(),
        originNameSnapshot: _string(json, 'originNameSnapshot'),
        sourceMessageIds: _strings(json['sourceMessageIds']),
        participantIds: _strings(json['participantIds']),
        occurredAt: _dateTime(json, 'occurredAt'),
        createdAt: _dateTime(json, 'createdAt'),
        updatedAt: _dateTime(json, 'updatedAt'),
        invalidationReason: json['invalidationReason']?.toString(),
      );

  static RelationshipEvent decodeRelationshipEvent(
    Map<String, dynamic> json,
  ) =>
      RelationshipEvent(
        id: _string(json, 'id'),
        sourceCharacterId: _string(json, 'sourceCharacterId'),
        targetType: _enum(json, 'targetType', RelationshipTargetType.values),
        targetId: _string(json, 'targetId'),
        reason: _string(json, 'reason'),
        affinityBefore: _integer(json, 'affinityBefore'),
        affinityAfter: _integer(json, 'affinityAfter'),
        trustBefore: _integer(json, 'trustBefore'),
        trustAfter: _integer(json, 'trustAfter'),
        frictionBefore: _integer(json, 'frictionBefore'),
        frictionAfter: _integer(json, 'frictionAfter'),
        familiarityBefore: _integer(json, 'familiarityBefore'),
        familiarityAfter: _integer(json, 'familiarityAfter'),
        moodBefore: _enum(json, 'moodBefore', RelationshipMood.values),
        moodAfter: _enum(json, 'moodAfter', RelationshipMood.values),
        stageBefore: _enum(json, 'stageBefore', RelationshipStage.values),
        stageAfter: _enum(json, 'stageAfter', RelationshipStage.values),
        originConversationId: json['originConversationId']?.toString(),
        originNameSnapshot: _string(json, 'originNameSnapshot'),
        sourceMessageIds: _strings(json['sourceMessageIds']),
        revision: _integer(json, 'revision'),
        occurredAt: _dateTime(json, 'occurredAt'),
        confidence: (json['confidence'] as num?)?.toDouble() ?? 1.0,
        createdBy: _enum(json, 'createdBy', RelationshipEventCreator.values),
        createdAt: _dateTime(json, 'createdAt'),
        notesBefore: json['notesBefore']?.toString() ?? '',
        notesAfter: json['notesAfter']?.toString() ?? '',
      );

  static Map<String, dynamic> skill(CharacterSkill item) => {
        'id': item.id,
        'characterId': item.characterId,
        'name': item.name,
        'domain': item.domain,
        'description': item.description,
        'instructions': item.instructions,
        'requiredPermissions':
            item.requiredPermissions.map((item) => item.name).toList(),
        'createdAt': _date(item.createdAt),
        'updatedAt': _date(item.updatedAt),
      };

  static CharacterSkill decodeSkill(Map<String, dynamic> json) =>
      CharacterSkill(
        id: _string(json, 'id'),
        characterId: _string(json, 'characterId'),
        name: _string(json, 'name'),
        domain: _string(json, 'domain'),
        description: _string(json, 'description'),
        instructions: _strings(json['instructions']),
        requiredPermissions:
            _enums(json['requiredPermissions'], ToolPermission.values),
        createdAt: _dateTime(json, 'createdAt'),
        updatedAt: _dateTime(json, 'updatedAt'),
      );

  static Map<String, dynamic> task(AgentTask item) => {
        'id': item.id,
        'groupId': item.groupId,
        'characterId': item.characterId,
        'userRequest': _safeTaskText(item.userRequest),
        'status': item.status.name,
        'requestedPermissions':
            item.requestedPermissions.map((item) => item.name).toList(),
        'plan': _safeTaskText(item.plan),
        'resultSummary': _safeTaskText(item.resultSummary),
        'createdAt': _date(item.createdAt),
        'currentStep': item.currentStep,
        // Tool checkpoints are intentionally redacted before backup. File
        // contents and shell commands must never leave the durable boundary.
        'completedOperations': item.completedOperations
            .map(_portableCompletedOperation)
            .where((value) => value.isNotEmpty)
            .toList(growable: false),
        // A pending approval is an in-process capability. Keep only a
        // display-safe tool marker; the original path, command and payload
        // must be re-planned after import on the destination device.
        'pendingToolRequestJson':
            _portableToolCheckpoint(item.pendingToolRequestJson),
        'updatedAt': item.updatedAt?.toIso8601String(),
        'lastError': _safeTaskText(item.lastError),
        'workModeTask': item.workModeTask,
        'queuedUserRequests': item.queuedUserRequests
            .map((request) => _safeTaskText(request))
            .where((request) => request.isNotEmpty)
            .toList(growable: false),
        'contextSummary': _safeTaskContextSummary(item.contextSummary),
        'assignedCharacterIds': item.assignedCharacterIds,
        'startedAt': item.startedAt?.toIso8601String(),
        'actionCount': item.actionCount,
        'softLimitReached': item.softLimitReached,
        'resumeRequired': item.resumeRequired,
        // Only restart-safe display state is portable. Approval scopes,
        // resource locks, snapshots, tool results and committed operation
        // keys are capabilities or local evidence and must never cross the
        // backup boundary.
        'executionStateJson': _safeExecutionStateJson(item.executionStateJson),
        // Artifact paths are portable workspace-relative names. Absolute and
        // traversal paths are discarded rather than reduced to a basename;
        // a basename can still disclose a private filename and is not a
        // resolvable portable target.
        'lastArtifactPaths': item.lastArtifactPaths
            .map(_portableArtifactPath)
            .where((path) => path.isNotEmpty)
            .toList(growable: false),
        'actionLimit': item.actionLimit,
        'softTimeLimitMinutes': item.softTimeLimitMinutes,
        'eventLogIncomplete': item.eventLogIncomplete,
      };

  static AgentTask decodeTask(Map<String, dynamic> json) => AgentTask(
        id: _string(json, 'id'),
        groupId: _string(json, 'groupId'),
        characterId: _string(json, 'characterId'),
        userRequest: _safeTaskText(_string(json, 'userRequest')),
        status: _enum(json, 'status', AgentTaskStatus.values),
        requestedPermissions:
            _enums(json['requestedPermissions'], ToolPermission.values),
        plan: _safeTaskText(json['plan']?.toString() ?? ''),
        resultSummary: _safeTaskText(json['resultSummary']?.toString() ?? ''),
        createdAt: _dateTime(json, 'createdAt'),
        currentStep: (json['currentStep'] as num?)?.toInt() ?? 0,
        completedOperations: _strings(json['completedOperations'])
            .map(_portableCompletedOperation)
            .where((value) => value.isNotEmpty)
            .toList(growable: false),
        pendingToolRequestJson: _portableToolCheckpoint(
          json['pendingToolRequestJson']?.toString() ?? '',
        ),
        updatedAt: _optionalDate(json['updatedAt']),
        lastError: _safeTaskText(json['lastError']?.toString() ?? ''),
        workModeTask: json['workModeTask'] as bool? ?? false,
        queuedUserRequests: _strings(json['queuedUserRequests'])
            .map(_safeTaskText)
            .where((request) => request.isNotEmpty)
            .toList(growable: false),
        contextSummary: _safeTaskContextSummary(
          json['contextSummary']?.toString() ?? '',
        ),
        assignedCharacterIds: _strings(json['assignedCharacterIds']),
        startedAt: _optionalDate(json['startedAt']),
        actionCount: (json['actionCount'] as num?)?.toInt() ?? 0,
        softLimitReached: json['softLimitReached'] as bool? ?? false,
        resumeRequired: json['resumeRequired'] as bool? ?? false,
        // Backups may come from an older build or an untrusted file. Apply
        // the same capability and portability boundary on import as on
        // export, so a crafted archive cannot reintroduce a stale approval,
        // local path or tool result into a restored task.
        executionStateJson: _safeExecutionStateJson(
          json['executionStateJson']?.toString() ?? '',
        ),
        lastArtifactPaths: _strings(json['lastArtifactPaths'])
            .map(_portableArtifactPath)
            .where((path) => path.isNotEmpty)
            .toList(growable: false),
        actionLimit: (json['actionLimit'] as num?)?.toInt() ??
            AgentTask.defaultActionLimit,
        softTimeLimitMinutes: (json['softTimeLimitMinutes'] as num?)?.toInt() ??
            AgentTask.defaultSoftTimeLimitMinutes,
        eventLogIncomplete: json['eventLogIncomplete'] as bool? ?? false,
      );

  static Map<String, dynamic> workspace(WorkModeWorkspace item) => {
        'id': item.id,
        'conversationId': item.conversationId,
        'conversationType': item.conversationType,
        'updatedAt': _date(item.updatedAt),
      };

  static WorkModeWorkspace decodeWorkspace(Map<String, dynamic> json) =>
      WorkModeWorkspace(
        id: _string(json, 'id'),
        conversationId: _string(json, 'conversationId'),
        conversationType: _string(json, 'conversationType'),
        // Device-local workspace paths are intentionally not portable.
        workDirPath: '',
        updatedAt: _dateTime(json, 'updatedAt'),
      );
}

String _portableArtifactPath(String raw) {
  final normalized = raw.trim().replaceAll('\\', '/');
  if (normalized.isEmpty) return '';
  // Treat every drive-qualified value as device-local, including Windows
  // drive-relative `C:foo` paths. Reject dot/empty segments and URI-like
  // first components so a future restore cannot reinterpret a display value
  // as an absolute or external target.
  if (normalized.startsWith('/') ||
      RegExp(r'^[A-Za-z]:').hasMatch(normalized)) {
    return '';
  }
  final segments = normalized.split('/');
  if (segments
      .any((segment) => segment.isEmpty || segment == '.' || segment == '..')) {
    return '';
  }
  if (RegExp(r'^[A-Za-z][A-Za-z0-9+.-]*:').hasMatch(normalized) ||
      normalized.contains('\u0000')) {
    return '';
  }
  return normalized;
}

String _portableCompletedOperation(String raw) {
  final checkpoint = _portableToolCheckpoint(raw);
  if (checkpoint.isNotEmpty) return checkpoint;
  // Opaque legacy operation strings may contain command output, file content,
  // credentials, or device paths. They are local evidence rather than
  // restart state, so keep only a redacted marker across the portable boundary.
  return '{"kind":"legacyOperation","redacted":true}';
}

String _portableToolCheckpoint(String raw) {
  if (raw.trim().isEmpty) return '';
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return '';
    final tool = AgentToolName.fromWire(decoded['tool']?.toString() ?? '');
    if (tool == null) return '';
    final args = decoded['args'];
    final safeArgs = <String, dynamic>{};
    if (args is Map) {
      final map = Map<String, dynamic>.from(args);
      final content = map['content'];
      if (content is String) safeArgs['contentLength'] = content.length;
      if (map['command'] is String &&
          (map['command'] as String).trim().isNotEmpty) {
        safeArgs['commandPresent'] = true;
      }
      if (map['overwrite'] is bool) safeArgs['overwrite'] = map['overwrite'];
      if (map['recursive'] is bool) safeArgs['recursive'] = map['recursive'];
      if (map['permissions'] is List) {
        safeArgs['permissionCount'] = (map['permissions'] as List).length;
      }
      if (map['url'] is String) safeArgs['urlPresent'] = true;
      for (final key in const ['startByte', 'byteLength']) {
        final value = map[key];
        if (value is num) safeArgs[key] = value.toInt().clamp(0, 1 << 31);
      }
    }
    return jsonEncode(<String, dynamic>{
      'tool': tool.wireName,
      'reason': '已记录 ${tool.wireName} 操作',
      'args': safeArgs,
    });
  } on Object {
    return '';
  }
}

String _safeTaskContextSummary(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return '';
  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is Map) {
      final safe = _safeContextMap(Map<String, dynamic>.from(decoded), 0);
      return _boundedJson(safe, 4000);
    }
  } on Object {
    // Legacy summaries were plain text. Fall through to the same redaction
    // used for task prose instead of rejecting an otherwise restorable task.
  }
  return _safeTaskText(trimmed, maximum: 4000);
}

const _portableExecutionKeys = <String>{
  'phase',
  'followupkind',
  'followupreason',
  'clarificationquestion',
  'autorenameifexists',
  'foldergrantpending',
  'folderrequireswritable',
  'explicitcommandrequestrequired',
  'visionmodelrequired',
  'visionmodelprovider',
  'visionmodel',
};

// Kept separate from safeToolRequestCheckpointJson: that helper is the
// in-app restart checkpoint and intentionally retains display-only fields.
// Portable backups need a stricter allow-list because they are transportable
// outside the trusted app-support directory.
String _safeExecutionStateJson(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return '';
  try {
    final decoded = jsonDecode(trimmed);
    if (decoded is! Map) return '';
    final result = <String, dynamic>{};
    for (final entry in decoded.entries) {
      final key = entry.key.toString();
      final normalized = key.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
      if (!_portableExecutionKeys.contains(normalized)) continue;
      final value = entry.value;
      if (value is bool || value is num) {
        result[key] = value;
      } else if (value is String) {
        result[key] = _safeTaskText(value, maximum: 512);
      }
    }
    return result.isEmpty ? '' : jsonEncode(result);
  } on Object {
    return '';
  }
}

const _nonPortableContextKeys = <String>{
  'approvalscope',
  'artifactpaths',
  'artifacts',
  'recenttoolresults',
  'rolehandoff',
  'handoff',
  'workingdirectory',
  'snapshot',
  'snapshotpath',
  'eventlog',
  'governance',
  'path',
  'paths',
  'targetpath',
  'originalpath',
  'command',
  'content',
  'body',
  'stdout',
  'stderr',
  'response',
  'data',
};

dynamic _safeContextValue(Object? value, int depth) {
  if (depth > 3) return null;
  if (value == null || value is bool || value is num) return value;
  if (value is String) return _safeTaskText(value, maximum: 512);
  if (value is Iterable) {
    return value
        .take(32)
        .map((item) => _safeContextValue(item, depth + 1))
        .where((item) => item != null)
        .toList(growable: false);
  }
  if (value is Map) {
    return _safeContextMap(Map<String, dynamic>.from(value), depth + 1);
  }
  return null;
}

Map<String, dynamic> _safeContextMap(Map<String, dynamic> source, int depth) {
  final result = <String, dynamic>{};
  if (depth > 3) return result;
  for (final entry in source.entries.take(32)) {
    final rawKey = entry.key.toString();
    final normalized =
        rawKey.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (_nonPortableContextKeys.contains(normalized)) continue;
    // Context keys are untrusted legacy/model data too. Keep ordinary field
    // names intact, but redact a path, URL, or token if one was used as a key.
    final key = _safeTaskText(rawKey, maximum: 128);
    if (key.isEmpty) continue;
    final safeValue = _safeContextValue(entry.value, depth);
    if (safeValue != null) result[key] = safeValue;
  }
  return result;
}

String _boundedJson(Object value, int maximum) {
  final encoded = jsonEncode(value);
  return encoded.length <= maximum
      ? encoded
      : '${encoded.substring(0, maximum - 1)}…';
}

String _safeTaskText(String raw, {int maximum = 2048}) {
  var safe = const SearchSecretScanner().redact(
    raw.trim(),
    includeOpaqueTokens: true,
  );
  safe = safe.replaceAll(
      RegExp(r'https?://[^\s,;）)]+', caseSensitive: false), '[外部地址]');
  safe = safe.replaceAll(
    RegExp(
      r'(?:(?:[A-Za-z]:[\\/])|(?:\\\\|//)|/)[^\s,;）)]*',
    ),
    '[本地路径]',
  );
  return safe.length <= maximum ? safe : '${safe.substring(0, maximum - 1)}…';
}

String _string(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String) throw FormatException('字段 $key 无效');
  return value;
}

int _integer(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! num) throw FormatException('字段 $key 无效');
  return value.toInt();
}

String _date(DateTime value) => value.toUtc().toIso8601String();

DateTime _dateTime(Map<String, dynamic> json, String key) =>
    DateTime.parse(_string(json, key));

DateTime? _optionalDate(Object? value) =>
    value == null ? null : DateTime.parse(value.toString());

List<String> _strings(Object? value) {
  if (value is! List) return const [];
  final result = <String>[];
  for (final item in value) {
    if (item is String) {
      result.add(item);
    }
  }
  return result;
}

T _enum<T extends Enum>(
  Map<String, dynamic> json,
  String key,
  List<T> values,
) {
  final raw = json[key];
  if (raw == null) {
    throw FormatException('字段 $key 缺失');
  }
  final name = raw.toString();
  final found = values.where((item) => item.name == name);
  if (found.isEmpty) {
    throw FormatException('字段 $key 值 "$name" 不在已知枚举 $values 中');
  }
  return found.first;
}

T? _optionalEnum<T extends Enum>(Object? raw, List<T> values) {
  if (raw == null) return null;
  final name = raw.toString();
  final found = values.where((item) => item.name == name);
  if (found.isEmpty) {
    throw FormatException('枚举值 "$name" 不在已知枚举 $values 中');
  }
  return found.first;
}

CharacterGender? _decodeGender(Object? raw) {
  if (raw is! String) return null;
  for (final gender in CharacterGender.values) {
    if (gender.name == raw) return gender;
  }
  return null;
}

List<T> _enums<T extends Enum>(Object? value, List<T> values) {
  final strings = _strings(value);
  if (strings.isEmpty || values.isEmpty) return const [];
  return strings.map((name) {
    final found = values.where((item) => item.name == name);
    if (found.isEmpty) {
      throw FormatException('枚举值 "$name" 不在已知枚举 $values 中');
    }
    return found.first;
  }).toList();
}

String _publicUrl(String value) {
  if (value.isEmpty) return '';
  final uri = Uri.tryParse(value);
  if (uri == null) return '';
  const scanner = SearchSecretScanner();
  if (uri.userInfo.isNotEmpty ||
      scanner.containsSensitiveData(uri.host) ||
      scanner.containsSensitiveData(uri.path)) {
    return '';
  }
  const secretParameters = {
    'key',
    'apikey',
    'legacyapikey',
    'credential',
    'credentialid',
    'token',
    'accesstoken',
    'authorization',
    'secret',
    'password',
  };
  final query = Map<String, List<String>>.from(uri.queryParametersAll)
    ..removeWhere((key, values) {
      final normalized = key.toLowerCase().replaceAll('_', '');
      return secretParameters.contains(normalized) ||
          scanner.isSensitiveParameter(key) ||
          values.any(scanner.containsSensitiveData);
    });
  final sanitized = uri
      .replace(userInfo: '', queryParameters: query, fragment: '')
      .toString();
  return sanitized.endsWith('#')
      ? sanitized.substring(0, sanitized.length - 1)
      : sanitized;
}

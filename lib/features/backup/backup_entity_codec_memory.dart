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
        'userRequest': item.userRequest,
        'status': item.status.name,
        'requestedPermissions':
            item.requestedPermissions.map((item) => item.name).toList(),
        'plan': item.plan,
        'resultSummary': item.resultSummary,
        'createdAt': _date(item.createdAt),
        'currentStep': item.currentStep,
        // Tool checkpoints are intentionally redacted before backup. File
        // contents and shell commands must never leave the durable boundary.
        'completedOperations': item.completedOperations
            .map(safeToolRequestCheckpointJson)
            .where((value) => value.isNotEmpty)
            .toList(growable: false),
        'pendingToolRequestJson':
            safeToolRequestCheckpointJson(item.pendingToolRequestJson),
        'updatedAt': item.updatedAt?.toIso8601String(),
        'lastError': item.lastError,
        'workModeTask': item.workModeTask,
        'queuedUserRequests': item.queuedUserRequests,
        'contextSummary': _safeTaskContextSummary(item.contextSummary),
        'assignedCharacterIds': item.assignedCharacterIds,
        'startedAt': item.startedAt?.toIso8601String(),
        'actionCount': item.actionCount,
        'softLimitReached': item.softLimitReached,
        'resumeRequired': item.resumeRequired,
        'executionStateJson': item.executionStateJson,
        // Artifact paths are portable workspace-relative names. Never export
        // a machine-specific absolute path (which would leak usernames and
        // cannot be resolved on another device).
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
        userRequest: _string(json, 'userRequest'),
        status: _enum(json, 'status', AgentTaskStatus.values),
        requestedPermissions:
            _enums(json['requestedPermissions'], ToolPermission.values),
        plan: json['plan']?.toString() ?? '',
        resultSummary: json['resultSummary']?.toString() ?? '',
        createdAt: _dateTime(json, 'createdAt'),
        currentStep: (json['currentStep'] as num?)?.toInt() ?? 0,
        completedOperations: _strings(json['completedOperations']),
        pendingToolRequestJson:
            json['pendingToolRequestJson']?.toString() ?? '',
        updatedAt: _optionalDate(json['updatedAt']),
        lastError: json['lastError']?.toString() ?? '',
        workModeTask: json['workModeTask'] as bool? ?? false,
        queuedUserRequests: _strings(json['queuedUserRequests']),
        contextSummary: json['contextSummary']?.toString() ?? '',
        assignedCharacterIds: _strings(json['assignedCharacterIds']),
        startedAt: _optionalDate(json['startedAt']),
        actionCount: (json['actionCount'] as num?)?.toInt() ?? 0,
        softLimitReached: json['softLimitReached'] as bool? ?? false,
        resumeRequired: json['resumeRequired'] as bool? ?? false,
        executionStateJson: json['executionStateJson']?.toString() ?? '',
        // Backups may come from an older build or an untrusted file. Apply
        // the same portability boundary on import as on export so an
        // absolute path cannot be reintroduced into a restored task.
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
  final absolute =
      normalized.startsWith('/') || RegExp(r'^[A-Za-z]:/').hasMatch(normalized);
  if (absolute) {
    final segments = normalized.split('/').where((part) => part.isNotEmpty);
    return segments.isEmpty ? '' : segments.last;
  }
  if (normalized.split('/').contains('..')) return '';
  return normalized;
}

String _safeTaskContextSummary(String raw) {
  var safe = const SearchSecretScanner().redact(
    raw.trim(),
    includeOpaqueTokens: true,
  );
  safe = safe.replaceAll(RegExp(r'https?://[^\s,;）)]+'), '[外部地址]');
  safe = safe.replaceAll(
    RegExp(
      r'(?:(?:[A-Za-z]:[\\/])|/(?:Users|home|Volumes|private|tmp)/)[^\s,;）)]*',
    ),
    '[本地路径]',
  );
  return safe.length <= 4000 ? safe : '${safe.substring(0, 3999)}…';
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

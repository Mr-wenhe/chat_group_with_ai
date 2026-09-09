import 'dart:async';
import 'dart:convert';

import 'package:chat_group/core/models/agent_task.dart';

/// A model may return a smaller public checkpoint, but it can never change the
/// conversation that owns the checkpoint.
typedef WorkContextCompressionModel = FutureOr<WorkContextSnapshot?> Function(
    WorkContextSnapshot context);

/// The only data that is allowed to cross the work-task persistence boundary.
/// File contents and raw model/tool payloads deliberately have no field here.
class WorkContextSnapshot {
  final int schemaVersion;
  final String conversationId;
  final String target;
  final List<String> pendingFollowUps;
  final List<String> completedSummaries;
  final List<Map<String, dynamic>> recentToolResults;
  final Map<String, dynamic>? approvalScope;
  final List<String> artifactPaths;
  final Map<String, dynamic>? roleHandoff;
  final List<String> errors;
  final String nextStep;

  WorkContextSnapshot({
    this.schemaVersion = 1,
    required this.conversationId,
    this.target = '',
    Iterable<String> pendingFollowUps = const [],
    Iterable<String> completedSummaries = const [],
    Iterable<Map<String, dynamic>> recentToolResults = const [],
    Map<String, dynamic>? approvalScope,
    Iterable<String> artifactPaths = const [],
    Map<String, dynamic>? roleHandoff,
    Iterable<String> errors = const [],
    this.nextStep = '',
  })  : pendingFollowUps = List.unmodifiable(pendingFollowUps),
        completedSummaries = List.unmodifiable(completedSummaries),
        recentToolResults = List.unmodifiable(
          recentToolResults.map(
            (item) => Map<String, dynamic>.unmodifiable(item),
          ),
        ),
        approvalScope = approvalScope == null
            ? null
            : Map<String, dynamic>.unmodifiable(approvalScope),
        artifactPaths = List.unmodifiable(artifactPaths),
        roleHandoff = roleHandoff == null
            ? null
            : Map<String, dynamic>.unmodifiable(roleHandoff),
        errors = List.unmodifiable(errors);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'schemaVersion': schemaVersion,
        'conversationId': conversationId,
        'target': target,
        'pendingFollowUps': pendingFollowUps,
        'completedSummaries': completedSummaries,
        'recentToolResults': recentToolResults,
        'approvalScope': approvalScope,
        'artifactPaths': artifactPaths,
        'roleHandoff': roleHandoff,
        'errors': errors,
        'nextStep': nextStep,
      };

  String toJsonString() => jsonEncode(toJson());

  factory WorkContextSnapshot.fromJson(
    Map<String, dynamic> json, {
    String? expectedConversationId,
  }) {
    final conversationId = json['conversationId'];
    if (conversationId is! String || conversationId.trim().isEmpty) {
      throw const FormatException('工作上下文缺少 conversationId');
    }
    if (expectedConversationId != null &&
        conversationId != expectedConversationId) {
      throw const FormatException('工作上下文 conversationId 不匹配');
    }
    final version = json['schemaVersion'];
    return WorkContextSnapshot(
      schemaVersion: version is num ? version.toInt() : 1,
      conversationId: conversationId,
      target: WorkContextBuilder._stringValue(json['target']),
      pendingFollowUps:
          WorkContextBuilder._stringList(json['pendingFollowUps']),
      completedSummaries:
          WorkContextBuilder._stringList(json['completedSummaries']),
      recentToolResults: WorkContextBuilder._mapList(json['recentToolResults']),
      approvalScope: WorkContextBuilder._mapValue(json['approvalScope']),
      artifactPaths: WorkContextBuilder._stringList(json['artifactPaths']),
      roleHandoff: WorkContextBuilder._mapValue(json['roleHandoff']),
      errors: WorkContextBuilder._stringList(json['errors']),
      nextStep: WorkContextBuilder._stringValue(json['nextStep']),
    );
  }

  WorkContextSnapshot copyWith({
    int? schemaVersion,
    String? conversationId,
    String? target,
    Iterable<String>? pendingFollowUps,
    Iterable<String>? completedSummaries,
    Iterable<Map<String, dynamic>>? recentToolResults,
    Map<String, dynamic>? approvalScope,
    bool clearApprovalScope = false,
    Iterable<String>? artifactPaths,
    Map<String, dynamic>? roleHandoff,
    bool clearRoleHandoff = false,
    Iterable<String>? errors,
    String? nextStep,
  }) {
    return WorkContextSnapshot(
      schemaVersion: schemaVersion ?? this.schemaVersion,
      conversationId: conversationId ?? this.conversationId,
      target: target ?? this.target,
      pendingFollowUps: pendingFollowUps ?? this.pendingFollowUps,
      completedSummaries: completedSummaries ?? this.completedSummaries,
      recentToolResults: recentToolResults ?? this.recentToolResults,
      approvalScope:
          clearApprovalScope ? null : approvalScope ?? this.approvalScope,
      artifactPaths: artifactPaths ?? this.artifactPaths,
      roleHandoff: clearRoleHandoff ? null : roleHandoff ?? this.roleHandoff,
      errors: errors ?? this.errors,
      nextStep: nextStep ?? this.nextStep,
    );
  }
}

/// Builds and restores bounded, public work checkpoints.
class WorkContextBuilder {
  static const int defaultMaxCharacters = 12000;
  static const double defaultCompressionTriggerRatio = 0.8;

  final int maxCharacters;

  const WorkContextBuilder({this.maxCharacters = defaultMaxCharacters})
      : assert(maxCharacters > 0);

  /// Semantic compression is only attempted when the bounded checkpoint is
  /// close to its budget. Small checkpoints stay byte-for-byte deterministic
  /// and do not spend another model request.
  bool shouldCompress(WorkContextSnapshot snapshot) {
    return _encodedLength(_normalise(snapshot)) >=
        (maxCharacters * defaultCompressionTriggerRatio).ceil();
  }

  WorkContextSnapshot build({
    required String conversationId,
    required String target,
    Iterable<String> pendingFollowUps = const [],
    Iterable<String> completedSummaries = const [],
    Iterable<Map<String, dynamic>> recentToolResults = const [],
    Map<String, dynamic>? approvalScope,
    Iterable<String> artifactPaths = const [],
    Map<String, dynamic>? roleHandoff,
    Iterable<String> errors = const [],
    String nextStep = '',
  }) {
    final owner = conversationId.trim();
    if (owner.isEmpty) {
      throw ArgumentError.value(conversationId, 'conversationId', '不能为空');
    }
    final snapshot = WorkContextSnapshot(
      conversationId: owner,
      target: _cleanText(target),
      pendingFollowUps: _cleanStrings(pendingFollowUps),
      completedSummaries: _cleanSummaries(completedSummaries),
      recentToolResults:
          recentToolResults.map(_safeToolResult).toList(growable: false),
      approvalScope: _safeMap(approvalScope),
      artifactPaths: _cleanPaths(artifactPaths),
      roleHandoff: _safeRoleHandoff(roleHandoff),
      errors: _cleanStrings(errors),
      nextStep: _cleanText(nextStep),
    );
    return _clip(snapshot);
  }

  /// Reconstructs a checkpoint from a durable [AgentTask]. Legacy summaries
  /// are read only through an allow-list; the task's queue and artifact fields
  /// remain authoritative so a stale summary cannot redirect a revision.
  WorkContextSnapshot fromTask(AgentTask task) {
    final decoded = _decode(task.contextSummary);
    final sameConversation = decoded['conversationId'] == task.groupId;
    final source = sameConversation ? decoded : const <String, dynamic>{};
    final rawPending = task.queuedUserRequests.isNotEmpty
        ? task.queuedUserRequests
        : _stringList(source['pendingFollowUps']);
    final rawArtifacts = task.lastArtifactPaths.isNotEmpty
        ? task.lastArtifactPaths
        : _stringList(source['artifactPaths'] ?? source['artifacts']);
    final completed = _stringList(source['completedSummaries']);
    final legacyActions = source['completedActions'];
    final completedWithLegacy = completed.isNotEmpty
        ? completed
        : legacyActions is List
            ? legacyActions.whereType<String>()
            : const <String>[];
    return build(
      conversationId: task.groupId,
      target: _stringValue(source['target'] ?? source['goal']).isNotEmpty
          ? _stringValue(source['target'] ?? source['goal'])
          : task.userRequest,
      pendingFollowUps: rawPending,
      completedSummaries: completedWithLegacy,
      recentToolResults: _mapList(source['recentToolResults']),
      approvalScope:
          _mapValue(source['approvalScope'] ?? source['approvedScope']),
      artifactPaths: rawArtifacts,
      roleHandoff: _mapValue(source['roleHandoff'] ?? source['handoff']),
      errors: _stringList(source['errors']),
      nextStep: _stringValue(source['nextStep']),
    );
  }

  /// Alias kept explicit for call sites that describe this as a task build.
  WorkContextSnapshot buildFromTask(AgentTask task) => fromTask(task);

  WorkContextSnapshot restore(
    String raw, {
    required String conversationId,
  }) {
    if (conversationId.trim().isEmpty) {
      throw ArgumentError.value(conversationId, 'conversationId', '不能为空');
    }
    if (raw.trim().isEmpty) {
      return WorkContextSnapshot(conversationId: conversationId);
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) throw const FormatException('工作上下文不是 JSON object');
      final parsed = WorkContextSnapshot.fromJson(
        Map<String, dynamic>.from(decoded),
        expectedConversationId: conversationId,
      );
      // Restore is another persistence boundary. Re-run the same allow-list
      // and file-body redaction used when the checkpoint was first built;
      // otherwise a hand-written/legacy JSON payload could bypass it.
      return _normalise(parsed);
    } on FormatException {
      rethrow;
    } on Object catch (error) {
      throw FormatException('工作上下文无法恢复：$error');
    }
  }

  Future<WorkContextSnapshot> compress(
    WorkContextSnapshot snapshot, {
    WorkContextCompressionModel? model,
  }) async {
    final safe = _clip(_normalise(snapshot));
    if (model != null) {
      try {
        final compressed = await model(safe);
        if (compressed != null &&
            compressed.conversationId == safe.conversationId) {
          // A summary model is allowed to shorten diagnostics, never to omit
          // the fields needed to resume safely after a restart.
          final preserved = compressed.copyWith(
            // These fields are execution state, not model prose. Keep the
            // pre-compression values even if a model returns replacements;
            // otherwise a bad summary could redirect a revision or drop a
            // pending user request while still looking like valid JSON.
            target: safe.target,
            pendingFollowUps: safe.pendingFollowUps,
            approvalScope: safe.approvalScope,
            clearApprovalScope: safe.approvalScope == null,
            artifactPaths: safe.artifactPaths,
            roleHandoff: safe.roleHandoff,
            clearRoleHandoff: safe.roleHandoff == null,
            errors: safe.errors,
            nextStep: safe.nextStep,
          );
          return _clip(_normalise(preserved));
        }
      } on Object {
        // Deterministic clipping is the recovery path. It must not clear the
        // queue or the approval/path fields when a summary model is down.
      }
    }
    return _clip(safe);
  }

  Future<WorkContextSnapshot> compressIfNeeded(
    WorkContextSnapshot snapshot, {
    WorkContextCompressionModel? model,
  }) async {
    final safe = _normalise(snapshot);
    if (!shouldCompress(safe)) return safe;
    return compress(safe, model: model);
  }

  WorkContextSnapshot _normalise(WorkContextSnapshot snapshot) => build(
        conversationId: snapshot.conversationId,
        target: snapshot.target,
        pendingFollowUps: snapshot.pendingFollowUps,
        completedSummaries: snapshot.completedSummaries,
        recentToolResults: snapshot.recentToolResults,
        approvalScope: snapshot.approvalScope,
        artifactPaths: snapshot.artifactPaths,
        roleHandoff: snapshot.roleHandoff,
        errors: snapshot.errors,
        nextStep: snapshot.nextStep,
      );

  WorkContextSnapshot _clip(WorkContextSnapshot source) {
    var result = source.copyWith(
      conversationId: source.conversationId.trim(),
      target: _clipText(source.target, 512),
      pendingFollowUps: _newestFitting(source.pendingFollowUps, 512),
      completedSummaries: _tail(source.completedSummaries, 16),
      recentToolResults: _tailMaps(source.recentToolResults, 8),
      approvalScope: _safeMap(source.approvalScope),
      artifactPaths: _cleanPaths(source.artifactPaths),
      roleHandoff: _safeRoleHandoff(source.roleHandoff),
      errors: _tail(source.errors, 16),
      nextStep: _clipText(source.nextStep, 512),
    );
    if (_encodedLength(result) <= maxCharacters) return result;

    // Optional diagnostics are removed before required target/queue/scope/path
    // data. This order is intentionally deterministic for restart/retry parity.
    result = result.copyWith(recentToolResults: const []);
    if (_encodedLength(result) > maxCharacters) {
      result = result.copyWith(completedSummaries: const []);
    }
    if (_encodedLength(result) > maxCharacters) {
      result = result.copyWith(errors: const []);
    }
    if (_encodedLength(result) > maxCharacters) {
      // Handoff state is a capability boundary just like approvalScope. Keep
      // the conversation/stage/role ids needed for serial recovery; compact
      // optional labels and deliverables before dropping ordinary diagnostics.
      result = result.copyWith(
        roleHandoff: result.roleHandoff == null
            ? null
            : _compactRoleHandoff(result.roleHandoff!),
        clearRoleHandoff: result.roleHandoff == null,
      );
    }
    if (_encodedLength(result) > maxCharacters) {
      result = result.copyWith(nextStep: '');
    }

    // Keep the newest queued request (the durable AgentTask queue still owns
    // the complete FIFO). Oversized old prompts must not crowd out paths or
    // approval scope in a compact checkpoint.
    while (_encodedLength(result) > maxCharacters &&
        result.pendingFollowUps.length > 1) {
      result = result.copyWith(
        pendingFollowUps:
            result.pendingFollowUps.skip(1).toList(growable: false),
      );
    }
    if (_encodedLength(result) > maxCharacters) {
      result = result.copyWith(
        target: _clipText(result.target, 128),
        nextStep: '',
      );
    }
    while (_encodedLength(result) > maxCharacters &&
        result.artifactPaths.length > 1) {
      result = result.copyWith(
        artifactPaths: result.artifactPaths.skip(1),
      );
    }
    if (_encodedLength(result) > maxCharacters) {
      result = result.copyWith(
        artifactPaths: result.artifactPaths
            .map((path) => _clipText(path, 256))
            .toList(growable: false),
      );
    }
    if (_encodedLength(result) > maxCharacters &&
        result.approvalScope != null) {
      // Approval scope is a capability, not optional diagnostics. Compact its
      // display fields before considering any further truncation so a restart
      // can never lose the exact paths that bound an approved mutation.
      result = result.copyWith(
        approvalScope: _compactApprovalScope(result.approvalScope!),
      );
    }
    if (_encodedLength(result) > maxCharacters) {
      result = result.copyWith(target: _clipText(result.target, 32));
    }
    if (_encodedLength(result) > maxCharacters &&
        result.pendingFollowUps.isNotEmpty) {
      // Keep the newest actionable follow-up, even when the configured
      // diagnostic budget is unusually small. AgentTask remains the source of
      // truth for the complete FIFO after restore.
      result = result.copyWith(
        pendingFollowUps: [
          _clipText(result.pendingFollowUps.last, 128),
        ],
      );
    }
    return result;
  }

  Map<String, dynamic> _compactApprovalScope(Map<String, dynamic> scope) {
    final compact = <String, dynamic>{};
    final taskId = scope['taskId'];
    if (taskId is String && taskId.trim().isNotEmpty) {
      compact['taskId'] = _clipText(taskId, 96);
    }
    final entries = scope['entries'];
    if (entries is List) {
      compact['entries'] = entries
          .whereType<Map>()
          .take(64)
          .map((entry) {
            final value = <String, dynamic>{};
            final path = entry['path'];
            if (path is String && path.trim().isNotEmpty) {
              value['path'] = _clipText(path, 512);
            }
            final kind = entry['kind'];
            if (kind is String && kind.trim().isNotEmpty) value['kind'] = kind;
            final actions = entry['actions'];
            if (actions is List) {
              value['actions'] = actions
                  .whereType<String>()
                  .map((action) => _clipText(action, 64))
                  .take(8)
                  .toList(growable: false);
            }
            return value;
          })
          .where((entry) => entry.isNotEmpty)
          .toList(growable: false);
    }
    return compact;
  }

  Map<String, dynamic> _compactRoleHandoff(Map<String, dynamic> handoff) {
    final compact = <String, dynamic>{};
    for (final key in const [
      'conversationId',
      'schemaVersion',
      'currentStageIndex',
      'stage',
      'stageLabel',
      'currentRoleId',
      // Legacy checkpoints used currentCharacterId. Preserve it while the
      // durable handoff model migrates to role ids.
      'currentCharacterId',
      'receivingRoleId',
      'status',
    ]) {
      if (handoff.containsKey(key)) compact[key] = handoff[key];
    }
    final stages = handoff['stages'];
    if (stages is List) {
      compact['stages'] = stages
          .whereType<Map>()
          .take(32)
          .map((stage) => <String, dynamic>{
                for (final key in const ['id', 'label', 'roleId'])
                  if (stage[key] is String &&
                      (stage[key] as String).trim().isNotEmpty)
                    key: _clipText((stage[key] as String).trim(), 128),
              })
          .where((stage) => stage.isNotEmpty)
          .toList(growable: false);
    }
    return compact;
  }

  int _encodedLength(WorkContextSnapshot value) => value.toJsonString().length;

  List<String> _newestFitting(Iterable<String> values, int maximum) {
    final source = values.map((item) => _clipText(item, maximum)).toList();
    final result = <String>[];
    for (final value in source.reversed) {
      if (value.isEmpty) continue;
      result.insert(0, value);
      // A very large first item is kept only when it is the sole item; this
      // leaves room for newer, actionable follow-ups in a compact summary.
      if (result.length > 1 && result.first.length >= maximum) {
        result.removeAt(0);
      }
      if (result.length == 32) break;
    }
    return result;
  }

  List<String> _tail(Iterable<String> values, int maximum) {
    final cleaned = values.where((value) => value.trim().isNotEmpty).toList();
    return cleaned.length <= maximum
        ? cleaned
        : cleaned.skip(cleaned.length - maximum).toList(growable: false);
  }

  List<Map<String, dynamic>> _tailMaps(
    Iterable<Map<String, dynamic>> values,
    int maximum,
  ) {
    final cleaned = values.map(_safeToolResult).toList();
    return cleaned.length <= maximum
        ? cleaned
        : cleaned.skip(cleaned.length - maximum).toList(growable: false);
  }

  Map<String, dynamic> _safeToolResult(Map<String, dynamic> value) =>
      _safeMap(value) ?? const <String, dynamic>{};

  Map<String, dynamic>? _safeMap(Map<String, dynamic>? value) {
    if (value == null) return null;
    final output = <String, dynamic>{};
    for (final entry in value.entries.take(32)) {
      final key = entry.key.toString();
      // Tool output bodies are excluded from durable context. A bounded
      // install suggestion is the one actionable exception because it only
      // contains a trusted package command and display metadata.
      if (_normalisedKey(key) == 'data' && entry.value is Map) {
        final raw = Map<dynamic, dynamic>.from(entry.value as Map);
        final suggestion = raw['installSuggestion'];
        if (suggestion is Map) {
          final safeSuggestion = _safeValue(
            Map<String, dynamic>.from(suggestion),
            key: 'installSuggestion',
          );
          if (safeSuggestion is Map) {
            output[key] = {'installSuggestion': safeSuggestion};
          }
        }
        continue;
      }
      if (_normalisedKey(key) == 'rolehandoff' && entry.value is Map) {
        final handoff = _safeRoleHandoff(
          Map<String, dynamic>.from(entry.value as Map),
        );
        if (handoff != null) output[key] = handoff;
        continue;
      }
      if (_blockedKey(key)) continue;
      final clean = _safeValue(entry.value, key: key);
      if (clean != null) output[key] = clean;
    }
    return output.isEmpty ? null : output;
  }

  /// Handoff metadata is internal execution state, but the conversation id
  /// and stage fields are required to resume the next role after a restart.
  /// Keep this narrow allow-list instead of weakening the general private-key
  /// filter, which must continue to drop conversation ids from tool output.
  Map<String, dynamic>? _safeRoleHandoff(Map<String, dynamic>? value) {
    if (value == null) return null;
    final output = <String, dynamic>{};
    final conversationId = value['conversationId'];
    if (conversationId is String && conversationId.trim().isNotEmpty) {
      output['conversationId'] = _clipText(conversationId.trim(), 256);
    }
    final schemaVersion = value['schemaVersion'];
    if (schemaVersion is num) output['schemaVersion'] = schemaVersion.toInt();
    final currentStageIndex = value['currentStageIndex'];
    if (currentStageIndex is num) {
      output['currentStageIndex'] = currentStageIndex.toInt();
    }
    for (final key in const [
      'stage',
      'stageLabel',
      'currentRoleId',
      'currentCharacterId',
      'receivingRoleId',
      'status',
      'lastSummary',
    ]) {
      final item = value[key];
      if (item is String && item.trim().isNotEmpty) {
        output[key] = _clipText(item.trim(), key == 'lastSummary' ? 512 : 256);
      }
    }
    for (final key in const [
      'deliverables',
      'completionCriteria',
      'deliveredArtifacts',
    ]) {
      final item = value[key];
      if (item is List) {
        output[key] = item
            .whereType<String>()
            .map((entry) => _clipText(entry.trim(), 512))
            .where((entry) => entry.isNotEmpty)
            .take(64)
            .toList(growable: false);
      }
    }
    final stages = value['stages'];
    if (stages is List) {
      output['stages'] = stages
          .whereType<Map>()
          .take(32)
          .map((raw) => _safeHandoffStage(Map<String, dynamic>.from(raw)))
          .whereType<Map<String, dynamic>>()
          .toList(growable: false);
    }
    return output.isEmpty ? null : output;
  }

  Map<String, dynamic>? _safeHandoffStage(Map<String, dynamic> value) {
    final output = <String, dynamic>{};
    for (final key in const ['id', 'label', 'roleId']) {
      final item = value[key];
      if (item is String && item.trim().isNotEmpty) {
        output[key] = _clipText(item.trim(), 256);
      }
    }
    for (final key in const ['deliverables', 'completionCriteria']) {
      final item = value[key];
      if (item is List) {
        output[key] = item
            .whereType<String>()
            .map((entry) => _clipText(entry.trim(), 512))
            .where((entry) => entry.isNotEmpty)
            .take(32)
            .toList(growable: false);
      }
    }
    return output.isEmpty ? null : output;
  }

  Object? _safeValue(Object? value, {String? key}) {
    if (value == null || value is num || value is bool) return value;
    if (value is String) return _clipText(value, key == 'path' ? 2048 : 512);
    if (value is Map) {
      final map = <String, dynamic>{};
      for (final entry in value.entries.take(32)) {
        map[entry.key.toString()] = entry.value;
      }
      return _safeMap(map);
    }
    if (value is Iterable) {
      return value
          .take(32)
          .map((item) => _safeValue(item, key: key))
          .where((item) => item != null)
          .toList(growable: false);
    }
    return null;
  }

  List<String> _cleanStrings(Iterable<String> values) => values
      .map(_cleanText)
      .where((value) => value.isNotEmpty)
      .take(128)
      .toList(growable: false);

  List<String> _cleanSummaries(Iterable<String> values) => values
      .map(_cleanText)
      .where((value) => value.isNotEmpty)
      .map(
        (value) => value.length > 512 ||
                value.contains('```') ||
                RegExp(r'<(!DOCTYPE|html|body)\b|\b(import|class|function)\b|[{};]{3}')
                    .hasMatch(value)
            ? '文件正文已省略，后续按需重新读取产物。'
            : value,
      )
      .toSet()
      .take(128)
      .toList(growable: false);

  List<String> _cleanPaths(Iterable<String> values) => values
      .map((value) => _clipText(value.replaceAll('\\', '/').trim(), 2048))
      .where((value) =>
          value.isNotEmpty &&
          !_hasControl(value) &&
          !value.split('/').contains('..'))
      .toSet()
      .take(64)
      .toList(growable: false);

  String _cleanText(String value) {
    final cleaned =
        value.replaceAll(RegExp(r'[\u0000-\u001f\u007f]'), ' ').trim();
    return _clipText(cleaned, 4096);
  }

  String _clipText(String value, int maximum) {
    if (value.length <= maximum) return value;
    return '${value.substring(0, maximum - 1)}…';
  }

  bool _blockedKey(String key) {
    final normalized = _normalisedKey(key);
    const exact = {
      'content',
      'contents',
      'body',
      'stdout',
      'stderr',
      'script',
      'command',
      'prompt',
      'raw',
      'readbackcontent',
      'filetext',
      'fulltext',
      'text',
      'rawtext',
      'readtext',
      'filebody',
      'filecontents',
      'data',
      'output',
      'result',
      'response',
      'conversationhistory',
      'conversationid',
      'groupid',
      'messages',
      'chatmessages',
      'privatechat',
      'bytes',
      'token',
      'secret',
      'apikey',
      'authorization',
      'password',
    };
    return exact.contains(normalized) ||
        normalized.contains('content') ||
        normalized.contains('fulltext') ||
        normalized.contains('apikey') ||
        normalized.contains('secret') ||
        normalized.contains('password');
  }

  String _normalisedKey(String key) =>
      key.toLowerCase().replaceAll(RegExp(r'[_-]'), '');

  bool _hasControl(String value) =>
      value.contains(RegExp(r'[\u0000-\u001f\u007f]'));

  Map<String, dynamic> _decode(String raw) {
    if (raw.trim().isEmpty) return const <String, dynamic>{};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : const {};
    } on Object {
      return const <String, dynamic>{};
    }
  }

  static String _stringValue(Object? value) =>
      value is String ? value.trim() : '';

  static List<String> _stringList(Object? value) => value is List
      ? value.whereType<String>().map((item) => item.trim()).toList()
      : const <String>[];

  static List<Map<String, dynamic>> _mapList(Object? value) => value is List
      ? value
          .whereType<Map>()
          .map(
            (item) => <String, dynamic>{
              for (final entry in item.entries)
                entry.key.toString(): entry.value,
            },
          )
          .toList()
      : const <Map<String, dynamic>>[];

  static Map<String, dynamic>? _mapValue(Object? value) => value is Map
      ? <String, dynamic>{
          for (final entry in value.entries) entry.key.toString(): entry.value,
        }
      : null;
}

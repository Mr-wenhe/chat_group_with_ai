import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'work_collaboration_state.dart';
import 'work_task_event_store.dart';

/// Produced only by a runtime handler; never decoded from model/tool JSON data.
class WorkUsageObservation {
  final String taskId;
  final String conversationId;
  final String actorId;
  final String scenarioId;
  final String iterationId;
  final String artifactDigest;
  final String planDigest;
  final int verificationRevision;
  final String runtime;
  final String sessionRef;
  final String operation;
  final String beforeRef;
  final String afterRef;
  final List<String> outputRefs;
  final List<String> verifiedAcceptanceIds;
  final bool businessResultVerified;
  final String? documentFileName;
  final String? documentPath;
  final String? documentDigest;
  final List<int> pageNumbers;
  final int? pageCount;
  final List<int> chunkIndexes;
  final int? chunkCount;
  final List<Map<String, dynamic>> sourceLocations;
  final String? fontCoverageStatus;

  WorkUsageObservation({
    required this.taskId,
    required this.conversationId,
    required this.actorId,
    required this.scenarioId,
    required this.iterationId,
    required this.artifactDigest,
    required this.planDigest,
    required this.verificationRevision,
    required this.runtime,
    required this.sessionRef,
    required this.operation,
    required this.beforeRef,
    required this.afterRef,
    required List<String> outputRefs,
    List<String> verifiedAcceptanceIds = const [],
    this.businessResultVerified = false,
    this.documentFileName,
    this.documentPath,
    this.documentDigest,
    List<int> pageNumbers = const [],
    this.pageCount,
    List<int> chunkIndexes = const [],
    this.chunkCount,
    List<Map<String, dynamic>> sourceLocations = const [],
    this.fontCoverageStatus,
  })  : outputRefs = List.unmodifiable(outputRefs),
        verifiedAcceptanceIds = List.unmodifiable(verifiedAcceptanceIds),
        pageNumbers = List.unmodifiable(pageNumbers),
        chunkIndexes = List.unmodifiable(chunkIndexes),
        sourceLocations = List.unmodifiable(sourceLocations
            .map((location) => Map<String, dynamic>.unmodifiable(location)));

  bool get valid =>
      {'macos-native', 'document'}.contains(runtime) &&
      sessionRef.isNotEmpty &&
      beforeRef.isNotEmpty &&
      afterRef.isNotEmpty &&
      beforeRef != afterRef &&
      outputRefs.isNotEmpty &&
      outputRefs.every((r) => r.isNotEmpty) &&
      (runtime == 'document'
          ? documentFileName != null &&
              documentFileName!.trim().isNotEmpty &&
              (documentPath == null ||
                  documentPath!.trim().isNotEmpty &&
                      !documentPath!.startsWith('/') &&
                      !documentPath!.contains('\\') &&
                      !documentPath!.split('/').any((part) =>
                          part.isEmpty || part == '.' || part == '..')) &&
              documentDigest != null &&
              RegExp(r'^[a-f0-9]{64}$').hasMatch(documentDigest!) &&
              (operation == 'visual-read'
                  ? pageNumbers.isNotEmpty &&
                      pageCount != null &&
                      pageNumbers
                          .every((page) => page > 0 && page <= pageCount!) &&
                      outputRefs.any((ref) => ref.startsWith('document:'))
                  : operation == 'body-read' &&
                      chunkIndexes.isNotEmpty &&
                      chunkCount != null &&
                      chunkIndexes.every(
                          (index) => index >= 0 && index < chunkCount!) &&
                      sourceLocations.isNotEmpty &&
                      outputRefs.any((ref) => ref.startsWith('document:')))
          : {
              'click',
              'input',
              'scroll',
              'resize',
              'reopen',
              'assert',
              'bundle-integrity-failed'
            }.contains(operation));

  bool duplicatesDocumentUse(WorkUsageObservation other) =>
      runtime == 'document' &&
      other.runtime == 'document' &&
      operation == other.operation &&
      documentPath == other.documentPath &&
      documentDigest == other.documentDigest &&
      pageNumbers.join(',') == other.pageNumbers.join(',') &&
      chunkIndexes.join(',') == other.chunkIndexes.join(',') &&
      outputRefs.toSet().containsAll(other.outputRefs);

  bool matches(WorkCollaborationState state, String member) =>
      valid &&
      taskId == state.taskId &&
      conversationId == state.conversationId &&
      actorId == member &&
      state.usageAssignments.any(
          (a) => a['memberId'] == member && a['scenarioId'] == scenarioId) &&
      iterationId == state.currentIteration?['id'] &&
      artifactDigest == state.currentIteration?['artifactDigest'] &&
      planDigest == state.usagePlanDigest &&
      verificationRevision == state.verificationRevision &&
      (runtime != 'document' || documentPath != null) &&
      (state.artifactContract['type'] != 'software' || runtime != 'document');

  static WorkUsageObservation? tryParse(Object? raw) {
    if (raw is! Map || raw.keys.any((key) => key is! String)) return null;
    const required = {
      'taskId',
      'conversationId',
      'actorId',
      'scenarioId',
      'iterationId',
      'artifactDigest',
      'planDigest',
      'verificationRevision',
      'runtime',
      'sessionRef',
      'operation',
      'beforeRef',
      'afterRef',
      'outputRefs',
      'verifiedAcceptanceIds',
      'businessResultVerified',
    };
    const optional = {
      'documentFileName',
      'documentPath',
      'documentDigest',
      'pageNumbers',
      'pageCount',
      'chunkIndexes',
      'chunkCount',
      'sourceLocations',
      'fontCoverageStatus',
    };
    final value = Map<String, dynamic>.from(raw);
    if (!value.keys
            .every((key) => required.contains(key) || optional.contains(key)) ||
        !required.every(value.containsKey) ||
        !required
            .where((key) =>
                key != 'verificationRevision' &&
                key != 'outputRefs' &&
                key != 'verifiedAcceptanceIds' &&
                key != 'businessResultVerified')
            .every((key) => value[key] is String) ||
        value['verificationRevision'] is! int ||
        value['outputRefs'] is! List ||
        (value['outputRefs'] as List).any((item) => item is! String) ||
        value['verifiedAcceptanceIds'] is! List ||
        (value['verifiedAcceptanceIds'] as List)
            .any((item) => item is! String) ||
        value['businessResultVerified'] is! bool) {
      return null;
    }
    for (final key in const [
      'documentFileName',
      'documentDigest',
      'fontCoverageStatus'
    ]) {
      if (value.containsKey(key) && value[key] is! String) return null;
    }
    for (final key in const ['pageCount', 'chunkCount']) {
      if (value.containsKey(key) && value[key] is! int) return null;
    }
    for (final key in const ['pageNumbers', 'chunkIndexes']) {
      if (value.containsKey(key) &&
          (value[key] is! List ||
              (value[key] as List).any((item) => item is! int))) {
        return null;
      }
    }
    final rawLocations = value['sourceLocations'];
    if (rawLocations != null &&
        (rawLocations is! List ||
            rawLocations.any((item) =>
                item is! Map || item.keys.any((key) => key is! String)))) {
      return null;
    }
    return WorkUsageObservation(
      taskId: value['taskId'] as String,
      conversationId: value['conversationId'] as String,
      actorId: value['actorId'] as String,
      scenarioId: value['scenarioId'] as String,
      iterationId: value['iterationId'] as String,
      artifactDigest: value['artifactDigest'] as String,
      planDigest: value['planDigest'] as String,
      verificationRevision: value['verificationRevision'] as int,
      runtime: value['runtime'] as String,
      sessionRef: value['sessionRef'] as String,
      operation: value['operation'] as String,
      beforeRef: value['beforeRef'] as String,
      afterRef: value['afterRef'] as String,
      outputRefs: List<String>.from(value['outputRefs'] as List),
      verifiedAcceptanceIds:
          List<String>.from(value['verifiedAcceptanceIds'] as List),
      businessResultVerified: value['businessResultVerified'] as bool,
      documentFileName: value['documentFileName'] as String?,
      documentPath: value['documentPath'] as String?,
      documentDigest: value['documentDigest'] as String?,
      pageNumbers: List<int>.from((value['pageNumbers'] as List?) ?? const []),
      pageCount: value['pageCount'] as int?,
      chunkIndexes:
          List<int>.from((value['chunkIndexes'] as List?) ?? const []),
      chunkCount: value['chunkCount'] as int?,
      sourceLocations: (rawLocations as List? ?? const [])
          .map((location) => Map<String, dynamic>.from(location as Map))
          .toList(),
      fontCoverageStatus: value['fontCoverageStatus'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'taskId': taskId,
        'conversationId': conversationId,
        'actorId': actorId,
        'scenarioId': scenarioId,
        'iterationId': iterationId,
        'artifactDigest': artifactDigest,
        'planDigest': planDigest,
        'verificationRevision': verificationRevision,
        'runtime': runtime,
        'sessionRef': sessionRef,
        'operation': operation,
        'beforeRef': beforeRef,
        'afterRef': afterRef,
        'outputRefs': outputRefs,
        'verifiedAcceptanceIds': verifiedAcceptanceIds,
        'businessResultVerified': businessResultVerified,
        if (documentFileName != null) 'documentFileName': documentFileName,
        if (documentPath != null) 'documentPath': documentPath,
        if (documentDigest != null) 'documentDigest': documentDigest,
        if (pageNumbers.isNotEmpty) 'pageNumbers': pageNumbers,
        if (pageCount != null) 'pageCount': pageCount,
        if (chunkIndexes.isNotEmpty) 'chunkIndexes': chunkIndexes,
        if (chunkCount != null) 'chunkCount': chunkCount,
        if (sourceLocations.isNotEmpty) 'sourceLocations': sourceLocations,
        if (fontCoverageStatus != null)
          'fontCoverageStatus': fontCoverageStatus,
      };
}

/// Local authority uses immutable event details plus device-only commit seals.
/// Exported reference strings convey history, never the seal or permission.
class WorkUsageReceiptStore {
  final WorkTaskEventStore events;
  const WorkUsageReceiptStore(this.events);

  Future<String> record(
      {required WorkCollaborationState state,
      required String actorId,
      required List<WorkUsageObservation> observations,
      required String feedbackRef,
      String status = 'passed',
      Map<String, dynamic>? feedback}) async {
    final assignment =
        state.usageAssignments.where((a) => a['memberId'] == actorId).single;
    if (!state.usagePlanReady ||
        state.currentIteration == null ||
        status != 'blocked' && observations.isEmpty ||
        observations.any((o) => !o.matches(state, actorId)) ||
        feedbackRef.isEmpty ||
        !{'passed', 'failed', 'blocked'}.contains(status)) {
      throw StateError('缺少本人真实操作、观察或反馈。');
    }
    if (feedback != null && feedback['result'] != status) {
      throw StateError('本人反馈与记录结果不一致。');
    }
    final requiredIds = (assignment['acceptanceIds'] as List).toSet();
    final verified = observations
        .where((o) => o.businessResultVerified)
        .expand((o) => o.verifiedAcceptanceIds)
        .toSet();
    if (status == 'passed' && !requiredIds.every(verified.contains)) {
      throw StateError('操作成功不能代替完整场景业务验证。');
    }
    final body = jsonEncode({
      'schemaVersion': 1,
      'status': status,
      if (feedback != null) 'feedback': feedback,
      'taskId': state.taskId,
      'conversationId': state.conversationId,
      'actorId': actorId,
      'scenarioId': assignment['scenarioId'],
      'requestRevision': state.requestRevision,
      'teamRevision': state.teamRevision,
      'verificationRevision': state.verificationRevision,
      'iterationId': state.currentIteration!['id'],
      'artifactDigest': state.currentIteration!['artifactDigest'],
      'planDigest': state.usagePlanDigest,
      'feedbackRef': feedbackRef,
      'observations': observations.map((o) => o.toJson()).toList(),
    });
    final hash = sha256.convert(utf8.encode(body)).toString();
    await events.writeDiscussionDetail(
        state.taskId, hash.substring(0, 24), body);
    await events.recordCommittedAction(state.taskId, 'usage:$hash');
    return 'usage:${hash.substring(0, 24)}';
  }

  Future<bool> valid(WorkCollaborationState state, String actorId) async {
    final ref = state.currentUsageFor(actorId);
    if (ref == null) return false;
    try {
      final body = await events.readDiscussionDetail(
          state.taskId, (ref['receiptRef'] as String).substring(6));
      final hash = sha256.convert(utf8.encode(body)).toString();
      if (ref['receiptRef'] != 'usage:${hash.substring(0, 24)}' ||
          !await events.hasCommittedAction(state.taskId, 'usage:$hash')) {
        return false;
      }
      final receipt = jsonDecode(body) as Map;
      final assignment = state.usageAssignments
          .where((item) => item['memberId'] == actorId)
          .firstOrNull;
      final rawObservations = receipt['observations'];
      if (receipt['schemaVersion'] != 1 ||
          receipt['status'] != 'passed' ||
          receipt['actorId'] != actorId ||
          receipt['taskId'] != state.taskId ||
          receipt['conversationId'] != state.conversationId ||
          receipt['requestRevision'] != state.requestRevision ||
          receipt['teamRevision'] != state.teamRevision ||
          receipt['verificationRevision'] != state.verificationRevision ||
          receipt['scenarioId'] != ref['scenarioId'] ||
          receipt['iterationId'] != ref['iterationId'] ||
          receipt['artifactDigest'] != ref['artifactDigest'] ||
          receipt['planDigest'] != state.usagePlanDigest ||
          receipt['feedbackRef'] != ref['feedbackRef'] ||
          assignment == null ||
          rawObservations is! List) {
        return false;
      }
      final observations = rawObservations
          .map(WorkUsageObservation.tryParse)
          .whereType<WorkUsageObservation>()
          .toList(growable: false);
      if (observations.length != rawObservations.length ||
          observations.isEmpty ||
          observations.any((item) => !item.matches(state, actorId))) {
        return false;
      }
      for (final observation in observations) {
        if (observation.runtime == 'macos-native' &&
            await events.hasCommittedAction(
              state.taskId,
              'native-session-invalidated:${observation.sessionRef}',
            )) {
          return false;
        }
        for (final reference in observation.outputRefs) {
          if (observation.runtime == 'macos-native' &&
              reference.startsWith('native:')) {
            await events.readNativeEvidence(state.taskId, reference);
          } else if (observation.runtime == 'document' &&
              reference.startsWith('document:')) {
            await events.readDocumentEvidence(state.taskId, reference);
          } else {
            return false;
          }
        }
      }
      final requiredIds = (assignment['acceptanceIds'] as List).toSet();
      final verifiedIds = observations
          .where((item) => item.businessResultVerified)
          .expand((item) => item.verifiedAcceptanceIds)
          .toSet();
      return requiredIds.every(verifiedIds.contains) &&
          receipt['schemaVersion'] == 1 &&
          receipt['status'] == 'passed' &&
          receipt['feedbackRef'] == ref['feedbackRef'];
    } on Object {
      return false;
    }
  }
}

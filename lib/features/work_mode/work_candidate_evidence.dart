part of 'work_candidate_publication.dart';

/// A frozen file identity. Reports and outcomes are separate append-only files.
class WorkCandidate {
  final Directory directory;
  final Map<String, dynamic> manifest;
  WorkCandidate(this.directory, Map<String, dynamic> manifest)
      : manifest = _freeze(manifest) as Map<String, dynamic>;
  static dynamic _freeze(dynamic value) => value is Map
      ? Map<String, dynamic>.unmodifiable(
          value.map((key, item) => MapEntry(key as String, _freeze(item))))
      : value is List
          ? List.unmodifiable(value.map(_freeze))
          : value;
  String get iterationId => manifest['iterationId'] as String;
  String get digest => manifest['artifactDigest'] as String;
  String get producerId => manifest['producerId'] as String;
  List<Map<String, dynamic>> get files => (manifest['files'] as List)
      .map((e) => Map<String, dynamic>.from(e as Map))
      .toList();
  File file(String relative) => File('${directory.path}/artifacts/$relative');
  Map<String, dynamic> get reference => {
        for (final key in const [
          'taskId',
          'conversationId',
          'iterationId',
          'artifactDigest',
          'requestRevision',
          'teamRevision',
          'producerId'
        ])
          key: manifest[key],
      };
}

/// A persisted pre-test identity check. Runtime test paths are never exported
/// or treated as grants when restoring an evidence record.
class WorkCandidateReview {
  final WorkCandidate candidate;
  final String attemptId;
  final String actorId;
  final int verificationRevision;
  final Map<String, File>? testedFiles;
  WorkCandidateReview(this.candidate, this.attemptId, this.actorId,
      this.verificationRevision, this.testedFiles);
  String? _reportDigest;
  String get attemptReference => 'review:${candidate.iterationId}:$attemptId';
  String get reference => _reportDigest == null
      ? attemptReference
      : '$attemptReference:$_reportDigest';
}

extension WorkCandidateEvidence on WorkCandidatePublisher {
  Future<WorkCandidateReview> beginReview({
    required WorkCandidate candidate,
    required String attemptId,
    required String actorId,
    required int verificationRevision,
    Map<String, File>? testedFiles,
  }) =>
      _serial(() async {
        if (await File('${candidate.directory.path}/outcome.json').exists()) {
          throw StateError('本轮结论已封存，不能开始新审查。');
        }
        WorkCandidatePublisher._id(attemptId);
        if (attemptId.length > 32) throw StateError('审查 attempt 标识过长。');
        WorkCandidatePublisher._id(actorId);
        if (verificationRevision < 1) throw StateError('验证版本无效。');
        await verify(candidate,
            expectedDigest: candidate.digest, testedFiles: testedFiles);
        final members = candidate.manifest['teamMemberIds'] as List;
        if (actorId != 'user' && !members.contains(actorId) ||
            (candidate.manifest['contract'] as Map)['type'] == 'software' &&
                actorId == candidate.producerId) {
          throw StateError('审查角色不属于团队或缺少独立测试责任。');
        }
        final reviews = Directory('${candidate.directory.path}/reviews');
        if (await reviews.exists() &&
            await reviews.list(followLinks: false).length >=
                WorkCandidatePublisher.maxFiles) {
          throw StateError('审查记录达到容量，请归档后处理。');
        }
        final start =
            File('${candidate.directory.path}/reviews/$attemptId/start.json');
        if (await start.exists()) {
          throw StateError('审查 attempt 已存在，请追加新的 attempt。');
        }
        await WorkCandidatePublisher._atomicJson(start, {
          ...candidate.reference,
          'attemptId': attemptId,
          'actorId': actorId,
          'verificationRevision': verificationRevision,
          'startedAt': DateTime.now().toUtc().toIso8601String(),
          'testedWorkspace': testedFiles != null,
        });
        if (testedFiles != null) {
          await WorkCandidatePublisher._atomicJson(
              File(
                  '${candidate.directory.path}/reviews/$attemptId/workspace.json'),
              testedFiles.map((name, file) => MapEntry(name, file.path)));
        }
        return WorkCandidateReview(
            candidate,
            attemptId,
            actorId,
            verificationRevision,
            testedFiles == null ? null : Map.unmodifiable(testedFiles));
      });

  /// Append one full report. Changed candidate/workspace is recorded as invalid,
  /// never as a passed test; a repair requires a new candidate and attempt.
  Future<File> appendReview(
    WorkCandidateReview review, {
    required String method,
    required String source,
    required String receipt,
    required String result,
    required List<String> acceptanceIds,
    required String report,
  }) =>
      _serial(() async {
        if (!{'passed', 'failed', 'blocked', 'manual'}.contains(result) ||
            !{'tool', 'human'}.contains(source) ||
            method.trim().isEmpty ||
            receipt.trim().isEmpty ||
            acceptanceIds.isEmpty ||
            acceptanceIds.length > WorkCandidatePublisher.maxFiles ||
            source == 'human' && result != 'manual' ||
            review.actorId == 'user' && source != 'human') {
          throw StateError('审查报告缺少方法、来源、回执或验收项。');
        }
        var valid = true;
        try {
          await verify(review.candidate,
              expectedDigest: review.candidate.digest,
              testedFiles: review.testedFiles);
        } on Object {
          valid = false;
        }
        final start = await WorkCandidatePublisher.readMetadata(File(
            '${review.candidate.directory.path}/reviews/${review.attemptId}/start.json'));
        if (start['actorId'] != review.actorId ||
            start['artifactDigest'] != review.candidate.digest ||
            start['verificationRevision'] != review.verificationRevision) {
          throw StateError('审查开始凭据已变化。');
        }
        final record = {
          ...start,
          'method': WorkPublicUpdateStream.sanitize(method),
          'source': source,
          'receipt': WorkPublicUpdateStream.sanitize(receipt),
          'result': valid ? result : 'invalidated',
          'acceptanceIds': acceptanceIds,
          'report': WorkPublicUpdateStream.sanitize(report),
        };
        final digest = WorkCandidatePublisher._jsonHash(record);
        record['evidenceRef'] = '${review.attemptReference}:$digest';
        final file = File(
            '${review.candidate.directory.path}/reviews/${review.attemptId}/report.json');
        if (await file.exists()) {
          if (jsonEncode(await WorkCandidatePublisher.readMetadata(file)) !=
              jsonEncode(record)) {
            throw StateError('已追加的审查报告不可覆盖。');
          }
          review._reportDigest = digest;
          return file;
        }
        if (await File('${review.candidate.directory.path}/outcome.json')
            .exists()) {
          throw StateError('本轮结论已封存，不能继续追加审查。');
        }
        await WorkCandidatePublisher._atomicJson(file, record);
        review._reportDigest = digest;
        return file;
      });

  /// Validity is computed from current bytes; historical reports remain intact.
  Future<bool> evidenceValid(WorkCandidate candidate, String reference,
      {Map<String, File>? testedFiles}) async {
    try {
      await verify(candidate,
          expectedDigest: candidate.digest, testedFiles: testedFiles);
      final record = await _reviewRecord(candidate, reference);
      if (record['testedWorkspace'] == true && testedFiles == null) {
        final workspace = await WorkCandidatePublisher.readMetadata(File(
            '${candidate.directory.path}/reviews/${record['attemptId']}/workspace.json'));
        await verify(candidate,
            expectedDigest: candidate.digest,
            testedFiles: workspace
                .map((name, path) => MapEntry(name, File(path as String))));
      }
      return record['artifactDigest'] == candidate.digest &&
          {'passed', 'failed', 'blocked', 'manual'}.contains(record['result']);
    } on Object {
      return false;
    }
  }

  Future<Map<String, dynamic>> _reviewRecord(
      WorkCandidate candidate, String ref) async {
    final prefix = 'review:${candidate.iterationId}:';
    if (!ref.startsWith(prefix)) throw StateError('报告不属于本轮候选。');
    final suffix = ref.substring(prefix.length).split(':');
    if (suffix.length != 2 ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(suffix.last)) {
      throw StateError('审查证据缺少真实报告摘要。');
    }
    final attempt = suffix.first;
    WorkCandidatePublisher._id(attempt);
    final record = await WorkCandidatePublisher.readMetadata(
        File('${candidate.directory.path}/reviews/$attempt/report.json'));
    final content = {...record}..remove('evidenceRef');
    if (record['evidenceRef'] != ref ||
        WorkCandidatePublisher._jsonHash(content) != suffix.last) {
      throw StateError('审查报告已变化，原结论无效。');
    }
    return record;
  }

  /// Seal once, only after every acceptance conclusion and (for delivery) all
  /// current signatures are present. Metadata cannot be rewritten after signing.
  Future<File> sealOutcome(
          WorkCandidate candidate, WorkCollaborationState state,
          {required bool accepted}) =>
      _serial(() async {
        await verify(candidate, expectedDigest: candidate.digest);
        if (state.taskId != candidate.manifest['taskId'] ||
            state.requestRevision != candidate.manifest['requestRevision'] ||
            state.teamRevision != candidate.manifest['teamRevision'] ||
            state.currentIteration?['artifactDigest'] != candidate.digest ||
            state.currentIteration?['id'] != candidate.iterationId ||
            state.pendingInputIds.isNotEmpty ||
            state.acceptances.isEmpty ||
            accepted && !state.deliveryReady) {
          throw StateError('本轮结论或签字尚未齐全，不能封存。');
        }
        for (final acceptance in state.acceptances) {
          if (!{'passed', 'failed', 'blocked', 'manual', 'waived'}
                  .contains(acceptance['status']) ||
              acceptance['requestRevision'] != state.requestRevision ||
              acceptance['verificationRevision'] !=
                  state.verificationRevision) {
            throw StateError('验收结论不完整或版本过期。');
          }
          if ({'manual', 'waived'}.contains(acceptance['status'])) {
            if (!state.decisions.any((d) =>
                d['targetId'] == acceptance['id'] &&
                d['responseRef'] == acceptance['evidenceRef'] &&
                {'answered', 'waived'}.contains(d['status']))) {
              throw StateError('人工结论缺少用户凭据。');
            }
            continue;
          }
          final record = await _reviewRecord(
              candidate, acceptance['evidenceRef'] as String);
          if (!await evidenceValid(
                  candidate, acceptance['evidenceRef'] as String) ||
              record['artifactDigest'] != candidate.digest ||
              record['verificationRevision'] != state.verificationRevision ||
              record['result'] != acceptance['status'] ||
              !(record['acceptanceIds'] as List).contains(acceptance['id'])) {
            throw StateError('验收证据与本轮内容或结论不匹配。');
          }
        }
        final outcome = {
          ...candidate.reference,
          'verificationRevision': state.verificationRevision,
          'accepted': accepted,
          'acceptances': state.acceptances,
          'approvals': state.approvals
              .where((a) =>
                  a['kind'] == 'delivery' &&
                  a['iterationId'] == candidate.iterationId &&
                  a['artifactDigest'] == candidate.digest &&
                  a['requestRevision'] == state.requestRevision &&
                  a['teamRevision'] == state.teamRevision &&
                  a['verificationRevision'] == state.verificationRevision)
              .toList(),
        };
        final file = File('${candidate.directory.path}/outcome.json');
        if (await file.exists()) {
          if (jsonEncode(await WorkCandidatePublisher.readMetadata(file)) !=
              jsonEncode(outcome)) {
            throw StateError('已封存结论不可覆盖。');
          }
          return file;
        }
        await WorkCandidatePublisher._atomicJson(file, outcome);
        return file;
      });
}

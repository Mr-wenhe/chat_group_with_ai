part of 'default_work_task_runner.dart';

/// P6 delivery boundary; P7 chooses the work item and explicit software file
/// contract. This does not enable the legacy runner to execute a v2 task.
extension WorkCandidateDelivery on DefaultWorkTaskRunner {
  Future<WorkCandidatePublisher> candidatePublisher(AgentTask task) async =>
      WorkCandidatePublisher(
          directoryService.deliveryTaskDir(await database.mediaDir, task.id));

  WorkCollaborationState _candidateState(AgentTask task) {
    if (!WorkTaskExecutionPolicy.isValidatedV2GroupTask(task) ||
        !database.agentTaskBox.containsKey(task.id) ||
        task.status == AgentTaskStatus.cancelled ||
        eventStore.appendsSuspendedForDataClear) {
      throw StateError('候选发布只接受仍存在的有效群 v2 任务。');
    }
    return WorkDiscussionState.fromExecutionState(task.executionStateJson)!
        .collaboration!;
  }

  /// Select, validate, freeze and index real contract files, then immediately
  /// offer the candidate. Required software sources/assets must be explicit;
  /// lastArtifactPaths alone cannot declare a runnable software package.
  Future<WorkCandidate> publishCandidate(
    AgentTask task, {
    required String publicationId,
    List<String> requiredPaths = const [],
    String baseline = '',
  }) async {
    final state = _candidateState(task);
    if (!state.productionReady ||
        !{'ready', 'producing', 'verifying'}.contains(state.phase)) {
      throw StateError('方案尚未确认，不能发布制作候选。');
    }
    final sources = await _candidateSources(task, state, requiredPaths);
    final basePublisher = await candidatePublisher(task);
    final publisher =
        WorkCandidatePublisher(basePublisher.directory, fault: (_) async {
      final live = _candidateState(task);
      if (task.status == AgentTaskStatus.cancelled ||
          eventStore.appendsSuspendedForDataClear ||
          live.requestRevision != state.requestRevision ||
          live.teamRevision != state.teamRevision) {
        throw StateError('发布期间任务已停止、删除或基线已变化。');
      }
    });
    final candidate = await publisher.publish(
        publicationId: publicationId,
        state: state,
        producerId: task.characterId,
        sources: sources,
        baseline: baseline);
    await _indexCandidate(task, state, candidate, publicationId);
    await sendCandidateVersion(task, candidate);
    return candidate;
  }

  Future<Map<String, File>> _candidateSources(AgentTask task,
      WorkCollaborationState state, List<String> requiredPaths) async {
    final files = workspaceFileService;
    if (files == null) throw StateError('受控文件服务未就绪。');
    final validation = await WorkArtifactDeliveryGuard.validateTask(
        task: task,
        pathPolicy: files.pathPolicy,
        workspaceRoot: _workspaceRootForTask(task),
        now: clock());
    if (!validation.valid || validation.deliveredPaths.isEmpty) {
      throw StateError(validation.message);
    }
    final software = state.artifactContract['type'] == 'software';
    if (software && requiredPaths.isEmpty) {
      throw StateError('软件候选缺少完整文件合同或明确可重建基线。');
    }
    final declared =
        requiredPaths.isEmpty ? validation.deliveredPaths : requiredPaths;
    final selection =
        await _safeArtifactsForAttachment(task, deliverablePaths: declared);
    if (selection.skippedNames.isNotEmpty ||
        selection.entries.length != declared.toSet().length ||
        !validation.deliveredPaths
            .every((path) => selection.files.any((f) => f.path == path))) {
      throw StateError('合同文件缺失、超限或不可读取，未发布完整候选。');
    }
    final root = _workspaceRootForTask(task);
    final sources = <String, File>{};
    for (final entry in selection.entries) {
      final relative = root == null
          ? entry.archivePath
          : p
              .relative(entry.file.path,
                  from: Directory(root).resolveSymbolicLinksSync())
              .replaceAll('\\', '/');
      if (sources.containsKey(relative)) throw StateError('合同文件相对路径重复。');
      sources[relative] = entry.file;
    }
    return sources;
  }

  Future<void> _indexCandidate(AgentTask task, WorkCollaborationState state,
      WorkCandidate candidate, String publicationId) async {
    final current = _candidateState(task);
    if (current.revision != state.revision) {
      throw StateError('发布期间任务基线变化，请重新核对候选。');
    }
    if (!current.iterations.any((i) => i['id'] == candidate.iterationId)) {
      final eventId = 'candidate-$publicationId';
      final json = current.toJson()
        ..['revision'] = current.revision + 1
        ..['verificationRevision'] = current.verificationRevision + 1
        ..['phase'] = 'verifying'
        ..['iterations'] = [
          ...current.iterations,
          {
            'id': candidate.iterationId,
            'artifactDigest': candidate.digest,
            'requestRevision': current.requestRevision,
            'teamRevision': current.teamRevision,
            'manifestRef': 'candidate:${candidate.iterationId}',
            'reviewRef': '',
            'status': 'candidate',
          }
        ]
        ..['appliedEventIds'] = [...current.appliedEventIds, eventId]
            .skip(current.appliedEventIds.length == 64 ? 1 : 0)
            .toList();
      final next = WorkCollaborationState.tryParse(json);
      // 候选索引本身是有界窗口（见 WorkCollaborationState.boundedIterations），所以
      // 这里为 null 只可能是基线状态已经越界，不是"索引攒满了"。
      if (next == null) throw StateError('候选索引写入后状态越界，请核对该任务状态。');
      final applied = current.apply(WorkCollaborationUpdate(
          taskId: task.id,
          conversationId: task.groupId,
          eventId: eventId,
          sourceId: task.characterId,
          sourceRole: 'tool',
          expectedRevision: current.revision,
          next: next));
      final discussion =
          WorkDiscussionState.fromExecutionState(task.executionStateJson)!;
      task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
          task.executionStateJson, discussion.copyWith(collaboration: applied),
          expectedCollaborationRevision: current.revision);
      await _persistCheckpoint(task);
    }
  }

  /// Uses the frozen bytes and original producer even after task actor handoff.
  /// Updating the same durable message makes a failed attachment retry idempotent.
  Future<bool> sendCandidateVersion(
    AgentTask task,
    WorkCandidate candidate, {
    String kind = 'candidate',
    File? report,
  }) async {
    final state = _candidateState(task);
    final publisher = await candidatePublisher(task);
    await publisher.verify(candidate, expectedDigest: candidate.digest);
    final iteration = state.iterations
        .where((i) => i['id'] == candidate.iterationId)
        .firstOrNull;
    if (iteration?['artifactDigest'] != candidate.digest) {
      throw StateError('候选不属于任务版本索引。');
    }
    if (!{'candidate', 'review', 'final'}.contains(kind)) {
      throw StateError('交付消息类型无效。');
    }
    var senderId = candidate.producerId;
    var evidence = '';
    if (kind == 'review') {
      if (report == null ||
          !p.isWithin(candidate.directory.path, report.path)) {
        throw StateError('审查消息缺少本轮报告。');
      }
      final record = await WorkCandidatePublisher.readMetadata(report);
      // The report path itself is managed, but its provenance still has to be
      // from appendReview. Never attach an arbitrary file as test evidence.
      evidence = record['evidenceRef'] as String;
      if (!await publisher.evidenceValid(candidate, evidence)) {
        throw StateError('审查证据已失效。');
      }
      senderId = record['actorId'] as String;
    }
    final messageId =
        'delivery-${sha256.convert(utf8.encode('${task.id}:${candidate.iterationId}:$kind:$evidence'))}';
    final existing = database.messageBox.get(messageId);
    if (kind == 'final') {
      await _validateFinalResend(existing, candidate, publisher, state);
    }
    final message = existing ??
        Message(
            id: messageId,
            groupId: task.groupId,
            senderId: senderId,
            senderType: senderId == 'user' ? 'user' : 'ai',
            isWorkMode: true,
            content: '');
    if (message.senderId != senderId || message.groupId != task.groupId) {
      throw StateError('原发送者身份不一致。');
    }
    final paths = await _candidateRelatedFiles(candidate, publisher);
    message.workDelivery = {
      ...candidate.reference,
      'kind': kind,
      'senderId': senderId,
      'verified': true,
      'evidenceRef': evidence,
      'files': paths
    };
    message.content = switch (kind) {
      'review' =>
        '本轮审查报告 ${candidate.iterationId}，对应摘要 ${candidate.digest.substring(0, 12)}。',
      'final' =>
        '正式交付 ${candidate.iterationId}，${state.acceptances.any((a) => a['status'] == 'waived') ? '含用户明确豁免，' : ''}${state.acceptances.any((a) => a['status'] == 'manual') ? '含用户人工验收，' : ''}验收与逐员认可已封存。',
      _ => '候选送测 ${candidate.iterationId}，文件已冻结，等待本轮审查。',
    };
    _candidateState(task);
    await database.persistMessage(message);
    return _copyCandidateAttachments(
        task, candidate, publisher, message, kind, report);
  }

  Future<bool> _copyCandidateAttachments(
      AgentTask task,
      WorkCandidate candidate,
      WorkCandidatePublisher publisher,
      Message message,
      String kind,
      File? report) async {
    final deliveryFiles = kind == 'review'
        ? [report!]
        : candidate.files
            .map((e) => candidate.file(e['path'] as String))
            .toList();
    File? bundle;
    try {
      if (kind != 'review' &&
              (candidate.manifest['contract'] as Map)['type'] == 'software' ||
          deliveryFiles.length >
              DefaultWorkTaskRunner._maxArtifactAttachments) {
        final skipped = <String>[];
        final included = <String>[];
        bundle = await _createArtifactBundle(
            task,
            candidate.files
                .map((e) => _ArtifactFileEntry(
                    file: candidate.file(e['path'] as String),
                    archivePath: e['path'] as String))
                .toList(),
            skippedNames: skipped,
            includedArchivePaths: included,
            preservePaths: true);
        if (bundle == null ||
            skipped.isNotEmpty ||
            included.length != candidate.files.length) {
          throw StateError('合同打包失败，未遗漏必要文件继续交付。');
        }
        deliveryFiles
          ..clear()
          ..add(bundle);
      }
      final attachments = <MediaAttachment>[...?message.media];
      for (final source in deliveryFiles) {
        final expected = await WorkCandidatePublisher.fileDigest(source);
        final previous = attachments
            .where((a) => a.fileName == _basename(source.path))
            .firstOrNull;
        if (previous != null &&
            await File(previous.managedPath).exists() &&
            await WorkCandidatePublisher.fileDigest(
                    File(previous.managedPath)) ==
                expected) {
          continue;
        }
        final copied = await (mediaCopier == null
            ? database.copyToMedia(source, 'file',
                fileName: _basename(source.path))
            : mediaCopier!(source, 'file', fileName: _basename(source.path)));
        if (await WorkCandidatePublisher.fileDigest(File(copied.managedPath)) !=
            expected) {
          throw StateError('附件副本校验失败。');
        }
        attachments.removeWhere((a) => a.fileName == copied.fileName);
        attachments.add(kind == 'review' || bundle == null
            ? _attachmentReferencingOriginal(source, copied)
            : copied);
        _candidateState(task);
        message.media = attachments;
        await database.updateMessage(message);
      }
      await publisher.verify(candidate, expectedDigest: candidate.digest);
      message.content = message.content.replaceAll('\n附件投递失败，可重发同一版本。', '');
      await database.updateMessage(message);
      _clearArtifactDeliveryNotice(task);
      await _persistCheckpoint(task);
      return true;
    } on Object {
      message.content += '\n附件投递失败，可重发同一版本。';
      _markArtifactDeliveryNoticePublished(task,
          messageId: message.id, retryOnly: true);
      await database.updateMessage(message);
      await _persistCheckpoint(task);
      return false;
    } finally {
      if (bundle != null && await bundle.exists()) await bundle.delete();
    }
  }

  Future<void> _validateFinalResend(Message? existing, WorkCandidate candidate,
      WorkCandidatePublisher publisher, WorkCollaborationState state) async {
    if (existing?.workDelivery?['verified'] == true) {
      final metadata = existing!.workDelivery!;
      if (metadata['artifactDigest'] != candidate.digest) {
        throw StateError('封存交付摘要不一致。');
      }
      final files = (metadata['files'] as List).cast<Map>();
      if (!files
          .any((e) => (e['relative'] as String).endsWith('/outcome.json'))) {
        throw StateError('封存交付缺少结论。');
      }
      for (final entry in files) {
        final file = File(entry['path'] as String);
        if (!p.isWithin(candidate.directory.path, file.path) ||
            await file.length() != entry['bytes'] ||
            await WorkCandidatePublisher.fileDigest(file) != entry['sha256']) {
          throw StateError('封存交付内容已变化，不能重发。');
        }
      }
    } else {
      if (!state.deliveryReady) throw StateError('全员版本认可尚未齐全。');
      await publisher.sealOutcome(candidate, state, accepted: true);
    }
  }

  /// Delivery-only retry uses the saved message identity, never the current
  /// actor, working paths, credentials, model or tools.
  Future<bool> resendCandidateMessage(AgentTask task, String messageId) async {
    final message = database.messageBox.get(messageId);
    final metadata = message?.workDelivery;
    if (message == null ||
        message.groupId != task.groupId ||
        metadata?['taskId'] != task.id ||
        metadata?['verified'] != true) {
      throw StateError('候选重发凭据无效或需导入后核验。');
    }
    final candidates = await (await candidatePublisher(task)).recover();
    final candidate = candidates
        .where((c) => c.iterationId == metadata!['iterationId'])
        .firstOrNull;
    if (candidate == null || candidate.digest != metadata!['artifactDigest']) {
      throw StateError('原封存版本缺失或已变化。');
    }
    final kind = metadata['kind'] as String;
    final evidence = metadata['evidenceRef'] as String? ?? '';
    final report = kind == 'review'
        ? File(
            '${candidate.directory.path}/reviews/${evidence.split(':')[2]}/report.json')
        : null;
    return sendCandidateVersion(task, candidate, kind: kind, report: report);
  }

  Future<List<Map<String, dynamic>>> _candidateRelatedFiles(
      WorkCandidate candidate, WorkCandidatePublisher publisher) async {
    final files = <File>[];
    await for (final entity
        in candidate.directory.list(recursive: true, followLinks: false)) {
      if (entity is File &&
          !entity.path.endsWith('.tmp') &&
          !entity.path.endsWith('/workspace.json')) {
        files.add(entity);
      }
    }
    final entries = <Map<String, dynamic>>[];
    for (final file in files) {
      entries.add({
        'relative': p
            .relative(file.path, from: publisher.directory.path)
            .replaceAll('\\', '/'),
        'path': file.path,
        'bytes': await file.length(),
        'sha256': await WorkCandidatePublisher.fileDigest(file)
      });
    }
    return entries;
  }
}

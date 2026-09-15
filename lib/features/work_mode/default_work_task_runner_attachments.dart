part of 'default_work_task_runner.dart';

extension _DefaultWorkTaskRunnerAttachments on DefaultWorkTaskRunner {
  Future<_ArtifactAttachmentSelection> _safeArtifactsForAttachment(
    AgentTask task,
  ) async {
    final files = workspaceFileService;
    if (files == null || task.lastArtifactPaths.isEmpty) {
      return const _ArtifactAttachmentSelection();
    }
    final entries = <_ArtifactFileEntry>[];
    final skipped = <String>[];
    for (final raw in task.lastArtifactPaths) {
      try {
        final resolved = await files.pathPolicy.resolveExisting(raw);
        // `wasSymbolicLink` also reports harmless platform aliases such as
        // macOS /var -> /private/var. Reject only an explicitly linked final
        // component; the path policy has already resolved and authorized the
        // complete path before this check.
        final requestedType = await FileSystemEntity.type(
          raw,
          followLinks: false,
        );
        if (!resolved.isFile || requestedType == FileSystemEntityType.link) {
          skipped.add(_basename(raw));
          continue;
        }
        final file = File(resolved.path);
        final stat = await file.stat();
        if (stat.size > DefaultWorkTaskRunner._maxAttachedArtifactBytes) {
          skipped.add(_basename(raw));
          continue;
        }
        if (entries.every((item) => item.file.path != file.path)) {
          entries.add(_ArtifactFileEntry(
            file: file,
            archivePath: _archiveRelativePath(
              resolved.authorizedRoot,
              resolved.path,
            ),
          ));
        }
      } on Object {
        skipped.add(_basename(raw));
      }
    }
    return _ArtifactAttachmentSelection(
      entries: List<_ArtifactFileEntry>.unmodifiable(entries),
      skippedNames: List<String>.unmodifiable(skipped),
    );
  }

  Future<File?> _createArtifactBundle(
    AgentTask task,
    List<_ArtifactFileEntry> entries, {
    required List<String> skippedNames,
    required List<String> includedArchivePaths,
    Future<void> Function(int processedFiles, int processedBytes)?
        onFileProcessed,
  }) async {
    final root = await database.aiProcessingDir;
    final safeTaskId = task.id.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final staging = Directory('${root.path}/work-artifacts-$safeTaskId');
    final archive = File('${root.path}/work-artifacts-$safeTaskId.zip');
    try {
      await staging.create(recursive: true);
      var total = 0;
      var index = 0;
      var processedBytesTotal = 0;
      for (var entryIndex = 0; entryIndex < entries.length; entryIndex++) {
        final entry = entries[entryIndex];
        final file = entry.file;
        var processedBytes = 0;
        try {
          final stat = await file.stat();
          processedBytes = stat.size;
          if (stat.size >
              DefaultWorkTaskRunner._maxArtifactBundleBytes - total) {
            skippedNames.add(_basename(file.path));
            continue;
          }
          final name =
              '${index.toString().padLeft(3, '0')}_${entry.archivePath}';
          final target = File('${staging.path}/$name');
          await target.parent.create(recursive: true);
          await file.copy(target.path);
          total += stat.size;
          includedArchivePaths.add(entry.archivePath);
          index++;
        } on Object {
          skippedNames.add(_basename(file.path));
        } finally {
          processedBytesTotal += processedBytes;
          if (onFileProcessed != null) {
            await onFileProcessed(
              entryIndex + 1,
              processedBytesTotal,
            );
          }
        }
      }
      if (index == 0) return null;
      await ZipFileEncoder().zipDirectory(
        staging,
        filename: archive.path,
        followLinks: false,
      );
      return archive;
    } on Object {
      try {
        if (await archive.exists()) await archive.delete();
      } on Object {
        // Best-effort cleanup only; the project files are never touched.
      }
      return null;
    } finally {
      try {
        if (await staging.exists()) await staging.delete(recursive: true);
      } on Object {
        // Best-effort cleanup only; the generated archive remains bounded.
      }
    }
  }

  Future<void> _recordArtifactProgress(
    AgentTask task, {
    required int processedFiles,
    required int totalFiles,
    required int processedBytes,
    required int totalBytes,
  }) {
    return _record(
      task,
      WorkTaskEventKind.toolOutput,
      '文件交付进度',
      detail:
          '已处理 $processedFiles/$totalFiles 个文件，$processedBytes/$totalBytes 字节。',
      safeMetadata: {
        'phase': 'artifact_delivery',
        'filesProcessed': processedFiles,
        'filesTotal': totalFiles,
        'bytesProcessed': processedBytes,
        'bytesTotal': totalBytes,
      },
    );
  }

  String _artifactDeliveryNote(
    _ArtifactAttachmentSelection selection, {
    required bool bundled,
    required int attachedCount,
    Iterable<String> deliveredArchivePaths = const <String>[],
    Iterable<String> skippedNames = const <String>[],
  }) {
    if (attachedCount == 0 &&
        selection.skippedNames.isEmpty &&
        selection.files.isEmpty) {
      return '';
    }
    final deliveredPaths = deliveredArchivePaths.toList(growable: false);
    final delivered = bundled
        ? attachedCount > 0
            ? '已将 ${deliveredPaths.length} 个产物打包为 ZIP 附件。'
            : '产物已生成，但 ZIP 附件暂时无法复制。'
        : attachedCount > 0
            ? '已附加 $attachedCount 个产物。'
            : '产物已生成，但暂时无法复制为聊天附件。';
    final listed = deliveredPaths.take(6).join('、');
    final listSuffix = deliveredPaths.length > 6 ? ' 等' : '';
    final withPaths =
        listed.isEmpty ? delivered : '$delivered 包含：$listed$listSuffix。';
    final allSkipped = <String>{
      ...selection.skippedNames,
      ...skippedNames,
    };
    if (allSkipped.isEmpty) return withPaths;
    final names = allSkipped.take(6).join('、');
    final suffix = allSkipped.length > 6 ? ' 等' : '';
    return '$withPaths 未附加：$names$suffix（文件不存在、超出大小限制或无法安全读取）。';
  }

  String _archiveRelativePath(String root, String path) {
    final normalizedRoot =
        root.replaceAll('\\', '/').replaceFirst(RegExp(r'/+$'), '');
    final normalizedPath = path.replaceAll('\\', '/');
    final prefix = '$normalizedRoot/';
    final relative = normalizedPath.startsWith(prefix)
        ? normalizedPath.substring(prefix.length)
        : _basename(path);
    final safeSegments = relative
        .split('/')
        .where((segment) =>
            segment.isNotEmpty && segment != '.' && segment != '..')
        .map((segment) => segment.replaceAll(RegExp(r'[^A-Za-z0-9._ -]'), '_'))
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
    return safeSegments.isEmpty ? 'artifact' : safeSegments.join('/');
  }

  String? _workspaceRootForTask(AgentTask task) {
    final path = database.workModeWorkspaceBox.get(task.groupId)?.workDirPath;
    final normalized = path?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  /// Re-delivers a saved artifact without entering the model/tool loop again.
  /// The coordinator keeps the task's delivery marker while queuing a retry;
  /// this branch consumes that marker before credentials, planning or command
  /// execution can run, so a transient media-copy failure cannot reconvert or
  /// overwrite the user's already-saved file.
  Future<void> _retryArtifactDelivery(
    AgentTask task,
    WorkTaskCancellation cancellation,
  ) async {
    if (cancellation.isCancelled || task.isTerminal) return;
    final messageId = _artifactDeliveryMessageId(task);
    final character = database.aiCharacterBox.get(task.characterId);
    if (character == null) {
      final failure = WorkFailure.fromToolFailure(
        code: 'artifactDelivery',
        message: '附件重试找不到原执行角色，保留原文件并等待重新处理。',
        scope: 'delivery',
        completedContent: task.lastArtifactPaths,
        retryable: true,
      );
      task
        ..status = AgentTaskStatus.failed
        ..resumeRequired = true
        ..lastError = failure.reason
        ..updatedAt = clock();
      WorkFailure.persistOnTask(task, failure);
      await _persistCheckpoint(task);
      return;
    }
    final result = await _appendPublicMessage(
      task,
      character,
      task.resultSummary,
      existingMessageId: messageId,
    );
    if (cancellation.isCancelled || task.isTerminal) return;
    if (result.succeeded) {
      task
        ..status = AgentTaskStatus.completed
        ..resumeRequired = false
        ..lastError = ''
        ..updatedAt = clock();
      WorkFailure.clearFromTask(task);
      _clearArtifactDeliveryNotice(task);
      await database.recordCharacterReplyUsage(character.id);
    } else {
      final failure = WorkFailure.fromToolFailure(
        code: 'artifactDelivery',
        message: result.message,
        scope: 'delivery',
        completedContent: task.lastArtifactPaths,
        retryable: true,
      );
      task
        ..status = AgentTaskStatus.failed
        ..resumeRequired = true
        ..lastError = failure.reason
        ..updatedAt = clock();
      WorkFailure.persistOnTask(task, failure);
      _markArtifactDeliveryNoticePublished(
        task,
        messageId: result.messageId ?? messageId,
        retryOnly: result.retryWithExistingArtifact,
      );
    }
    await _persistCheckpoint(task);
  }

  Future<void> _persistCheckpoint(AgentTask task) async {
    task.updatedAt = clock();
    final sink = _taskCheckpointSink;
    if (sink != null) {
      await sink(task);
      return;
    }
    await database.agentTaskBox.put(task.id, task);
    _taskUpdateSink?.call(task);
  }

  void _markArtifactDeliveryNoticePublished(
    AgentTask task, {
    String? messageId,
    bool retryOnly = false,
  }) {
    final metadata = _decodeExecutionMetadata(task.executionStateJson);
    metadata['artifactDeliveryNoticePublished'] = true;
    final normalizedMessageId = messageId?.trim() ?? '';
    if (normalizedMessageId.isEmpty) {
      metadata.remove('artifactDeliveryMessageId');
    } else {
      metadata['artifactDeliveryMessageId'] = normalizedMessageId;
    }
    if (retryOnly && normalizedMessageId.isNotEmpty) {
      metadata['artifactDeliveryRetryOnly'] = true;
    } else {
      metadata.remove('artifactDeliveryRetryOnly');
    }
    task.executionStateJson = jsonEncode(metadata);
  }

  void _clearArtifactDeliveryNotice(AgentTask task) {
    final metadata = _decodeExecutionMetadata(task.executionStateJson);
    metadata
      ..remove('artifactDeliveryNoticePublished')
      ..remove('artifactDeliveryMessageId')
      ..remove('artifactDeliveryRetryOnly');
    task.executionStateJson = metadata.isEmpty ? '' : jsonEncode(metadata);
  }

  bool _artifactDeliveryNoticePublished(AgentTask task) =>
      _decodeExecutionMetadata(
          task.executionStateJson)['artifactDeliveryNoticePublished'] ==
      true;

  bool _artifactDeliveryRetryOnly(AgentTask task) {
    final metadata = _decodeExecutionMetadata(task.executionStateJson);
    final messageId = metadata['artifactDeliveryMessageId'];
    return metadata['artifactDeliveryNoticePublished'] == true &&
        metadata['artifactDeliveryRetryOnly'] == true &&
        messageId is String &&
        messageId.trim().isNotEmpty;
  }

  String _artifactDeliveryMessageId(AgentTask task) {
    final value = _decodeExecutionMetadata(
        task.executionStateJson)['artifactDeliveryMessageId'];
    return value is String ? value.trim() : '';
  }

  Map<String, dynamic> _decodeExecutionMetadata(String raw) {
    if (raw.trim().isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : <String, dynamic>{};
    } on Object {
      return <String, dynamic>{};
    }
  }

  Future<void> _record(
    AgentTask task,
    WorkTaskEventKind kind,
    String title, {
    String detail = '',
    Map<String, Object?>? safeMetadata,
  }) async {
    if (eventStore.appendsSuspendedForDataClear) return;
    try {
      await eventStore.append(
        taskId: task.id,
        kind: kind,
        title: title,
        detail: detail,
        safeMetadata: safeMetadata,
        timestamp: clock(),
      );
    } on Object catch (error) {
      // A late callback can race with app-data clearing. Do not recreate a
      // deleted task checkpoint merely because diagnostic persistence stopped.
      if (eventStore.appendsSuspendedForDataClear) return;
      task.eventLogIncomplete = true;
      task.lastError = task.lastError.isEmpty
          ? '任务日志保存不完整：${sanitizeWorkTaskError(error)}'
          : task.lastError;
      try {
        await database.agentTaskBox.put(task.id, task);
        _taskUpdateSink?.call(task);
      } on Object {
        // Logging is diagnostic and cannot replace the task outcome.
      }
    }
  }

  bool _requestsExplicitValidation(String request) {
    return isExplicitWorkValidationRequest(request);
  }

  String _displayPlan(WorkChangePlan plan) {
    final paths = plan.exactPaths.isEmpty
        ? plan.knownAffectedDirectories
        : plan.exactPaths;
    return paths.map(_basename).join('、');
  }
}

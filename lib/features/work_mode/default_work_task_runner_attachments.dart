part of 'default_work_task_runner.dart';

extension _DefaultWorkTaskRunnerAttachments on DefaultWorkTaskRunner {
  /// Collects the files this run may attach.
  ///
  /// When [deliverablePaths] is non-empty the task declared a file contract and
  /// every candidate passed that contract, so only those paths are considered.
  /// Without it the run has no contract and the ordinary set of changed files is
  /// used.
  Future<_ArtifactAttachmentSelection> _safeArtifactsForAttachment(
    AgentTask task, {
    List<String> deliverablePaths = const <String>[],
  }) async {
    final files = workspaceFileService;
    if (files == null || task.lastArtifactPaths.isEmpty) {
      return const _ArtifactAttachmentSelection();
    }
    final candidates =
        deliverablePaths.isEmpty ? task.lastArtifactPaths : deliverablePaths;
    final entries = <_ArtifactFileEntry>[];
    final skipped = <String>[];
    for (final raw in candidates) {
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
    bool contractUnmet = false,
    Iterable<String> deliveredArchivePaths = const <String>[],
    Iterable<String> skippedNames = const <String>[],
  }) {
    if (attachedCount == 0 &&
        selection.skippedNames.isEmpty &&
        selection.files.isEmpty) {
      return '';
    }
    final deliveredPaths = deliveredArchivePaths.toList(growable: false);
    final delivered = _deliveryHeadline(
      contractUnmet: contractUnmet,
      bundled: bundled,
      attachedCount: attachedCount,
      deliveredCount: deliveredPaths.length,
    );
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

  /// How the attachment step describes itself.
  ///
  /// A failed artifact task still hands over whatever the run wrote, but those
  /// files are intermediates: reporting them as 产物 — and reporting the
  /// attachment as a success — contradicted the failure report sitting directly
  /// above it and read as "the deliverable is here after all".
  String _deliveryHeadline({
    required bool contractUnmet,
    required bool bundled,
    required int attachedCount,
    required int deliveredCount,
  }) {
    if (contractUnmet) {
      if (attachedCount == 0) {
        return '本次运行写出的文件暂时无法复制为聊天附件。';
      }
      return bundled
          ? '已将本次运行写出的 $deliveredCount 个中间文件打包为 ZIP 附件，供你排查或继续处理。'
          : '已附加本次运行写出的 $attachedCount 个中间文件，供你排查或继续处理。';
    }
    if (bundled) {
      return attachedCount > 0
          ? '已将 $deliveredCount 个产物打包为 ZIP 附件。'
          : '产物已生成，但 ZIP 附件暂时无法复制。';
    }
    return attachedCount > 0
        ? '已附加 $attachedCount 个产物。'
        : '产物已生成，但暂时无法复制为聊天附件。';
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
        .map(_archiveSafeSegment)
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
    return safeSegments.isEmpty ? 'artifact' : safeSegments.join('/');
  }

  /// Characters that could escape the staging directory or break the archive
  /// entry name. Control characters are handled separately by code point so no
  /// regex range can silently swallow printable ASCII.
  static const String _unsafeArchiveCharacters = r'/\:*?"<>|';

  String _archiveSafeSegment(String segment) {
    final withoutTraversal = segment.replaceAll('..', '_');
    final buffer = StringBuffer();
    for (final rune in withoutTraversal.runes) {
      final isControl = rune < 0x20 || rune == 0x7f;
      final character = String.fromCharCode(rune);
      buffer.write(
        isControl || _unsafeArchiveCharacters.contains(character)
            ? '_'
            : character,
      );
    }
    final collapsed = buffer.toString().replaceAll(RegExp(r'_{2,}'), '_');
    final trimmed = collapsed
        .replaceFirst(RegExp(r'^[. _]+'), '')
        .replaceFirst(RegExp(r'[. _]+$'), '');
    // Archive entries have a 255-byte name limit on most extractors; 80
    // characters keeps multi-byte names comfortably inside it. Two long names
    // that share a prefix would otherwise truncate to the SAME entry, and most
    // extractors silently keep one — so the truncation carries a short digest of
    // the full name.
    final runes = trimmed.runes.toList(growable: false);
    if (runes.length <= 80) return trimmed;
    final digest = workArtifactNameDigest(trimmed);
    return String.fromCharCodes(runes.take(80)).replaceFirst(
      RegExp(r'(.{8})$'),
      '_${digest.substring(0, 8)}',
    );
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
        // 执行角色缺失是 App 侧状态问题，已保存的产物不受影响，任务保持完成。
        ..status = AgentTaskStatus.completed
        ..resumeRequired = true
        ..lastError = failure.reason
        ..updatedAt = clock();
      WorkFailure.persistOnTask(task, failure);
      _markArtifactDeliveryNoticePublished(
        task,
        messageId: messageId,
        retryOnly: true,
      );
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
      _applyArtifactDeliveryFailure(
        task,
        result,
        previousMessageId: messageId,
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
    task.executionStateJson = workWithoutArtifactDeliveryNotice(
      task.executionStateJson,
    );
  }

  /// Records the outcome of a delivery attempt that did not produce the
  /// expected chat message.
  ///
  /// A deliverable that is saved and validated but could not be attached is an
  /// app-side fault, so the task keeps its completed status and only a
  /// retryable "resend" notice is recorded — finished work must not be reported
  /// as failed. A deliverable that no longer satisfies its contract really did
  /// leave the task incomplete and keeps the failed status.
  void _applyArtifactDeliveryFailure(
    AgentTask task,
    _ArtifactDeliveryResult result, {
    String? previousMessageId,
  }) {
    final failure = WorkFailure.fromToolFailure(
      code: 'artifactDelivery',
      message: result.message,
      scope: 'delivery',
      completedContent: task.lastArtifactPaths,
      retryable: true,
    );
    task
      ..status = result.retryWithExistingArtifact
          ? AgentTaskStatus.completed
          : AgentTaskStatus.failed
      ..resumeRequired = true
      ..lastError = failure.reason
      ..updatedAt = clock();
    WorkFailure.persistOnTask(task, failure);
    _markArtifactDeliveryNoticePublished(
      task,
      messageId: result.messageId ?? previousMessageId,
      retryOnly: result.retryWithExistingArtifact,
    );
  }

  bool _artifactDeliveryNoticePublished(AgentTask task) =>
      _decodeExecutionMetadata(
          task.executionStateJson)['artifactDeliveryNoticePublished'] ==
      true;

  bool _artifactDeliveryRetryOnly(AgentTask task) =>
      workArtifactDeliveryRetryPending(task.executionStateJson);

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

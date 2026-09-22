part of 'default_work_task_runner.dart';

extension _DefaultWorkTaskRunnerDelivery on DefaultWorkTaskRunner {
  Future<Map<String, dynamic>> _createSkill(
    AICharacter character,
    Map<String, dynamic> args,
  ) async {
    final rawInstructions = args['instructions'];
    if (rawInstructions is! List ||
        rawInstructions.any((item) => item is! String)) {
      return {'ok': false, 'error': 'instructions_missing'};
    }
    final rawPermissions = args['permissions'];
    final permissions = ToolPermission.values
        .where((permission) =>
            rawPermissions is List && rawPermissions.contains(permission.name))
        .toList(growable: false);
    final skill = CharacterSkill(
      characterId: character.id,
      name: args['name']?.toString() ?? 'Generated Skill',
      domain: args['domain']?.toString() ?? 'general',
      description: args['description']?.toString() ?? '',
      instructions: rawInstructions.cast<String>(),
      requiredPermissions: permissions,
    );
    await database.characterSkillBox.put(skill.id, skill);
    if (!character.skillIds.contains(skill.id)) {
      character.skillIds = [...character.skillIds, skill.id];
      await database.aiCharacterBox.put(character.id, character);
    }
    return {'ok': true, 'skillId': skill.id, 'name': skill.name};
  }

  Future<Map<String, dynamic>> _downloadSkill(
    AICharacter character,
    Map<String, dynamic> args,
  ) async {
    final requested = args['templateId']?.toString() ?? args['id']?.toString();
    final template = requested == null
        ? (SkillDownloadService.recommendedTemplatesFor(character).isEmpty
            ? null
            : SkillDownloadService.recommendedTemplatesFor(character).first)
        : ExpertSkillCatalog.findById(requested);
    if (template == null) return {'ok': false, 'error': 'template_not_found'};
    final existing = database.characterSkillBox.values.where(
      (skill) =>
          skill.name == template.name &&
          (skill.isGlobal ||
              skill.characterId == character.id ||
              character.skillIds.contains(skill.id)),
    );
    final skill = existing.isEmpty
        ? template.instantiateFor(character.id)
        : existing.first;
    if (existing.isEmpty) await database.characterSkillBox.put(skill.id, skill);
    if (!skill.isGlobal && !character.skillIds.contains(skill.id)) {
      character.skillIds = {...character.skillIds, skill.id}.toList();
      await database.aiCharacterBox.put(character.id, character);
    }
    return {'ok': true, 'skillId': skill.id, 'templateId': template.id};
  }

  Future<String> _failureReply(AgentTask task, WorkFailure failure) async {
    final reason = _failureReplyText(failure.reason, fallback: '任务执行失败。');
    final technical = _failureReplyText(
      failure.technicalDetail,
      fallback: reason,
    );
    final attachmentSelection = await _safeArtifactsForAttachment(task);
    final artifactNames = attachmentSelection.files
        .map((file) => _basename(file.path))
        .where((name) => name.trim().isNotEmpty)
        .take(6)
        .toList(growable: false);
    final recordedArtifactNames = task.lastArtifactPaths
        .map(_basename)
        .where((name) => name.trim().isNotEmpty)
        .take(6)
        .toList(growable: false);
    final lines = <String>[
      '任务未完成。',
      '原因：$reason',
      if (technical != reason) '技术细节：$technical',
    ];
    if (task.completedOperations.isNotEmpty) {
      lines.add('已完成：${task.completedOperations.length} 个步骤，最近的安全检查点已保留。');
    }
    if (artifactNames.isNotEmpty) {
      lines.add(
        '输出文件：已确认工作区中有 ${artifactNames.join('、')}；任务失败不会删除这些文件，并会尽量附加到这条消息。',
      );
    } else if (recordedArtifactNames.isNotEmpty) {
      lines.add(
        '输出文件：已记录候选路径 ${recordedArtifactNames.join('、')}，但当前没有确认到仍可交付的文件；重试时会从最近检查点继续核对。',
      );
    } else {
      lines.add(
        '输出文件：当前没有确认到可交付文件；如果失败前已经写入文件，重试时会从最近检查点继续核对。',
      );
    }
    lines.add(
        '下一步：${_failureReplyText(failure.suggestedAction, fallback: '请检查任务面板后重试。')}');
    return lines.join('\n');
  }

  String _failureReplyText(String value, {required String fallback}) {
    if (value.trim().isEmpty) return fallback;
    final safe = sanitizeWorkTaskError(value);
    return safe == '任务执行失败' ? fallback : safe;
  }

  Future<_ArtifactDeliveryResult> _appendPublicMessage(
    AgentTask task,
    AICharacter character,
    String content, {
    bool enforceArtifactContract = true,
    String? existingMessageId,
  }) async {
    final text = content.trim();
    if (text.isEmpty) return const _ArtifactDeliveryResult.success();

    final requestedMessageId = existingMessageId?.trim();
    final previousMessage =
        requestedMessageId == null || requestedMessageId.isEmpty
            ? null
            : database.messageBox.get(requestedMessageId);
    final message = previousMessage != null &&
            previousMessage.groupId == task.groupId &&
            previousMessage.senderId == character.id &&
            previousMessage.senderType == 'ai'
        ? previousMessage
        : Message(
            groupId: task.groupId,
            senderId: character.id,
            senderType: 'ai',
            content: '',
          );

    Future<void> persistMessage() async {
      if (identical(message, previousMessage)) {
        await database.updateMessage(message);
      } else {
        await database.persistMessage(message);
      }
    }

    final currentRequest = WorkDiscussionState.currentRequestScope(task);
    final requiredDocx = WorkArtifactDeliveryGuard.requiresDocxArtifact(
      currentRequest,
      contractFormat: WorkArtifactDeliveryGuard.contractFormatForTask(task),
    );
    final requiresArtifactDelivery = requiredDocx ||
        WorkArtifactDeliveryGuard.isRevisionTask(task) ||
        WorkArtifactDeliveryGuard.requiresFileArtifact(currentRequest) ||
        WorkArtifactDeliveryGuard.requiresSourceArtifact(currentRequest);

    // Deliverables accepted by the contract check. Delivery is scoped to these
    // paths so an intermediate file the same run wrote (a script, a conversion
    // source) cannot be attached as if it were a deliverable, nor make the
    // attachment step fail on a file the user never asked for.
    var validatedDeliverables = const <String>[];

    if (enforceArtifactContract) {
      final files = workspaceFileService;
      if (files != null) {
        final validation = await WorkArtifactDeliveryGuard.validateTask(
          task: task,
          pathPolicy: files.pathPolicy,
          workspaceRoot: _workspaceRootForTask(task),
          now: clock(),
        );
        if (!validation.valid && requiresArtifactDelivery) {
          message
            ..content = _artifactDeliveryFailureContent(validation.message)
            ..media = null;
          await persistMessage();
          return _ArtifactDeliveryResult.failure(
            validation.message,
            messageId: message.id,
          );
        }
        validatedDeliverables = validation.deliveredPaths;
      } else if (requiresArtifactDelivery) {
        const failureMessage = WorkArtifactDeliveryGuard.missingArtifactMessage;
        message.content = _artifactDeliveryFailureContent(failureMessage);
        message.media = null;
        await persistMessage();
        return _ArtifactDeliveryResult.failure(
          failureMessage,
          messageId: message.id,
        );
      }
    }

    // Only successful artifact completions defer the model's response until
    // attachment delivery. Failure reports must keep their diagnostic text;
    // otherwise a failed task can appear to be stuck in delivery forever.
    final deferArtifactText =
        enforceArtifactContract && requiresArtifactDelivery;
    message
      ..content = deferArtifactText ? '正在验证并交付文件，请稍候。' : text
      ..media = null;
    await persistMessage();

    List<MediaAttachment>? media;
    File? temporaryBundle;
    var deliveryFailure = false;
    var deliveryFailureMessage = '';
    var retryWithExistingArtifact = false;
    try {
      try {
        final selection = await _safeArtifactsForAttachment(
          task,
          deliverablePaths: validatedDeliverables,
        );
        final files = selection.files;
        final attachmentSkippedNames = <String>[];
        final deliveredArchivePaths = <String>[];
        final bundledSkippedNames = <String>[];
        final totalBytes = files.fold<int>(0, (sum, file) {
          try {
            return sum + file.lengthSync();
          } on Object {
            return sum;
          }
        });
        // Keep ordinary artifacts as individual file cards so the chat shows
        // exactly which files this run produced or modified. Bundle only when
        // the count/size would make individual delivery impractical.
        final needsBundle =
            files.length > DefaultWorkTaskRunner._maxArtifactAttachments ||
                totalBytes > DefaultWorkTaskRunner._maxAttachedArtifactBytes;
        await _recordArtifactProgress(
          task,
          processedFiles: 0,
          totalFiles: files.length,
          processedBytes: 0,
          totalBytes: totalBytes,
        );
        final deliveryFiles = <File>[];
        if (needsBundle && files.isNotEmpty) {
          temporaryBundle = await _createArtifactBundle(
            task,
            selection.entries,
            skippedNames: bundledSkippedNames,
            includedArchivePaths: deliveredArchivePaths,
            onFileProcessed: (processedFiles, processedBytes) =>
                _recordArtifactProgress(
              task,
              processedFiles: processedFiles,
              totalFiles: files.length,
              processedBytes: processedBytes,
              totalBytes: totalBytes,
            ),
          );
          if (temporaryBundle != null) deliveryFiles.add(temporaryBundle);
        } else {
          deliveryFiles.addAll(files);
        }
        final attachments = <MediaAttachment>[];
        final copiedArtifactPaths = <String>{};
        var processedArtifactFiles = 0;
        var processedArtifactBytes = 0;
        for (final file in deliveryFiles) {
          var processedBytes = 0;
          try {
            final stat = await file.stat();
            processedBytes = stat.size;
            final sizeLimit = identical(file, temporaryBundle)
                ? DefaultWorkTaskRunner._maxArtifactBundleBytes
                : DefaultWorkTaskRunner._maxAttachedArtifactBytes;
            if (stat.type != FileSystemEntityType.file ||
                stat.size > sizeLimit) {
              attachmentSkippedNames.add(_basename(file.path));
              continue;
            }
            final copied = await (mediaCopier == null
                ? database.copyToMedia(
                    file,
                    'file',
                    fileName: _basename(file.path),
                  )
                : mediaCopier!(
                    file,
                    'file',
                    fileName: _basename(file.path),
                  ));
            attachments.add(
              temporaryBundle == null
                  ? _attachmentReferencingOriginal(file, copied)
                  : copied,
            );
            if (temporaryBundle == null) {
              final entry =
                  selection.entries.cast<_ArtifactFileEntry?>().firstWhere(
                        (item) => item?.file.path == file.path,
                        orElse: () => null,
                      );
              if (entry != null) deliveredArchivePaths.add(entry.archivePath);
              copiedArtifactPaths.add(file.path);
            } else {
              copiedArtifactPaths.addAll(
                selection.entries
                    .where((entry) =>
                        deliveredArchivePaths.contains(entry.archivePath))
                    .map((entry) => entry.file.path),
              );
            }
          } on Object {
            // Continue delivering other verified artifacts when one copy fails.
            attachmentSkippedNames.add(_basename(file.path));
          } finally {
            if (temporaryBundle == null) {
              processedArtifactFiles++;
              processedArtifactBytes += processedBytes;
              await _recordArtifactProgress(
                task,
                processedFiles: processedArtifactFiles,
                totalFiles: files.length,
                processedBytes: processedArtifactBytes,
                totalBytes: totalBytes,
              );
            }
          }
        }
        if (attachments.isNotEmpty) media = attachments;
        await _recordArtifactProgress(
          task,
          processedFiles: files.length,
          totalFiles: files.length,
          processedBytes: totalBytes,
          totalBytes: totalBytes,
        );
        final deliveryNote = _artifactDeliveryNote(
          selection,
          bundled: temporaryBundle != null,
          attachedCount: media?.length ?? 0,
          deliveredArchivePaths: deliveredArchivePaths,
          skippedNames: [
            ...bundledSkippedNames,
            ...attachmentSkippedNames,
          ],
        );
        if (deliveryNote.isNotEmpty) {
          message.content = '$text\n\n$deliveryNote';
        }
        final attachmentSkips = <String>{
          ...selection.skippedNames,
          ...bundledSkippedNames,
          ...attachmentSkippedNames,
        };
        final requiredValidation = requiredDocx && workspaceFileService != null
            ? await WorkArtifactDeliveryGuard.validateTask(
                task: task,
                pathPolicy: workspaceFileService!.pathPolicy,
                workspaceRoot: _workspaceRootForTask(task),
                now: clock(),
              )
            : null;
        final requiredPath = requiredValidation?.path;
        if (requiresArtifactDelivery &&
            requiredDocx &&
            (requiredValidation == null || !requiredValidation.valid)) {
          deliveryFailure = true;
          deliveryFailureMessage = requiredValidation?.message ??
              WorkArtifactDeliveryGuard.docxContractMessage;
        } else if (requiresArtifactDelivery &&
            requiredDocx &&
            (requiredPath == null ||
                !copiedArtifactPaths.contains(requiredPath))) {
          deliveryFailure = true;
          retryWithExistingArtifact = true;
          deliveryFailureMessage =
              '文件已保存，但真实 DOCX 未能作为聊天附件发送；可重试交付，重试不会重新转换或覆盖文件。';
        } else if (requiresArtifactDelivery &&
            !requiredDocx &&
            (attachmentSkips.isNotEmpty ||
                (enforceArtifactContract && files.isEmpty) ||
                files.isNotEmpty && attachments.isEmpty)) {
          deliveryFailure = true;
          retryWithExistingArtifact = true;
          final skippedCount = attachmentSkips.isEmpty
              ? (files.isEmpty ? 1 : files.length)
              : attachmentSkips.length;
          deliveryFailureMessage = skippedCount == 1
              ? '文件已保存，但有 1 个产物无法作为聊天附件发送；可重试交付，重试不会重新生成或覆盖文件。'
              : '文件已保存，但有 $skippedCount 个产物无法作为聊天附件发送；可重试交付，重试不会重新生成或覆盖文件。';
        }
        if (deliveryFailure) {
          message.content = enforceArtifactContract && requiresArtifactDelivery
              ? _artifactDeliveryFailureContent(
                  deliveryFailureMessage,
                  saved: true,
                )
              : '${message.content}\n\n$deliveryFailureMessage';
        }
        message.media = media;
        await database.updateMessage(message);
      } finally {
        if (temporaryBundle != null) {
          try {
            if (await temporaryBundle.exists()) await temporaryBundle.delete();
          } on Object {
            // The copied media attachment remains authoritative if cleanup fails.
          }
        }
      }
    } on Object {
      deliveryFailure = true;
      retryWithExistingArtifact = true;
      deliveryFailureMessage = '文件已保存，但附件发送遇到暂时性错误；可重试交付，重试不会重新转换或覆盖文件。';
      try {
        message.content = enforceArtifactContract && requiresArtifactDelivery
            ? _artifactDeliveryFailureContent(
                deliveryFailureMessage,
                saved: true,
              )
            : '$text\n\n$deliveryFailureMessage';
        await database.updateMessage(message);
      } on Object {
        // The initial text message remains durable even if its diagnostic
        // update also fails.
      }
    }
    return deliveryFailure
        ? _ArtifactDeliveryResult.failure(
            deliveryFailureMessage,
            messageId: message.id,
            retryWithExistingArtifact: retryWithExistingArtifact,
          )
        : _ArtifactDeliveryResult.success(messageId: message.id);
  }

  String _artifactDeliveryFailureContent(
    String reason, {
    bool saved = false,
  }) {
    final prefix = saved ? '任务未完成，文件已保留。' : '任务未完成。';
    return '$prefix\n交付门禁未通过：${reason.trim()}\n'
        '未将模型说明文字伪装成附件；请先确保真实文件写入并通过回读校验后再完成。';
  }

  MediaAttachment _attachmentReferencingOriginal(
    File original,
    MediaAttachment cached,
  ) {
    final originalPath = original.path;
    final cachedPath = cached.localPath.trim();
    final samePath = cachedPath == originalPath ||
        File(cachedPath).absolute.path == File(originalPath).absolute.path;
    return MediaAttachment(
      id: cached.id,
      type: cached.type,
      localPath: originalPath,
      cachePath: cached.cachePath ?? (samePath ? null : cached.localPath),
      fileName: cached.fileName ?? _basename(originalPath),
      fileSize: cached.fileSize,
      mimeType: cached.mimeType,
      durationMs: cached.durationMs,
    );
  }

  /// Tools whose result can prove that a task's deliverable already exists.
  ///
  /// `command.run` belongs here because a script writing the workbook produces
  /// it just as directly as `workspace.patch` produces a text file. Without it a
  /// “write a script, then run it” task never auto-completed and kept re-reading
  /// and re-running a finished artifact.
  static const Set<AgentToolName> _artifactCompletionTools = {
    AgentToolName.workspacePatch,
    AgentToolName.commandRun,
  };

  /// Finishes a single-deliverable task as soon as its contract is satisfied.
  ///
  /// The decision uses the contract check, not “how many files changed”: one run
  /// normally writes an intermediate script as well, and any change-count rule
  /// either blocks the completion or treats the script as a deliverable.
  Future<AgentFinishCompletion?> _autoCompleteAfterArtifact(
    AgentTask task,
    AgentToolCall call,
    WorkToolResult result,
  ) async {
    if (!_artifactCompletionTools.contains(call.name) ||
        !_artifactToolChanged(call, result) ||
        !_canAutoCompleteSingleArtifact(task)) {
      return null;
    }
    // A command reports every file it touched in `artifactPaths`, so a successful
    // run alone does not prove the deliverable exists: “开发一个网页应用” would
    // finish as soon as its first script ran. Requiring a format the user named
    // (or the discussion contract fixed) keeps the command branch as narrow as
    // the `workspace.patch` branch it replaced.
    if (call.name == AgentToolName.commandRun &&
        WorkArtifactDeliveryGuard.declaredOutputFormats(task).isEmpty) {
      return null;
    }
    final files = workspaceFileService;
    if (files == null) return null;
    final validation = await WorkArtifactDeliveryGuard.validateTask(
      task: task,
      pathPolicy: files.pathPolicy,
      workspaceRoot: _workspaceRootForTask(task),
      now: clock(),
    );
    // A request without a file contract is not an artifact task; one whose
    // deliverable is missing or invalid must keep looping so the model can fix
    // it.
    if (!validation.valid || !validation.requiresArtifact) return null;
    final path = validation.path ?? result.data['path']?.toString() ?? '';
    final requestHint = _safeCompletionRequestHint(
      WorkDiscussionState.currentRequestScope(task),
    );
    final baseSummary = path.trim().isEmpty
        ? '文件已写入并通过回读校验。'
        : '文件已写入并通过回读校验：${_basename(path)}。';
    return AgentFinishCompletion(
      summary:
          requestHint == null ? baseSummary : '$baseSummary 请求摘要：$requestHint。',
      evidence: [
        '${call.name.wireName} 确认产物已写入',
        if (path.trim().isNotEmpty) '已验证路径：$path',
      ],
    );
  }

  /// Whether a tool result committed a change that could complete an artifact
  /// task. `workspace.patch` reports `changed`; a successful `command.run`
  /// reports the files it created.
  bool _artifactToolChanged(AgentToolCall call, WorkToolResult result) {
    if (call.name == AgentToolName.workspacePatch) {
      return result.data['changed'] == true;
    }
    final artifacts = result.data['artifactPaths'];
    return result.data['runStatus'] == WorkCommandRunStatus.completed.name &&
        artifacts is List &&
        artifacts.whereType<String>().any((path) => path.trim().isNotEmpty);
  }

  String? _safeCompletionRequestHint(String request) {
    var hint = request
        .replaceAll(RegExp(r'[\u0000-\u001f\u007f]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (hint.isEmpty) return null;
    hint = const SearchSecretScanner().redact(
      hint,
      includeOpaqueTokens: true,
    );
    const maximum = 160;
    if (hint.length > maximum) {
      hint = '${hint.substring(0, maximum - 1)}…';
    }
    return hint;
  }

  /// Whether the request names a single deliverable, so the run can finish as
  /// soon as the artifact contract is satisfied.
  ///
  /// This deliberately counts the extensions the user wrote instead of the
  /// files the run changed: one run legitimately writes an intermediate script
  /// next to its deliverable, and a change-count rule would read that as “this
  /// task produces several files” and never auto-complete.
  bool _canAutoCompleteSingleArtifact(AgentTask task) {
    if (WorkArtifactDeliveryGuard.isRevisionTask(task)) return true;
    final request = WorkDiscussionState.currentRequestScope(task).toLowerCase();
    if (RegExp(r'全部|所有|多个|多份|多文件|all\s+files|multiple', caseSensitive: false)
        .hasMatch(request)) {
      return false;
    }
    final explicitExtensions = RegExp(
      r'\.(?:html?|css|js|ts|jsx|tsx|vue|dart|py|md|txt|json|ya?ml|xlsx?|pptx?|docx?|pdf|csv)\b',
      caseSensitive: false,
    ).allMatches(request).length;
    return explicitExtensions <= 1;
  }

  Future<void> _tryOpenHtmlArtifact(AgentTask task) async {
    if (!autoOpenHtml || workspaceFileService == null) return;
    final validation = await WorkArtifactDeliveryGuard.validateTask(
      task: task,
      pathPolicy: workspaceFileService!.pathPolicy,
      workspaceRoot: _workspaceRootForTask(task),
      now: clock(),
    );
    final path = validation.path;
    if (!validation.valid ||
        path == null ||
        !RegExp(r'\.html?$', caseSensitive: false).hasMatch(path)) {
      return;
    }
    try {
      final opened = await OpenFilex.open(path, type: 'text/html');
      final succeeded = opened.type.name == 'done';
      await _record(
        task,
        WorkTaskEventKind.toolOutput,
        succeeded ? '已尝试在默认浏览器打开 HTML。' : 'HTML 已交付，但自动打开浏览器失败。',
        detail: succeeded ? path : opened.message,
        safeMetadata: {
          'browserPreview': true,
          'opened': succeeded,
        },
      );
    } on Object catch (error) {
      await _record(
        task,
        WorkTaskEventKind.toolOutput,
        'HTML 已交付，但自动打开浏览器失败。',
        detail: error.toString(),
        safeMetadata: const {'browserPreview': true, 'opened': false},
      );
    }
  }

  /// A source-code request is successful only when a real readable file was
  /// produced. The guard intentionally does not synthesize a path or recover
  /// prose into code; that fallback belonged to the removed legacy work-mode
  /// protocol and could create a misleading `.py`/`.js` attachment.
  Future<String?> _validateCompletion(
    AgentTask task,
    AgentFinishCompletion _,
  ) async {
    final files = workspaceFileService;
    if (files == null) {
      return WorkArtifactDeliveryGuard.failureFor(
        request: WorkDiscussionState.currentRequestScope(task),
        hasReadableArtifact: false,
        contractFormat: WorkArtifactDeliveryGuard.contractFormatForTask(task),
      );
    }
    final validation = await WorkArtifactDeliveryGuard.validateTask(
      task: task,
      pathPolicy: files.pathPolicy,
      workspaceRoot: _workspaceRootForTask(task),
      now: clock(),
    );
    return validation.valid ? null : validation.message;
  }
}

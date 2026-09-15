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
          skill.characterId == character.id && skill.name == template.name,
    );
    final skill = existing.isEmpty
        ? template.instantiateFor(character.id)
        : existing.first;
    if (existing.isEmpty) await database.characterSkillBox.put(skill.id, skill);
    character.skillIds = {...character.skillIds, skill.id}.toList();
    await database.aiCharacterBox.put(character.id, character);
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

    // The model's final response is the chat reply. Persist it before the
    // optional artifact-copy phase so a slow or failed attachment delivery
    // can never hide the conclusion from the conversation.
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
            content: text,
          );
    message
      ..content = text
      ..media = null;
    if (identical(message, previousMessage)) {
      await database.updateMessage(message);
    } else {
      await database.persistMessage(message);
    }

    if (enforceArtifactContract) {
      final files = workspaceFileService;
      if (files != null) {
        final validation = await WorkArtifactDeliveryGuard.validateTask(
          task: task,
          pathPolicy: files.pathPolicy,
          workspaceRoot: _workspaceRootForTask(task),
          now: clock(),
        );
        if (!validation.valid &&
            (WorkArtifactDeliveryGuard.requiresDocxArtifact(
                  task.userRequest,
                  contractFormat:
                      WorkArtifactDeliveryGuard.contractFormatForTask(task),
                ) ||
                WorkArtifactDeliveryGuard.requiresFileArtifact(
                  task.userRequest,
                ) ||
                WorkArtifactDeliveryGuard.requiresSourceArtifact(
                  task.userRequest,
                ))) {
          message.content = '$text\n\n交付门禁未通过：${validation.message}';
          await database.updateMessage(message);
          return _ArtifactDeliveryResult.failure(
            validation.message,
            messageId: message.id,
          );
        }
      }
    }

    List<MediaAttachment>? media;
    File? temporaryBundle;
    var deliveryFailure = false;
    var deliveryFailureMessage = '';
    var retryWithExistingArtifact = false;
    try {
      try {
        final selection = await _safeArtifactsForAttachment(task);
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
            attachments.add(copied);
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
        final requiredDocx = WorkArtifactDeliveryGuard.requiresDocxArtifact(
          task.userRequest,
          contractFormat: WorkArtifactDeliveryGuard.contractFormatForTask(task),
        );
        final requiresArtifactDelivery = requiredDocx ||
            WorkArtifactDeliveryGuard.requiresFileArtifact(task.userRequest) ||
            WorkArtifactDeliveryGuard.requiresSourceArtifact(task.userRequest);
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
                files.isNotEmpty && attachments.isEmpty)) {
          deliveryFailure = true;
          retryWithExistingArtifact = true;
          final skippedCount =
              attachmentSkips.isEmpty ? files.length : attachmentSkips.length;
          deliveryFailureMessage = skippedCount == 1
              ? '文件已保存，但有 1 个产物无法作为聊天附件发送；可重试交付，重试不会重新生成或覆盖文件。'
              : '文件已保存，但有 $skippedCount 个产物无法作为聊天附件发送；可重试交付，重试不会重新生成或覆盖文件。';
        }
        if (deliveryFailure) {
          message.content = '${message.content}\n\n$deliveryFailureMessage';
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
        message.content = '$text\n\n$deliveryFailureMessage';
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
        request: task.userRequest,
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

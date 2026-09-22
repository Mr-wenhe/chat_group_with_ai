part of 'default_work_task_runner.dart';

extension _DefaultWorkTaskRunnerCommandExecution on DefaultWorkTaskRunner {
  Future<WorkToolResult> _runCommand(
    AgentTask task,
    WorkToolInvocation invocation,
    AICharacter character,
    String workspaceRoot,
  ) async {
    final permissions = _permissionsForTask(task, character);
    if (!permissions.contains(ToolPermission.commandRun)) {
      return const WorkToolResult.permissionDenied(
        message: '角色未授予 commandRun 工具权限。',
      );
    }
    final command = _commandFromCall(invocation.call, workspaceRoot);
    if (command == null) {
      return const WorkToolResult.failed(
        message: '命令必须使用结构化参数，未执行。',
        failureCode: 'invalidCommand',
      );
    }
    final commandPolicy = _commandPolicyFor(character, workspaceRoot);
    final policy = commandPolicy.evaluate(
      command,
      taskId: task.id,
      userExplicitlyRequested: _requestsExplicitValidation(
        WorkDiscussionState.currentRequestScope(task),
      ),
    );
    final plan = policy.changePlan;
    final checkpoint = _decodeMap(task.executionStateJson);
    final approvalGranted = plan != null &&
        !policy.isReadOnly &&
        _approvalDecision(task.executionStateJson)?.permitsExecution == true &&
        checkpoint['approvalCapability'] == WorkApprovalCapability.mutation &&
        checkpoint['approvalOperationFingerprint'] ==
            WorkApprovalFingerprint.mutation(call: invocation.call, plan: plan);
    final runner = commandRunner ??
        WorkCommandRunner(
          policy: commandPolicy,
          pathPolicy: workspaceFileService?.pathPolicy,
          continueAfterOutputLimit: true,
          preferTectonicForPandoc: true,
          onOutput: (chunk) => _record(
            task,
            WorkTaskEventKind.toolOutput,
            '命令输出',
            detail: chunk.text,
            safeMetadata: {'stream': chunk.stream.name},
          ),
        );
    Future<WorkCommandResult> run() => runner.run(
          command,
          taskId: task.id,
          approvalGranted: approvalGranted,
          userExplicitlyRequested: _requestsExplicitValidation(
            WorkDiscussionState.currentRequestScope(task),
          ),
          cancellation: invocation.context.cancellation?.whenCancelled,
          isCancelled: () => invocation.context.isCancelled,
        );
    final lockManager = resourceLockManager;
    if (plan != null && !policy.isReadOnly && lockManager == null) {
      return const WorkToolResult.failed(
        message: '命令变更缺少资源锁管理器，未执行。',
        failureCode: 'commandLockUnavailable',
      );
    }
    final result = plan == null || policy.isReadOnly
        ? await run()
        : await lockManager!.withLocks(
            task.id,
            <WorkResourceLockRequest>{
              ...plan.knownAffectedDirectories
                  .map(WorkResourceLockRequest.treeWrite),
              ...plan.exactPaths.map(WorkResourceLockRequest.treeWrite),
            },
            run,
            cancellation: invocation.context.cancellation?.whenCancelled,
            isCancelled: () => invocation.context.isCancelled,
          );
    final artifactPaths = await _existingCommandArtifactPaths(command);
    final data = <String, dynamic>{
      'commandDisplay': _safeCommandDisplay(command),
      'runStatus': result.status.name,
      if (result.exitCode != null) 'exitCode': result.exitCode,
      'elapsedMs': result.elapsed.inMilliseconds,
      'outputTruncated': result.outputTruncated,
      if (result.command.displayCommand != command.displayCommand)
        'executedCommandDisplay': _safeCommandDisplay(result.command),
      if (artifactPaths.isNotEmpty) 'artifactPaths': artifactPaths,
      if (result.stdout.isNotEmpty) 'stdout': result.stdout,
      if (result.stderr.isNotEmpty) 'stderr': result.stderr,
      if (result.installSuggestion != null)
        'installSuggestion': result.installSuggestion!.toJson(),
    };
    if (!result.succeeded) {
      final failureTargetPath =
          _commandFailureTargetPath(command, artifactPaths);
      if (failureTargetPath != null) {
        data['failureTargetPath'] = failureTargetPath;
      }
    }
    if (result.succeeded) {
      return WorkToolResult.success(message: result.message, data: data);
    }
    if (result.status == WorkCommandRunStatus.waitingForApproval) {
      return WorkToolResult.waitingForApproval(
        message: result.message,
        data: data,
      );
    }
    if (result.status == WorkCommandRunStatus.pausedForUser ||
        result.status == WorkCommandRunStatus.toolMissing) {
      return WorkToolResult.paused(
        message: result.message,
        data: data,
        failureCode: result.status == WorkCommandRunStatus.toolMissing
            ? 'toolMissing'
            : 'userActionRequired',
      );
    }
    if (result.status == WorkCommandRunStatus.blockedByDefault) {
      return WorkToolResult.failed(
        message: result.message,
        data: data,
        failureCode: 'commandFailed',
      );
    }
    if (result.status == WorkCommandRunStatus.pathRejected) {
      return WorkToolResult.pathRejected(message: result.message, data: data);
    }
    final failureCode = switch (result.status) {
      WorkCommandRunStatus.timedOut => 'commandFailed',
      WorkCommandRunStatus.outputLimitExceeded => 'commandFailed',
      WorkCommandRunStatus.failed => !policy.allowed &&
              policy.rejectionKind == WorkCommandRejectionKind.invalidInput
          ? 'modelProtocol'
          : 'commandFailed',
      WorkCommandRunStatus.cancelled => 'userActionRequired',
      _ => 'commandFailed',
    };
    return WorkToolResult.failed(
      message: result.message,
      data: data,
      failureCode: failureCode,
    );
  }

  Future<List<String>> _existingCommandArtifactPaths(
    WorkCommand command,
  ) async {
    final files = workspaceFileService;
    if (files == null) return const <String>[];
    final paths = <String>{};
    for (final rawPath in command.declaredImpact.take(64)) {
      try {
        final candidate = _effectivePath(
          null,
          command.workingDirectory,
          rawPath,
          enforceRevision: false,
        );
        final resolved = await files.pathPolicy.resolveExisting(candidate);
        // The path policy may mark harmless parent aliases such as macOS
        // /var -> /private/var as symbolic. Reject only a linked final
        // component; the policy has already authorized the resolved path.
        final requestedType = await FileSystemEntity.type(
          candidate,
          followLinks: false,
        );
        if (resolved.isFile && requestedType != FileSystemEntityType.link) {
          paths.add(resolved.path);
        }
      } on Object {
        // declaredImpact is an authorization hint, not proof that a file was
        // produced. Only existing, policy-resolved files become artifacts.
      }
    }
    return paths.toList(growable: false);
  }

  String? _commandFailureTargetPath(
    WorkCommand command,
    Iterable<String> existingArtifactPaths,
  ) {
    final sourcePaths = existingArtifactPaths
        .where(_looksLikeSourceArtifact)
        .toList(growable: false);
    final display = command.displayCommand.toLowerCase();
    final fullPathMatches = sourcePaths
        .where((path) =>
            display.contains(path.replaceAll('\\', '/').toLowerCase()))
        .toList(growable: false);
    if (fullPathMatches.length == 1) return fullPathMatches.single;
    final basenameMatches = sourcePaths.where((path) {
      final basename = path.replaceAll('\\', '/').split('/').last.toLowerCase();
      return basename.isNotEmpty && display.contains(basename);
    }).toList(growable: false);
    if (basenameMatches.length == 1) {
      return basenameMatches.single;
    }
    if (sourcePaths.length == 1) return sourcePaths.single;

    // A script can be the failing input without being listed in
    // declaredImpact. The command policy has already validated argument paths;
    // retain only a source-looking argument and never persist inline code or
    // an option as a repair target.
    final argumentMatches = <String>[];
    for (final argument in command.arguments) {
      final candidate = argument.trim();
      if (candidate.isEmpty || candidate.startsWith('-')) continue;
      if (_looksLikeSourceArtifact(candidate)) argumentMatches.add(candidate);
    }
    return argumentMatches.length == 1 ? argumentMatches.single : null;
  }

  bool _looksLikeSourceArtifact(String path) => RegExp(
        r'\.(?:py|pyw|js|mjs|cjs|ts|tsx|jsx|dart|sh|bash|rb|go|rs|java|kt|swift|c|cc|cpp|h|hpp)$',
        caseSensitive: false,
      ).hasMatch(path.replaceAll('\\', '/'));

  Future<WorkCommandResult> _implInstallMissingTool(
    AgentTask task,
    WorkTaskCancellation cancellation,
  ) async {
    final pending = _pendingRequests[task.id] ??
        ToolRequest.fromJsonString(task.pendingToolRequestJson);
    if (pending == null || pending.tool != AgentToolName.commandRun) {
      throw StateError('当前任务没有可安装的缺失命令。');
    }
    final character = database.aiCharacterBox.get(task.characterId);
    if (character == null) throw StateError('执行角色不可用。');
    if (!_permissionsForTask(task, character)
        .contains(ToolPermission.commandRun)) {
      throw StateError('角色未授予 commandRun 工具权限。');
    }
    final workspace = await workspaceService.loadOrCreate(
      conversationId: task.groupId,
      isDirectChat: task.groupId.startsWith('dm:'),
    );
    final original = _commandFromCall(
      AgentToolCall(name: AgentToolName.commandRun, arguments: pending.args),
      workspace.workDirPath,
    );
    if (original == null) throw StateError('缺失命令检查点格式无效。');
    final policy = _commandPolicyFor(character, workspace.workDirPath);
    final runner = commandRunner ??
        WorkCommandRunner(
          policy: policy,
          pathPolicy: workspaceFileService?.pathPolicy,
          onOutput: (chunk) => _record(
            task,
            WorkTaskEventKind.toolOutput,
            '安装命令输出',
            detail: chunk.text,
            safeMetadata: {'stream': chunk.stream.name, 'install': true},
          ),
        );
    // Use the runner's policy when a caller injects one. This keeps the
    // installer branch deterministic in tests and makes the suggested
    // package manager match the policy that will actually execute it.
    final installerPolicy = commandRunner?.policy ?? policy;
    final suggestion = WorkCommandInstallSuggestion.forExecutable(
      original.executable,
      isWindows: installerPolicy.isWindows,
      isMacOS: installerPolicy.isMacOS,
      workingDirectory: original.workingDirectory,
      declaredImpact: original.declaredImpact,
    );
    final install = suggestion.installCommand;
    if (install == null) {
      throw StateError('该工具没有可安全自动安装的受信命令。');
    }
    // Clicking the panel action is the explicit user confirmation for this
    // one-shot package-manager command; it never changes the task's ordinary
    // write-confirmation setting or grants a permanent system capability.
    final result = await runner.run(
      install,
      taskId: '${task.id}:install',
      approvalGranted: true,
      userExplicitlyRequested: true,
      includeUserHome: true,
      cancellation: cancellation.whenCancelled,
      isCancelled: () => cancellation.isCancelled,
    );
    if (result.succeeded &&
        task.pendingToolRequestJson == safeToolRequestCheckpoint(pending) &&
        _isReplayableInstalledCommand(original)) {
      // The checkpoint contains only structured command fields. Promote it
      // after the trusted installer succeeds so the coordinator can resume
      // the exact operation; _runCommand still performs the current policy,
      // path and approval checks before spawning anything.
      _pendingRequests[task.id] = pending;
    }
    return result;
  }

  bool _isReplayableInstalledCommand(WorkCommand command) {
    if (_containsCheckpointRedaction(command.executable) ||
        _containsCheckpointRedaction(command.workingDirectory)) {
      return false;
    }
    return command.arguments.every(
          (argument) => !_containsCheckpointRedaction(argument),
        ) &&
        command.declaredImpact.every(
          (path) => !_containsCheckpointRedaction(path),
        );
  }

  bool _containsCheckpointRedaction(String value) =>
      value.contains(SearchSecretScanner.redaction);

  WorkToolResult _mapFileResult(Map<String, dynamic> result) =>
      _mapFileResultToTool(result);

  WorkToolResult _mapSkillResult(Map<String, dynamic> result) {
    final ok = result['ok'] == true;
    return ok
        ? WorkToolResult.success(
            message: result['message']?.toString() ?? '技能已更新。',
            data: result,
          )
        : WorkToolResult.failed(
            message: result['message']?.toString() ?? '技能操作失败。',
            data: result,
            failureCode: result['error']?.toString() ?? 'skillFailed',
          );
  }

  WorkToolResult _mapFileResultToTool(Map<String, dynamic> result) {
    final message = result['message']?.toString() ??
        (result['error']?.toString() ?? '文件操作已完成。');
    if (result['requiresFolderGrant'] == true) {
      return WorkToolResult.paused(
        message: message,
        data: result,
        failureCode: 'authorizationLost',
      );
    }
    if (result['requiresApproval'] == true) {
      final error = result['error']?.toString().toLowerCase() ?? '';
      return WorkToolResult.waitingForApproval(
        message: message,
        data: result,
        failureCode: error.contains('snapshot')
            ? 'snapshotUnavailable'
            : 'userActionRequired',
      );
    }
    if (result['ok'] == true) {
      return WorkToolResult.success(message: message, data: result);
    }
    final error = result['error']?.toString() ?? '';
    final lowerError = error.toLowerCase();
    final lowerMessage = message.toLowerCase();
    final mutationCommitted = result['mutationCommitted'] == true;
    if (lowerError.contains('snapshot') ||
        lowerError.contains('snapshotunavailable') ||
        lowerMessage.contains('快照') ||
        lowerMessage.contains('撤销记录')) {
      return WorkToolResult.failed(
        message: message,
        data: result,
        failureCode: 'snapshotUnavailable',
        committed: mutationCommitted,
      );
    }
    if (lowerError.contains('conflict') ||
        lowerError.contains('postcondition')) {
      return WorkToolResult.failed(
        message: message,
        data: result,
        failureCode: 'fileConflict',
        committed: mutationCommitted,
      );
    }
    if (lowerError.contains('path') || lowerError.contains('notauthorized')) {
      return WorkToolResult.pathRejected(message: message, data: result);
    }
    return WorkToolResult.failed(
      message: message,
      data: result,
      failureCode: error.isEmpty ? 'fileFailed' : error,
      committed: mutationCommitted,
    );
  }

  String _withApprovalPlan(
    String raw,
    WorkChangePlan plan, {
    AgentToolCall? call,
  }) {
    final current = _decodeMap(raw)
      ..remove('approvalDecision')
      ..['approvalPlan'] = plan.toJson()
      ..['approvalScope'] = WorkApprovalScope.fromPlan(plan).toJson();
    if (call != null) {
      current['approvalCapability'] = WorkApprovalCapability.mutation;
      current['approvalOperationFingerprint'] =
          WorkApprovalFingerprint.mutation(call: call, plan: plan);
      current.remove('approvalConsumed');
    } else {
      current
        ..remove('approvalCapability')
        ..remove('approvalOperationFingerprint')
        ..remove('approvalConsumed');
    }
    return jsonEncode(current);
  }

  String _withApprovalMetadata(
    String raw, {
    required String capability,
    required String fingerprint,
  }) {
    final current = _decodeMap(raw)
      ..remove('approvalDecision')
      ..remove('approvalPlan')
      ..remove('approvalScope')
      ..['approvalCapability'] = capability
      ..['approvalOperationFingerprint'] = fingerprint
      ..remove('approvalConsumed');
    return jsonEncode(current);
  }

  String? _approvedSensitiveOperation(AgentTask task) {
    final checkpoint = _decodeMap(task.executionStateJson);
    if (checkpoint['approvalCapability'] !=
            WorkApprovalCapability.sensitiveRead ||
        _approvalDecision(task.executionStateJson)?.permitsExecution != true) {
      return null;
    }
    final value = checkpoint['approvalOperationFingerprint'];
    return value is String && value.trim().isNotEmpty ? value : null;
  }

  String? _approvalCapability(AgentTask task) {
    final value = _decodeMap(task.executionStateJson)['approvalCapability'];
    return value is String && value.trim().isNotEmpty ? value : null;
  }
}

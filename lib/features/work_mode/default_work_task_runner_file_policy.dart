part of 'default_work_task_runner.dart';

extension _DefaultWorkTaskRunnerFilePolicy on DefaultWorkTaskRunner {
  Future<WorkChangePlan?> _planForFileInvocation(
    AgentTask task,
    AgentToolCall call,
    Stage02WorkspaceFileTool stage02,
    WorkspaceMutationService mutations,
  ) async {
    final rawPath = call.arguments['path'];
    if (rawPath is! String || rawPath.trim().isEmpty) return null;
    try {
      final targetPath = await _mutationPath(
        task,
        stage02,
        rawPath,
        allowAutoRename: call.name == AgentToolName.workspacePatch &&
            !_isExactPatch(call.arguments),
      );
      final target = await stage02.pathPolicy.resolve(
        targetPath,
        allowMissing: call.name != AgentToolName.workspaceDelete,
      );
      if (target.exists && !target.isFile) return null;
      final action = switch (call.name) {
        AgentToolName.workspaceDelete => WorkChangeActionType.delete,
        AgentToolName.workspaceRename => WorkChangeActionType.rename,
        AgentToolName.workspacePatch => _isExactPatch(call.arguments)
            ? WorkChangeActionType.patch
            : target.exists
                ? WorkChangeActionType.modify
                : WorkChangeActionType.create,
        _ => null,
      };
      if (action == null) return null;
      final exactPaths = <String>[target.path];
      final directories = <String>{target.authorizedRoot};
      if (action == WorkChangeActionType.rename) {
        final destinationRaw = call.arguments['destinationPath'];
        if (destinationRaw is! String || destinationRaw.trim().isEmpty) {
          return null;
        }
        final destination = await stage02.pathPolicy.resolve(
          _effectivePath(
            task,
            stage02.workspaceRoot,
            destinationRaw,
            enforceRevision: false,
          ),
          allowMissing: true,
        );
        if (destination.exists && !destination.isFile) return null;
        exactPaths.add(destination.path);
        directories.add(destination.authorizedRoot);
      }
      final content = call.arguments['content'];
      final replacement = call.arguments['replacement'];
      var plan = WorkChangePlan(
        taskId: task.id,
        actionType: action,
        exactPaths: exactPaths,
        knownAffectedDirectories: directories.toList(growable: false),
        estimatedBytes: replacement is String
            ? utf8.encode(replacement).length
            : content is String
                ? utf8.encode(content).length
                : 0,
        snapshotAvailable: mutations.snapshotPort != null,
        reversible: mutations.snapshotPort != null,
        riskReason: switch (action) {
          WorkChangeActionType.create => '工作模式需要在授权目录内创建文件。',
          WorkChangeActionType.modify => '工作模式需要在授权目录内原子替换文件。',
          WorkChangeActionType.patch => '工作模式需要在授权目录内应用精确补丁。',
          WorkChangeActionType.rename => '工作模式需要在授权目录内重命名文件。',
          WorkChangeActionType.delete => '工作模式需要删除授权目录内的普通文件。',
          _ => '工作模式需要修改授权目录内的文件。',
        },
      );
      final port = mutations.snapshotPort;
      if (port case final WorkspaceMutationSnapshotAvailabilityPort checker) {
        final available = await checker.canReserve(
          plan: plan,
          paths: plan.exactPaths,
        );
        if (!available) {
          plan = WorkChangePlan(
            taskId: plan.taskId,
            actionType: plan.actionType,
            exactPaths: plan.exactPaths,
            knownAffectedDirectories: plan.knownAffectedDirectories,
            estimatedBytes: plan.estimatedBytes,
            snapshotAvailable: false,
            reversible: false,
            riskReason: plan.riskReason,
          );
        }
      }
      return plan;
    } on Object {
      return null;
    }
  }

  bool _isDirectWordPatch(AgentTask task, AgentToolCall call) {
    if (call.name != AgentToolName.workspacePatch ||
        !WorkArtifactDeliveryGuard.requiresDocxArtifact(
          task.userRequest,
          contractFormat: WorkArtifactDeliveryGuard.contractFormatForTask(task),
        )) {
      return false;
    }
    final rawPath = call.arguments['path'];
    if (rawPath is! String) return false;
    final normalized = rawPath.trim().replaceAll('\\', '/').toLowerCase();
    return normalized.endsWith('.docx') || normalized.endsWith('.doc');
  }

  WorkCommand? _commandFromCall(AgentToolCall call, String workspaceRoot) {
    try {
      final raw = Map<String, dynamic>.from(call.arguments);
      final cwd = raw['workingDirectory'];
      if (cwd is String) {
        raw['workingDirectory'] = cwd.trim().isEmpty
            ? workspaceRoot
            : _isAbsolutePath(cwd)
                ? cwd
                : _effectivePath(null, workspaceRoot, cwd);
      }
      final arguments = raw['arguments'] ?? raw['args'];
      if (arguments is! List || arguments.any((item) => item is! String)) {
        return null;
      }
      raw['arguments'] = arguments.cast<String>();
      final impact = raw['declaredImpact'];
      if (impact is! List || impact.any((item) => item is! String)) {
        return null;
      }
      raw['declaredImpact'] = impact.cast<String>();
      return WorkCommand.fromJson(raw);
    } on Object {
      return null;
    }
  }

  Future<String> _mutationPath(
    AgentTask task,
    Stage02WorkspaceFileTool stage02,
    Object? rawPath, {
    bool allowAutoRename = false,
  }) async {
    final candidate = _effectivePath(task, stage02.workspaceRoot, rawPath);
    if (!allowAutoRename ||
        _revisionTarget(task) != null ||
        _decodeMap(task.executionStateJson)['autoRenameIfExists'] != true) {
      return candidate;
    }
    final metadata = _decodeMap(task.executionStateJson);
    final persisted = metadata['resolvedMutationPath'];
    if (persisted is String && persisted.trim().isNotEmpty) {
      // Persist the collision decision before the approval pause so every
      // gate and the eventual handler use one exact path, including after a
      // restart. The path policy revalidates its authorization boundary.
      final resolved = await stage02.pathPolicy.resolve(
        persisted.trim(),
        allowMissing: true,
      );
      if (resolved.exists) {
        throw StateError('自动重命名目标在审批期间已被占用，未覆盖现有文件。');
      }
      return resolved.path;
    }
    final resolved =
        await stage02.pathPolicy.resolve(candidate, allowMissing: true);
    if (!resolved.exists) return candidate;
    final allocated = await _nextAvailablePath(stage02, candidate);
    metadata['resolvedMutationPath'] = allocated;
    task.executionStateJson = jsonEncode(metadata);
    return allocated;
  }

  Future<String> _nextAvailablePath(
    Stage02WorkspaceFileTool stage02,
    String original,
  ) async {
    final normalized = original.replaceAll('\\', '/');
    final slash = normalized.lastIndexOf('/');
    final directory = slash < 0 ? '' : normalized.substring(0, slash);
    final name = slash < 0 ? normalized : normalized.substring(slash + 1);
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final extension = dot > 0 ? name.substring(dot) : '';
    for (var index = 1; index <= 1000; index++) {
      final candidate = '$directory/$stem ($index)$extension';
      final resolved = await stage02.pathPolicy.resolve(
        candidate,
        allowMissing: true,
      );
      if (!resolved.exists) return resolved.path;
    }
    throw StateError('无法为重名文件分配安全的新路径。');
  }

  WorkCommandPolicy _commandPolicyFor(
    AICharacter character,
    String workspaceRoot,
  ) {
    final roots = folderGrantService?.grants
            .where(
              (grant) =>
                  grant.available && grant.cloudDisclosureConfirmedAt != null,
            )
            .map((grant) => grant.path)
            .toList(growable: false) ??
        <String>[workspaceRoot];
    return WorkCommandPolicy(
      authorizedRoots: roots.isEmpty ? [workspaceRoot] : roots,
    );
  }

  /// A read grant authorizes inspection, but it must never become an implicit
  /// write capability merely because a command was classified after planning.
  /// Re-check the concrete command immediately before approval/handler gates so
  /// a grant revoked while a task was paused cannot be used for local writes.
  Future<WorkToolResult?> _commandWritableCapabilityGate(
    AgentTask task,
    WorkCommand command,
    WorkCommandPolicyResult evaluation,
  ) async {
    final grants = folderGrantService;
    if (grants == null || !evaluation.allowed || evaluation.isReadOnly) {
      return null;
    }

    // External-only commands (for example a confirmed HTTP POST) do not need
    // a writable workspace. A declared absolute impact path still does, as it
    // explicitly claims a local side effect in addition to the external one.
    final requiresWritable =
        evaluation.impact != WorkCommandImpact.externalMutation ||
            command.declaredImpact.any(_isAbsolutePath);
    if (!requiresWritable) return null;

    final paths = <String>[command.workingDirectory];
    paths.addAll(command.declaredImpact.where(_isAbsolutePath));
    for (final path in paths) {
      if (await grants.isPathWritableResolved(path)) continue;
      task.executionStateJson =
          _withFolderRequest(task.executionStateJson, path);
      return WorkToolResult.waitingForApproval(
        message: '命令可能修改本地状态，需要重新授权可写工作目录后才能继续。',
        data: {
          'folderRequestPath': path,
          'requiresWritable': true,
        },
        failureCode: 'authorizationRequired',
      );
    }
    return null;
  }

  Set<ToolPermission> _permissionsForTask(
    AgentTask task,
    AICharacter character,
  ) {
    final characterPermissions = character.toolPermissions.toSet();
    final taskPermissions = task.requestedPermissions.toSet();
    // requestedPermissions is a task-level request/checkpoint field, not an
    // authority grant. Always intersect it with the active role's persisted
    // capabilities so a stale or tampered task cannot grant commandRun (or
    // any other tool) that the current character does not have.
    return taskPermissions.isEmpty
        ? characterPermissions
        : characterPermissions.intersection(taskPermissions);
  }

  bool _pendingRequiresWritableWorkspace(
    AgentTask task,
    ToolRequest? pending,
  ) {
    final execution = _decodeMap(task.executionStateJson);
    if (execution['folderRequiresWritable'] == true) return true;
    if (pending == null) return false;
    return switch (pending.tool) {
      AgentToolName.workspacePatch ||
      AgentToolName.workspaceRename ||
      AgentToolName.workspaceDelete =>
        true,
      // command.run is normally classified by WorkCommandPolicy. If a folder
      // grant was just repaired, the marker may already have been cleared, so
      // conservatively recognize the small read-only command set here to keep
      // local mutations on a writable workspace.
      AgentToolName.commandRun => _pendingCommandNeedsWritable(pending.args),
      _ => false,
    };
  }

  bool _hasWritableWorkspaceMarker(AgentTask task) {
    return _decodeMap(task.executionStateJson)['folderRequiresWritable'] ==
        true;
  }

  void _consumeWritableWorkspaceMarker(AgentTask task) {
    final execution = _decodeMap(task.executionStateJson)
      ..remove('folderRequiresWritable');
    task.executionStateJson = execution.isEmpty ? '' : jsonEncode(execution);
  }

  bool _pendingCommandNeedsWritable(Map<String, dynamic> args) {
    final executable = (args['executable'] ?? '').toString().toLowerCase();
    final base = executable.replaceAll('\\', '/').split('/').last;
    final rawArguments = args['arguments'] ?? args['args'];
    final rawArgumentList = rawArguments is List
        ? rawArguments.map((item) => item.toString()).toList()
        : const <String>[];
    final arguments = rawArgumentList
        .map((item) => item.toLowerCase())
        .toList(growable: false);
    final rawImpact = args['declaredImpact'];
    final impactPaths =
        rawImpact is List ? rawImpact.whereType<String>() : const <String>[];
    if (impactPaths.any(_isAbsolutePath) ||
        arguments.any(_isLocalRedirectArgument)) {
      return true;
    }
    if (const {
      'pwd',
      'ls',
      'dir',
      'rg',
      'ripgrep',
      'grep',
      'egrep',
      'fgrep',
      'cat',
      'head',
      'tail',
      'wc',
      'file',
      'stat',
      'which',
      'where',
      'whoami',
      'uname',
    }.contains(base)) {
      return false;
    }
    if (base == 'find' || base == 'fd') {
      return arguments.any(
        (argument) => {'-delete', '-exec', '-execdir', '-ok', '-okdir'}
            .contains(argument),
      );
    }
    if (base == 'git' && arguments.isNotEmpty) {
      return !const {
        'status',
        'diff',
        'log',
        'show',
        'branch',
        'rev-parse',
        'ls-files',
      }.contains(arguments.first);
    }
    if (base == 'flutter' || base == 'dart') {
      final first = arguments.isEmpty ? '' : arguments.first;
      return first != 'analyze' && first != '--version' && first != '--help';
    }
    if (base == 'curl' || base == 'wget') {
      return rawArgumentList.any(
        (raw) {
          final argument = raw.toLowerCase();
          final curlShortOutput = base == 'curl' &&
              (raw == '-D' ||
                  raw.startsWith('-D') && raw.length > 2 ||
                  raw == '-c' ||
                  raw.startsWith('-c') && raw.length > 2);
          return curlShortOutput ||
              argument == '-o' ||
              argument == '--output' ||
              argument.startsWith('--output=') ||
              argument == '--output-dir' ||
              argument.startsWith('--output-dir=') ||
              argument == '--output-document' ||
              argument.startsWith('--output-document=') ||
              argument == '--dump-header' ||
              argument.startsWith('--dump-header=') ||
              argument == '--cookie-jar' ||
              argument.startsWith('--cookie-jar=') ||
              argument == '--trace' ||
              argument.startsWith('--trace=') ||
              argument == '--trace-ascii' ||
              argument.startsWith('--trace-ascii=') ||
              argument == '--stderr' ||
              argument.startsWith('--stderr=') ||
              argument == '--hsts' ||
              argument.startsWith('--hsts=') ||
              argument == '--etag-save' ||
              argument.startsWith('--etag-save=') ||
              argument.startsWith('-o') && argument.length > 2;
        },
      );
    }
    return true;
  }

  bool _isLocalRedirectArgument(String argument) {
    return argument == '>' ||
        argument == '>>' ||
        argument == '<' ||
        argument == '2>' ||
        argument.startsWith('>') ||
        argument.startsWith('<') ||
        argument.startsWith('2>');
  }
}

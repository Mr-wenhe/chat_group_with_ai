part of 'default_work_task_runner.dart';

extension _DefaultWorkTaskRunnerRecovery on DefaultWorkTaskRunner {
  /// Called under the coordinator's freshly acquired lease. Portable history
  /// never becomes a trusted local receipt or an executable approval.
  Future<String?> _validateRecovery(AgentTask task) async {
    if (!WorkTaskExecutionPolicy.isValidatedV2GroupTask(task)) {
      return '恢复状态身份或版本无效。';
    }
    final state = _candidateState(task);
    final workspace = database.workModeWorkspaceBox.get(task.groupId);
    if (workspace == null ||
        workspace.projectScopeId != state.projectScopeId ||
        state.projectScopeId == 'portable-unbound') {
      return '项目需在本设备重新绑定并核对，历史认可不能授权执行。';
    }
    final memberError = await _validateRecoveryMembers(task, state);
    if (memberError != null) return memberError;
    final actionError =
        await _resolveUncertainAction(task, workspace.workDirPath);
    if (actionError != null) return actionError;
    return _validateRecoveryCandidate(task, state);
  }

  Future<String?> _validateRecoveryMembers(
      AgentTask task, WorkCollaborationState state) async {
    final actor = task.characterId;
    try {
      for (final member in state.team) {
        task.characterId = member['memberId'] as String;
        if (!await _productionActorAvailable(task, persist: false)) {
          return task.lastError;
        }
      }
    } finally {
      task.characterId = actor;
    }
    return null;
  }

  Future<String?> _resolveUncertainAction(
      AgentTask task, String workspaceRoot) async {
    final root = _decodeMap(task.executionStateJson);
    final uncertain = root['uncertainAction'];
    if (uncertain is Map &&
        uncertain['operationKey'] is String &&
        await eventStore.hasCommittedAction(
            task.id, uncertain['operationKey'] as String)) {
      root.remove('uncertainAction');
      task.executionStateJson = jsonEncode(root);
    } else if (uncertain != null) {
      if (uncertain is! Map ||
          uncertain['expectedSha256'] is! String ||
          uncertain['path'] is! String ||
          uncertain['tool'] != 'workspace.patch' ||
          workspaceFileService == null) {
        return '上次操作可能已发生副作用，无法证明结果；请核对后置条件，未重放外部调用、安装、删除或写入。';
      }
      final resolved = await workspaceFileService!.pathPolicy.resolveExisting(
          p.isAbsolute(uncertain['path'] as String)
              ? uncertain['path'] as String
              : p.join(workspaceRoot, uncertain['path'] as String));
      final file = File(resolved.path);
      if (await file.length() > WorkCandidatePublisher.maxFileBytes ||
          (await sha256.bind(file.openRead()).first).toString() !=
              uncertain['expectedSha256']) {
        return '上次写入的真实文件不符合预期摘要，保留不确定操作等待处理。';
      }
      final keys = (root['committedActionKeys'] as List? ?? const [])
          .whereType<String>()
          .toSet();
      final operationKey = uncertain['operationKey'];
      if (operationKey is! String || operationKey.isEmpty) {
        return '不确定操作缺少身份，不能恢复。';
      }
      await eventStore.recordCommittedAction(task.id, operationKey);
      keys.add(operationKey);
      root['committedActionKeys'] = keys.take(128).toList();
      root.remove('uncertainAction');
      task.executionStateJson = jsonEncode(root);
    }
    return null;
  }

  Future<String?> _validateRecoveryCandidate(
      AgentTask task, WorkCollaborationState state) async {
    if (state.currentIteration != null &&
        state.currentIteration!['requestRevision'] == state.requestRevision &&
        state.currentIteration!['teamRevision'] == state.teamRevision) {
      final publisher = await candidatePublisher(task);
      final candidates = await publisher.recover();
      final candidate = candidates
          .where((c) => c.iterationId == state.currentIteration!['id'])
          .single;
      await publisher.verify(candidate,
          expectedDigest: state.currentIteration!['artifactDigest'] as String);
      final report = state.currentIteration!['reviewRef'] as String;
      if (report.isNotEmpty &&
          !await publisher.evidenceValid(candidate, report)) {
        return '候选或真实被测文件已变化，旧验证和签字不能继续放行。';
      }
    }
    return null;
  }
}

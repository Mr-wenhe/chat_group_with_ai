part of 'default_work_task_runner.dart';

extension _ProductionChanges on DefaultWorkTaskRunner {
  Future<bool> _recoverUnchangedProduction(
      AgentTask task, WorkCollaborationState state) async {
    if (state.currentIteration == null ||
        state.workItems.any((item) => item['status'] != 'done')) {
      return false;
    }
    final publisher = await candidatePublisher(task);
    final candidates = await publisher.recover();
    final index = candidates.indexWhere(
        (candidate) => candidate.iterationId == state.currentIteration!['id']);
    if (index < 1) return false;
    final candidate = candidates[index];
    if (!(candidate.manifest['publicationId'] as String)
            .startsWith('production-') ||
        (candidate.manifest['baseline'] as String).isNotEmpty ||
        candidate.manifest['requestRevision'] != state.requestRevision ||
        candidate.manifest['teamRevision'] != state.teamRevision ||
        !candidate.hasSameFilesAs(candidates[index - 1])) {
      return false;
    }
    final item = state.workItems
        .where((item) =>
            item['kind'] != 'material' &&
            item['ownerId'] == candidate.producerId)
        .lastOrNull;
    if (item == null) return false;
    await publisher.verify(candidate, expectedDigest: candidate.digest);
    await publisher.verify(candidates[index - 1],
        expectedDigest: candidates[index - 1].digest);
    task.characterId = candidate.producerId;
    await _productionCommit(task, 'workItem', {
      'phase': 'producing',
      'workItems': [
        for (final current in state.workItems)
          current['id'] == item['id']
              ? {...current, 'status': 'pending', 'resultRef': ''}
              : current
      ]
    });
    await _record(task, WorkTaskEventKind.planning, '候选没有文件内容变更，已退回制作',
        detail: '当前制作候选与前一版的文件路径和 SHA-256 完全相同。'
            '旧候选、测试及聊天证据保留；本轮制作完成声明不证明优化已写入。'
            '继续完成已确认的修改后，重新冻结候选并独立测试。',
        safeMetadata: {
          'iterationId': candidate.iterationId,
          'previousIterationId': candidates[index - 1].iterationId
        });
    return true;
  }

  Future<void> _captureProductionBaseline(AgentTask task) async {
    final root = _decodeMap(task.executionStateJson);
    final binding = root['workItemExecution'];
    final existing = root['productionBaseline'];
    if (existing is Map &&
        jsonEncode(existing['binding']) == jsonEncode(binding)) {
      return;
    }
    final files = workspaceFileService;
    final workspace = _workspaceRootForTask(task);
    if (files == null || workspace == null) return;
    final hashes = <String, String?>{};
    for (final name in (_candidateState(task).artifactContract['files'] as List)
        .cast<String>()) {
      final path = p.normalize(p.join(workspace, name));
      try {
        final resolved = await files.pathPolicy.resolveNewTarget(path);
        hashes[resolved.path] = !resolved.exists
            ? null
            : resolved.isDirectory
                ? 'unavailable'
                : await WorkCandidatePublisher.fileDigest(File(resolved.path));
      } on Object {
        hashes[path] = 'unavailable';
      }
    }
    root['productionBaseline'] = {'binding': binding, 'hashes': hashes};
    task.executionStateJson = jsonEncode(root);
  }

  Future<String?> _validateProductionChanges(AgentTask task) async {
    if (!WorkTaskExecutionPolicy.isValidatedV2GroupTask(task)) return null;
    final root = _decodeMap(task.executionStateJson);
    final binding = root['workItemExecution'];
    if (binding is! Map || binding['stage'] != 'produce') return null;
    const failure = '本轮制作没有可核验的交付文件变更，不能把读取旧文件或模型的完成声明当作制作完成。'
        '请实际修改合同目标文件，读回核对后再提交；只写分段、重写相同内容或沿用旧轮写入记录均不算完成。';
    final receipt = root['productionChanges'];
    if (receipt is! Map ||
        receipt['paths'] is! Map ||
        jsonEncode(receipt['binding']) != jsonEncode(binding)) {
      return failure;
    }
    final files = workspaceFileService;
    final workspace = _workspaceRootForTask(task);
    if (files == null || workspace == null) return failure;
    final baseline = root['productionBaseline'];
    if (baseline is! Map ||
        baseline['hashes'] is! Map ||
        jsonEncode(baseline['binding']) != jsonEncode(binding)) {
      return failure;
    }
    final canonicalWorkspace =
        (await files.pathPolicy.resolveExisting(workspace)).path;
    final state = _candidateState(task);
    final declared = (state.artifactContract['files'] as List).cast<String>();
    final previous = state.currentIteration == null
        ? null
        : (await (await candidatePublisher(task)).recover()).lastOrNull;
    for (final entry in (receipt['paths'] as Map).entries) {
      if (entry.key is! String ||
          entry.value is! Map ||
          (entry.value as Map)['changed'] != true) {
        continue;
      }
      final path = p.normalize(p.isAbsolute(entry.key as String)
          ? entry.key as String
          : p.join(workspace, entry.key as String));
      try {
        final resolved = await files.pathPolicy.resolveExisting(path);
        final relative = p.relative(resolved.path, from: canonicalWorkspace);
        if (state.artifactContract['nativeBundle'] == null &&
            !declared.contains(relative)) {
          continue;
        }
        if (resolved.isDirectory) continue;
        final digest =
            await WorkCandidatePublisher.fileDigest(File(resolved.path));
        final baselinePath =
            (baseline['hashes'] as Map).containsKey(resolved.path)
                ? resolved.path
                : path;
        final initial = (baseline['hashes'] as Map)[baselinePath];
        if (state.artifactContract['nativeBundle'] == null &&
            (!(baseline['hashes'] as Map).containsKey(baselinePath) ||
                initial == 'unavailable' ||
                initial == digest)) {
          continue;
        }
        final after = (entry.value as Map)['afterSha256'];
        if (after is String && after != digest) continue;
        final before = (entry.value as Map)['beforeSha256'];
        if (before is String && before == digest) continue;
        final old = previous?.files
            .where((file) => file['path'] == relative)
            .firstOrNull;
        if (old != null && old['sha256'] == digest) continue;
        return null;
      } on Object {
        // Missing or unauthorized output cannot prove this work item completed.
      }
    }
    return failure;
  }
}

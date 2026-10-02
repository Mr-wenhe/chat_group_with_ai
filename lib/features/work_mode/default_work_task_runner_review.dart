part of 'default_work_task_runner.dart';

class _ProductionReview {
  final WorkCandidatePublisher publisher;
  final WorkCandidateReview review;
  final List<Map<String, dynamic>> receipts = [];
  Map<String, dynamic>? conclusion;
  final Map<String, String> results = {};
  _ProductionReview(this.publisher, this.review);
}

extension _DefaultWorkTaskRunnerReview on DefaultWorkTaskRunner {
  Future<_ProductionReview?> _prepareProductionReview(AgentTask task) async {
    final binding =
        _decodeMap(task.executionStateJson)['workItemExecution'] as Map?;
    if (binding?['stage'] != 'verify') return null;
    final state = _candidateState(task);
    final publisher = await candidatePublisher(task);
    final candidate = (await publisher.recover())
        .where((c) => c.iterationId == binding!['iterationId'])
        .single;
    final root = _workspaceRootForTask(task)!;
    final tested = {
      for (final f in candidate.files)
        f['path'] as String: File(p.join(root, f['path'] as String))
    };
    final reviews = Directory('${candidate.directory.path}/reviews');
    final attempt = await reviews.exists()
        ? await reviews.list(followLinks: false).length
        : 0;
    final review = await publisher.beginReview(
        candidate: candidate,
        attemptId: 'a${state.revision}-$attempt',
        actorId: task.characterId,
        verificationRevision: state.verificationRevision + 1,
        testedFiles: tested);
    final result = _ProductionReview(publisher, review);
    final receiptRef =
        _decodeMap(task.executionStateJson)['v2ReviewReceiptRef'];
    if (receiptRef is String) {
      final saved =
          jsonDecode(await eventStore.readDiscussionDetail(task.id, receiptRef))
              as Map;
      if (saved['artifactDigest'] != candidate.digest ||
          saved['verificationRevision'] != review.verificationRevision ||
          jsonEncode(saved['binding']) != jsonEncode(binding)) {
        throw StateError('旧工具证据不属于当前审查基线。');
      }
      result.receipts.addAll((saved['receipts'] as List)
          .map((r) => Map<String, dynamic>.from(r as Map)));
    }
    return result;
  }

  Future<void> _recordProductionReviewReceipt(
      AgentTask task,
      _ProductionReview review,
      AgentToolCall call,
      WorkToolResult result) async {
    await review.publisher.verify(review.review.candidate,
        expectedDigest: review.review.candidate.digest,
        testedFiles: review.review.testedFiles);
    if (!result.succeeded && result.failureCode != 'commandFailed') return;
    review.receipts.add({
      'tool': call.name.wireName,
      'arguments': call.arguments,
      'status': result.status.name,
      'data': result.data
    });
    final root = _decodeMap(task.executionStateJson);
    final text = const SearchSecretScanner().redact(jsonEncode({
      'binding': root['workItemExecution'],
      'artifactDigest': review.review.candidate.digest,
      'verificationRevision': review.review.verificationRevision,
      'receipts': review.receipts
    }));
    final digest =
        sha256.convert(utf8.encode(text)).toString().substring(0, 24);
    await eventStore.writeDiscussionDetail(task.id, digest, text);
    root['v2ReviewReceiptRef'] = digest;
    task.executionStateJson = jsonEncode(root);
    // The loop checkpoints this reference together with its committed key.
  }

  WorkToolRegistry _reviewRegistry(
      AgentTask task, WorkToolRegistry registry, _ProductionReview review) {
    return WorkToolRegistry(
        mutationPipeline: registry.mutationPipeline,
        definitions: [
          for (final definition in registry.definitions)
            WorkToolDefinition(
                name: definition.name,
                access: definition.access,
                schema: definition.schema,
                mutationPipeline: definition.mutationPipeline,
                handler: (invocation) async {
                  // Review may run approved commands, but must not rewrite the
                  // candidate or test assertions to make a failing baseline green.
                  if (definition.isMutation &&
                      definition.name != AgentToolName.commandRun) {
                    return const WorkToolResult.permissionDenied(
                        message: '审查阶段不能改写产物或测试断言；请回群讨论修订。');
                  }
                  await review.publisher.verify(review.review.candidate,
                      expectedDigest: review.review.candidate.digest,
                      testedFiles: review.review.testedFiles);
                  final result = await definition.handler(invocation);
                  await review.publisher.verify(review.review.candidate,
                      expectedDigest: review.review.candidate.digest,
                      testedFiles: review.review.testedFiles);
                  return result;
                })
        ]);
  }

  String? _validateProfessionalReview(
      AgentTask task, _ProductionReview review) {
    final state = _candidateState(task);
    final format = state.artifactContract['format'] as String;
    final primary = review.review.testedFiles!.entries.where(
        (e) => WorkArtifactDeliveryGuard.matchesContractFormat(e.key, format));
    if (primary.isEmpty) return '专业审查缺少明确正文文件。';
    for (final file in primary) {
      final receipts = review.receipts.where((r) =>
          {'workspace.read', 'workspace.document'}.contains(r['tool']) &&
          r['status'] == WorkToolResultStatus.success.name &&
          (r['data'] as Map)['path'] == file.value.resolveSymbolicLinksSync());
      if (receipts.any((r) => (r['data'] as Map)['truncated'] == false)) {
        continue;
      }
      final pages = receipts
          .where((r) => r['tool'] == 'workspace.document')
          .map((r) => r['data'] as Map)
          .toList();
      final totals =
          pages.map((r) => r['totalChunkCount']).whereType<int>().toSet();
      final covered = <int>{};
      for (final page in pages) {
        final start = page['chunkStart'];
        final count = page['chunkCount'];
        if (start is int &&
            count is int &&
            start >= 0 &&
            count > 0 &&
            count <= DocumentUnderstandingService.maxRetrievedChunks) {
          covered.addAll(List.generate(count, (index) => start + index));
        }
      }
      if (totals.length == 1 &&
          totals.single > 0 &&
          covered.length == totals.single &&
          covered.every((index) => index < totals.single)) {
        continue;
      }
      return '正文尚未完整读取或格式解析，不能声称专业审查通过。';
    }
    if (state.acceptances.any((a) =>
        RegExp(r'web|browser|network', caseSensitive: false)
            .hasMatch(a['requiredCapability'] as String))) {
      return '当前审查入口未接通网络来源核验能力；请补充已有授权工具或人工核验，未伪造来源。';
    }
    return null;
  }

  String? _validateSoftwareCoverage(WorkCollaborationState state,
      _ProductionReview review, List<String> ids) {
    final covered = <String>{};
    for (final receipt
        in review.receipts.where((r) => r['tool'] == 'command.run')) {
      final data = receipt['data'] as Map;
      final output = data['stdout'];
      if (output is! String || data['outputTruncated'] == true) continue;
      try {
        final execution = jsonDecode(output) as Map;
        if (execution['artifactDigest'] != review.review.candidate.digest ||
            execution['tests'] is! List) {
          continue;
        }
        for (final test in (execution['tests'] as List).whereType<Map>()) {
          final acceptance =
              state.acceptances.where((a) => a['id'] == test['id']).firstOrNull;
          if (acceptance == null ||
              !{'passed', 'failed'}.contains(test['status']) ||
              test['method'] != acceptance['requiredCapability'] ||
              test['expected'] is! String ||
              test['actual'] is! String ||
              test['reproduction'] is! String) {
            continue;
          }
          covered.add(test['id'] as String);
          review.results[test['id'] as String] = test['status'] as String;
        }
      } on Object {/* Ordinary output is not structured coverage. */}
    }
    if (!ids.every(covered.contains) ||
        review.results.keys.any((id) => !ids.contains(id))) {
      return '实际运行结果未覆盖报告的全部验收项，需明确用例、结果与候选摘要。';
    }
    return null;
  }

  String? _validateReviewDefects(_ProductionReview review,
      Map<String, dynamic> conclusion, List<String> ids) {
    final defects = (conclusion['defects'] as List).cast<Map>();
    if (review.results.values.contains('failed') &&
            conclusion['result'] != 'failed' ||
        review.results.entries.any((e) =>
            e.value == 'failed' &&
            !defects.any((d) => d['acceptanceId'] == e.key))) {
      return '实际运行发现的失败必须全部进入缺陷报告，不能省略或概括为通过。';
    }

    if (conclusion['result'] == 'failed' && defects.isEmpty ||
        conclusion['result'] == 'passed' && defects.isNotEmpty) {
      return '失败报告须记录全部缺陷，通过报告不能保留未决缺陷。';
    }
    for (final defect in defects) {
      if (![
            'acceptanceId',
            'reproduction',
            'expected',
            'actual',
            'retestCondition'
          ].every((k) =>
              defect[k] is String && (defect[k] as String).trim().isNotEmpty) ||
          !ids.contains(defect['acceptanceId'])) {
        return '缺陷缺少复现、预期、实际、关联验收或复测条件。';
      }
    }
    return null;
  }

  String? _validateReviewShape(WorkCollaborationState state,
      _ProductionReview review, Map<String, dynamic> conclusion) {
    if (!{'passed', 'failed', 'blocked'}.contains(conclusion['result']) ||
        conclusion['method'] is! String ||
        (conclusion['method'] as String).trim().isEmpty ||
        conclusion['report'] is! String ||
        (conclusion['report'] as String).trim().isEmpty ||
        conclusion['acceptanceIds'] is! List ||
        conclusion['defects'] is! List) {
      return '审查结论缺少方法、完整报告、验收项或缺陷。';
    }
    final ids = (conclusion['acceptanceIds'] as List).cast<String>();
    if (ids.isEmpty ||
        ids.toSet().length != ids.length ||
        ids.any((id) => !state.acceptances.any((a) => a['id'] == id))) {
      return '报告引用了未知或重复验收项。';
    }
    if (review.receipts.isEmpty && conclusion['result'] != 'blocked') {
      return '没有本轮实际工具证据，不能声称验证通过或复现缺陷。';
    }
    return null;
  }

  Future<String?> _validateProductionReview(AgentTask task,
      _ProductionReview review, AgentFinishCompletion completion) async {
    if (completion.evidence.length != 1) return '审查必须提交一份完整结构化结论，不把退出码当验收。';
    try {
      final conclusion = Map<String, dynamic>.from(
          jsonDecode(completion.evidence.single) as Map);
      final state = _candidateState(task);
      final shapeFailure = _validateReviewShape(state, review, conclusion);
      if (shapeFailure != null) return shapeFailure;
      final ids = (conclusion['acceptanceIds'] as List).cast<String>();
      if (state.artifactContract['type'] != 'software' &&
          conclusion['result'] != 'blocked') {
        final failure = _validateProfessionalReview(task, review);
        if (failure != null) return failure;
      }
      if (state.artifactContract['type'] == 'software' &&
          state.acceptances
              .any((a) => !{'manual', 'waived'}.contains(a['status'])) &&
          conclusion['result'] != 'blocked') {
        final failure = _validateSoftwareCoverage(state, review, ids);
        if (failure != null) return failure;
      }
      final defectFailure = _validateReviewDefects(review, conclusion, ids);
      if (defectFailure != null) return defectFailure;
      await review.publisher.verify(review.review.candidate,
          expectedDigest: review.review.candidate.digest,
          testedFiles: review.review.testedFiles);
      review.conclusion = conclusion;
      return null;
    } on Object {
      return '审查结构或候选身份无效，请保留全部问题重新提交。';
    }
  }

  Map<String, dynamic> _reviewStatePatch(WorkCollaborationState state,
      _ProductionReview review, AICharacter actor) {
    final result = review.conclusion!['result'] as String;
    final ids = (review.conclusion!['acceptanceIds'] as List).cast<String>();
    final defects = (review.conclusion!['defects'] as List).cast<Map>();
    final ref = review.review.reference;
    return {
      'verificationRevision': review.review.verificationRevision,
      'phase': result == 'failed' ? 'clarifying' : 'reviewing',
      'acceptances': [
        for (final a in state.acceptances)
          {
            ...a,
            'verificationRevision': review.review.verificationRevision,
            if (ids.contains(a['id']) &&
                !{'manual', 'waived'}.contains(a['status']))
              'status': result == 'blocked'
                  ? 'pending'
                  : review.results[a['id']] ?? result,
            if (ids.contains(a['id']) &&
                !{'manual', 'waived'}.contains(a['status']))
              'evidenceRef': ref,
          }
      ],
      'iterations': [
        for (final i in state.iterations)
          i['id'] == review.review.candidate.iterationId
              ? {...i, 'status': 'reviewed', 'reviewRef': ref}
              : i
      ],
      'issues': [
        ...state.issues,
        for (var index = 0; index < defects.length; index++)
          {
            'id': 'defect-${review.review.candidate.iterationId}-$index',
            'sourceId': actor.id,
            'kind': 'defect',
            'status': 'open',
            'target': defects[index]['acceptanceId'],
            'problem':
                '复现：${defects[index]['reproduction']}；预期：${defects[index]['expected']}；实际：${defects[index]['actual']}',
            'evidenceRef': ref,
            'resolution': '',
            'resolutionRef': '',
            'retestCondition': defects[index]['retestCondition'],
            'requestRevision': state.requestRevision,
          }
      ]
    };
  }

  Future<void> _finishProductionReview(
      AgentTask task, _ProductionReview review, AICharacter actor) async {
    final conclusion = review.conclusion;
    if (conclusion == null) {
      await _productionDecision(
          task, 'acceptance', '', '审查未形成有效结论；不能用 handoff 跳过验证。');
      return;
    }
    task.status = AgentTaskStatus.runningTool;
    final state = _candidateState(task);
    final result = conclusion['result'] as String;
    final ids = (conclusion['acceptanceIds'] as List).cast<String>();
    final report = await review.publisher.appendReview(review.review,
        method: conclusion['method'] as String,
        source: 'tool',
        receipt:
            'loop:${task.id}:${state.requestRevision}:${review.review.attemptId}',
        result: result,
        acceptanceIds: ids,
        report: WorkPublicUpdateStream.sanitize(jsonEncode(
            {'conclusion': conclusion, 'receipts': review.receipts})));
    final record = await WorkCandidatePublisher.readMetadata(report);
    if (record['result'] == 'invalidated') throw StateError('被测文件已变化，旧结论失效。');
    await _productionCommit(
        task, 'review', _reviewStatePatch(state, review, actor));
    await sendCandidateVersion(task, review.review.candidate,
        kind: 'review', report: report);
    await database.persistMessage(Message(
        groupId: task.groupId,
        senderId: actor.id,
        senderType: 'ai',
        isWorkMode: true,
        content: task.resultSummary));
    task
      ..status = AgentTaskStatus.paused
      ..resumeRequired = false;
    if (result == 'blocked' ||
        state.acceptances.any((a) =>
            !ids.contains(a['id']) && !state.deferredWork.contains(a['id']))) {
      final target = state.acceptances
          .where((a) => result == 'blocked'
              ? ids.contains(a['id'])
              : !ids.contains(a['id']) && !state.deferredWork.contains(a['id']))
          .first;
      await _productionDecision(task, 'acceptance', target['id'] as String,
          '当前验收缺少实际验证能力或覆盖，请补充环境、人工验收、明确豁免或暂缓。');
    }
    await _persistCheckpoint(task);
  }
}

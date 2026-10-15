part of 'backup_restore_service_test.dart';

Future<WorkCandidate> _seedP6BackupCandidate() async {
  final source =
      await File('${testRoot.path}/report.txt').writeAsString('frozen report');
  await _seedCoreData(db, source);
  final json = candidateTestState().toJson()
    ..['taskId'] = 'p6-task'
    ..['conversationId'] = 'group-1'
    ..['coordinatorId'] = 'char-1'
    ..['team'] = [
      {
        'memberId': 'char-1',
        'role': 'writer',
        'qualificationRef': 'skill',
        'qualified': true,
        'available': true,
      }
    ];
  final state = WorkCollaborationState.tryParse(json)!;
  final publisher = WorkCandidatePublisher(
      Directory('${mediaDirectory.path}/work-deliveries/p6-task'));
  final candidate = await publisher.publish(
      publicationId: 'first',
      state: state,
      producerId: 'char-1',
      sources: {'report.txt': source});
  final review = await publisher.beginReview(
      candidate: candidate,
      attemptId: 'a1',
      actorId: 'char-1',
      verificationRevision: 1);
  await publisher.appendReview(review,
      method: 'read',
      source: 'tool',
      receipt: 'read-1',
      result: 'passed',
      acceptanceIds: ['qa'],
      report: 'checked');
  final files = <Map<String, dynamic>>[];
  await for (final entity
      in candidate.directory.list(recursive: true, followLinks: false)) {
    if (entity is File) {
      files.add({
        'relative': entity.path.substring(publisher.directory.path.length + 1),
        'path': entity.path,
        'bytes': await entity.length(),
        'sha256': await WorkCandidatePublisher.fileDigest(entity)
      });
    }
  }
  await db.agentTaskBox.put(
      'p6-task',
      AgentTask(
          id: 'p6-task',
          groupId: 'group-1',
          characterId: 'char-1',
          userRequest: '报告'));
  await db.messageBox.put(
      'p6-delivery',
      Message(
          id: 'p6-delivery',
          groupId: 'group-1',
          senderId: 'char-1',
          senderType: 'ai',
          isWorkMode: true,
          content: '候选送测 r001',
          media: [
            MediaAttachment(
                type: 'file', localPath: candidate.file('report.txt').path)
          ],
          workDelivery: {
            ...candidate.reference,
            'kind': 'candidate',
            'senderId': 'char-1',
            'evidenceRef': '',
            'verified': true,
            'files': files
          }));
  return candidate;
}

void _registerP6BackupTests() {
  test('P1 自主策略、成员场景、收据引用和定案随备份重映射但不带本地授权', () async {
    await _seedP6BackupCandidate();
    final raw = candidateTestState().toJson()
      ..['taskId'] = 'p6-task'
      ..['conversationId'] = 'group-1'
      ..['coordinatorId'] = 'char-1'
      ..['autonomyPolicy'] = WorkCollaborationAutonomy.policyFor(['char-1'])
      ..['usageAssignments'] = [
        {
          'memberId': 'char-1',
          'scenarioId': 'document-scene',
          'goal': '检查真实正文',
          'preconditions': '当前报告',
          'stepGoals': ['核对术语'],
          'expectedResult': '术语准确',
          'acceptanceIds': ['qa'],
          'requiredCapabilities': ['document'],
          'resetMethod': '重新打开文件',
          'requestRevision': 1,
        }
      ]
      ..['usageEvidenceRefs'] = []
      ..['coordinatorDecisions'] = []
      ..['approvals'] = [candidateTestApproval('char-1', 'plan', 'p6-task')]
      ..['team'] = [
        {
          'memberId': 'char-1',
          'role': 'writer',
          'qualificationRef': 'skill',
          'qualified': true,
          'available': true,
        }
      ];
    final plan = WorkCollaborationState.tryParse(raw)!;
    raw['usageEvidenceRefs'] = [
      {
        'taskId': 'p6-task',
        'conversationId': 'group-1',
        'memberId': 'char-1',
        'scenarioId': 'document-scene',
        'requestRevision': 1,
        'teamRevision': 1,
        'iterationId': 'r001',
        'artifactDigest': 'digest',
        'planDigest': plan.usagePlanDigest,
        'verificationRevision': 1,
        'receiptRef': 'usage:${'a' * 24}',
        'feedbackRef': 'p6-delivery',
        'status': 'passed',
      }
    ];
    raw['coordinatorDecisions'] = [
      {
        'eventId': 'ruling',
        'coordinatorId': 'char-1',
        'kind': 'plan',
        'subjectId': 'p6-task',
        'requestRevision': 1,
        'teamRevision': 1,
        'verificationRevision': 1,
        'iterationId': '',
        'artifactDigest': '',
        'opinionEventIds': ['plan-char-1-1'],
        'reason': '确认当前方案',
        'responseRef': 'p6-delivery',
      }
    ];
    final task = AgentTask(
        id: 'p6-task',
        groupId: 'group-1',
        characterId: 'char-1',
        userRequest: '报告',
        workModeTask: true);
    task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
        '',
        WorkDiscussionState(
            schemaVersion: 2,
            conversationId: 'group-1',
            phase: WorkDiscussionPhase.ready,
            requestRevision: 1,
            collaboration: WorkCollaborationState.tryParse(raw)!));
    await db.agentTaskBox.put(task.id, task);
    final service = BackupRestoreService(
        db: db, mediaDirectory: mediaDirectory, tempRoot: testRoot);
    final backup = File('${testRoot.path}/autonomy.cgbak');
    await service.createBackup(
        destination: backup, selection: const BackupSelection.all());
    final prepared = await service.inspect(backup);
    addTearDown(prepared.dispose);
    await service.restore(prepared,
        strategy: RestoreConflictStrategy.copyWithNewIds);
    final restoredTask = db.agentTaskBox.values
        .where((t) => t.id != 'p6-task' && t.workModeTask)
        .single;
    final state =
        WorkDiscussionState.fromExecutionState(restoredTask.executionStateJson)!
            .collaboration!;
    final restoredMember = state.participantIds.single;
    expect(restoredMember, isNot('char-1'));
    expect(state.usageAssignments.single['memberId'], restoredMember);
    final receipt = state.usageEvidenceRefs.single;
    expect(receipt['memberId'], restoredMember);
    expect(receipt['taskId'], restoredTask.id);
    expect(receipt['conversationId'], restoredTask.groupId);
    expect(receipt['feedbackRef'], isNot('p6-delivery'));
    expect(state.coordinatorDecisions.single['coordinatorId'], restoredMember);
    expect(state.coordinatorDecisions.single['subjectId'], restoredTask.id);
    expect(state.coordinatorDecisions.single['responseRef'],
        receipt['feedbackRef']);
    expect(state.planReady, isFalse);
    expect(state.deliveryReady, isFalse);
    expect(state.projectScopeId, 'portable-unbound');
  });

  for (final selection in [
    const BackupSelection.all(),
    const BackupSelection.conversation('group-1')
  ]) {
    test(
        'P6 nested frozen files and reports backup ${selection.scope.name}, new IDs remain unverified',
        () async {
      final candidate = await _seedP6BackupCandidate();
      final service = BackupRestoreService(
          db: db, mediaDirectory: mediaDirectory, tempRoot: testRoot);
      final backup = File('${testRoot.path}/candidate.cgbak');
      await service.createBackup(destination: backup, selection: selection);
      final archive = ZipDecoder().decodeBytes(await backup.readAsBytes());
      final text =
          utf8.decode(archive.findFile('data/messages.jsonl')!.content);
      expect(text, contains('workDelivery'));
      expect(text, isNot(contains(testRoot.path)));
      expect(text, isNot(contains('work_mode_folder_grants')));
      final prepared = await service.inspect(backup);
      addTearDown(prepared.dispose);
      await service.restore(prepared,
          strategy: RestoreConflictStrategy.copyWithNewIds);
      final imported = db.messageBox.values
          .where((m) => m.workDelivery != null && m.id != 'p6-delivery')
          .single;
      final metadata = imported.workDelivery!;
      expect(metadata['verified'], isFalse);
      expect(metadata['taskId'], isNot('p6-task'));
      expect(metadata['conversationId'], imported.groupId);
      expect(metadata['senderId'], imported.senderId);
      expect(metadata['producerId'], imported.senderId);
      expect(metadata['artifactDigest'], candidate.digest);
      final entries = (metadata['files'] as List).cast<Map>();
      expect(entries.any((e) => e['relative'] == 'r001/reviews/a1/report.json'),
          isTrue);
      for (final entry in entries) {
        final file = File(entry['path'] as String);
        expect(await file.exists(), isTrue);
        expect(await WorkCandidatePublisher.fileDigest(file), entry['sha256']);
      }
    });
  }

  test(
      'P6 configuration backup excludes delivery history; tampered and missing candidate files are explicit',
      () async {
    final candidate = await _seedP6BackupCandidate();
    final service = BackupRestoreService(
        db: db, mediaDirectory: mediaDirectory, tempRoot: testRoot);
    final configuration = File('${testRoot.path}/config.cgbak');
    final config = await service.createBackup(
        destination: configuration,
        selection: const BackupSelection.configurationOnly());
    expect(config.manifest.counts['attachments'], 0);
    await candidate.file('report.txt').writeAsString('tampered');
    await expectLater(
        service.createBackup(
            destination: File('${testRoot.path}/tampered.cgbak')),
        throwsA(isA<BackupException>()));
    await candidate.file('report.txt').delete();
    final missing = await service.createBackup(
        destination: File('${testRoot.path}/missing.cgbak'));
    expect(missing.manifest.missingAttachments,
        contains('交付版本:r001/artifacts/report.txt'));
  });
}

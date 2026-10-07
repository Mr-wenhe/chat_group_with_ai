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

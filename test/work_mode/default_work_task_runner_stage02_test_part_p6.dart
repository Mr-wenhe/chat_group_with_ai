part of 'default_work_task_runner_stage02_test.dart';

void _registerP6RunnerTests(Directory Function() hiveRoot,
    Directory Function() workRoot, WorkTaskEventStore Function() events) {
  Future<DefaultWorkTaskRunner> runner({bool failCopy = false}) async {
    final db = CandidateTestDatabase(hiveRoot());
    addTearDown(db.dispose);
    final grants = WorkFolderGrantService(
        box: db.appSettingsBox,
        directoryValidator: (_) async => true,
        writeDirectoryValidator: (_) async => true,
        isWindows: false);
    await grants.authorizeDirectory(workRoot().path,
        consent: (_) async => true);
    return DefaultWorkTaskRunner(
        database: db,
        eventStore: events(),
        credentials: _TestCredentials(),
        gateway: _HangingModelGateway(),
        workspaceFileService: WorkspaceFileService(
            pathPolicy: WorkspacePathPolicy(grantService: grants)),
        mediaCopier: failCopy
            ? (source, type, {fileName}) async =>
                throw const FileSystemException('copy failed')
            : null);
  }

  Future<AgentTask> task(DefaultWorkTaskRunner runner,
      {String type = 'document', String format = 'txt'}) async {
    final task =
        candidateTestTask(candidateTestState(type: type, format: format));
    final file = await File('${workRoot().path}/report.$format').writeAsString(
        format == 'html'
            ? '<html><body>game r001</body></html>'
            : 'report r001');
    task.lastArtifactPaths = [file.path];
    await runner.database.workModeWorkspaceBox.put(
        task.groupId,
        WorkModeWorkspace(
            conversationId: task.groupId,
            conversationType: 'group',
            workDirPath: workRoot().path,
            projectScopeId: 'scope-a'));
    await runner.database.agentTaskBox.put(task.id, task);
    return task;
  }

  test(
      'P6 sealed final retry ignores later acceptance state and detects changed outcome',
      () async {
    final delivery = await runner();
    final work = await task(delivery);
    final candidate =
        await delivery.publishCandidate(work, publicationId: 'first');
    final outcome = await File('${candidate.directory.path}/outcome.json')
        .writeAsString('{"accepted":true}');
    final metadata = Map<String, dynamic>.from(
        delivery.database.messageBox.values.single.workDelivery!);
    metadata['kind'] = 'final';
    (metadata['files'] as List).add({
      'relative': '${candidate.iterationId}/outcome.json',
      'path': outcome.path,
      'bytes': await outcome.length(),
      'sha256': await WorkCandidatePublisher.fileDigest(outcome),
    });
    final id =
        'delivery-${sha256.convert(utf8.encode('${work.id}:${candidate.iterationId}:final:'))}';
    await delivery.database.persistMessage(Message(
        id: id,
        groupId: work.groupId,
        senderId: 'a',
        senderType: 'ai',
        content: '',
        workDelivery: metadata));
    expect(await delivery.resendCandidateMessage(work, id), isTrue);
    await outcome.writeAsString('{"accepted":false}');
    await expectLater(
        delivery.resendCandidateMessage(work, id), throwsStateError);
  });

  test(
      'P6 candidate has immediately openable frozen attachment and stays nonterminal',
      () async {
    final delivery = await runner();
    final work = await task(delivery);
    final candidate =
        await delivery.publishCandidate(work, publicationId: 'first');
    final message = delivery.database.messageBox.values.single;
    expect(message.content, contains('候选送测 r001'));
    expect(message.media, isNotEmpty);
    expect(
        message.media!.single.localPath, startsWith(candidate.directory.path));
    await File(work.lastArtifactPaths.single)
        .writeAsString('repaired working file');
    expect(await File(message.media!.single.localPath).readAsString(),
        'report r001');
    expect(work.isTerminal, isFalse);
    expect(
        WorkDiscussionState.fromExecutionState(work.executionStateJson)!
            .collaboration!
            .currentIteration!['artifactDigest'],
        candidate.digest);
  });

  test(
      'P6 failed copy resends same iteration with original producer after actor handoff',
      () async {
    final failed = await runner(failCopy: true);
    final work = await task(failed);
    final candidate =
        await failed.publishCandidate(work, publicationId: 'first');
    final message = failed.database.messageBox.values.single;
    expect(message.content, contains('附件投递失败'));
    work.characterId = 'b';
    await File(work.lastArtifactPaths.single)
        .writeAsString('external edit to working file');
    final restarted = await runner();
    expect(await restarted.resendCandidateMessage(work, message.id), isTrue);
    expect(await restarted.resendCandidateMessage(work, message.id), isTrue);
    final saved = restarted.database.messageBox.get(message.id)!;
    expect(saved.senderId, 'a');
    expect(await File(saved.media!.single.localPath).readAsString(),
        'report r001');
    expect(restarted.database.messageBox.length, 1);
    expect(
        (await (await restarted.candidatePublisher(work)).recover())
            .single
            .digest,
        candidate.digest);
    // Going through the runner retry branch must never call this hanging model.
    work.status = AgentTaskStatus.queued;
    final metadata = jsonDecode(work.executionStateJson) as Map;
    metadata['artifactDeliveryNoticePublished'] = true;
    metadata['artifactDeliveryRetryOnly'] = true;
    metadata['artifactDeliveryMessageId'] = message.id;
    work.executionStateJson = jsonEncode(metadata);
    await restarted.run(work, WorkTaskCancellation());
    expect(work.status, AgentTaskStatus.paused);
    expect(work.isTerminal, isFalse);
  });

  test(
      'P6 software contract packs complete relative files and rejects missing assets',
      () async {
    final delivery = await runner();
    final work = await task(delivery, type: 'software', format: 'html');
    final html = File(work.lastArtifactPaths.single);
    await html.writeAsString(
        '<html><body><script src="scripts/game.js"></script></body></html>');
    await expectLater(delivery.publishCandidate(work, publicationId: 'first'),
        throwsStateError);
    await expectLater(
        delivery.publishCandidate(work,
            publicationId: 'first', requiredPaths: [html.path]),
        throwsStateError);
    await (await delivery.candidatePublisher(work)).discardUnpublished('first');
    final script = File('${workRoot().path}/scripts/game.js');
    await script.parent.create();
    await script.writeAsString('console.log("game");');
    final candidate = await delivery.publishCandidate(work,
        publicationId: 'first', requiredPaths: [html.path, script.path]);
    final attachment = delivery.database.messageBox.values.single.media!.single;
    final zip = ZipDecoder()
        .decodeBytes(await File(attachment.localPath).readAsBytes());
    expect(zip.files.map((f) => f.name),
        containsAll(['report.html', 'scripts/game.js']));
    expect(candidate.files.length, 2);
  });

  test(
      'P6 snapshot cleanup and task true deletion preserve candidates; message cleanup reclaims managed versions',
      () async {
    final delivery = await runner();
    final work = await task(delivery);
    final candidate =
        await delivery.publishCandidate(work, publicationId: 'first');
    final snapshots = WorkSnapshotService(
        appSupportDirectory: Directory('${hiveRoot().path}/support'));
    await snapshots.cleanup();
    expect(await candidate.file('report.txt').exists(), isTrue);
    final coordinator = WorkTaskCoordinator(
        taskBox: delivery.database.agentTaskBox,
        runner: delivery,
        eventStore: events());
    addTearDown(coordinator.dispose);
    await coordinator.deleteTask(work.id);
    expect(delivery.database.agentTaskBox.containsKey(work.id), isFalse);
    expect(await File(work.lastArtifactPaths.single).exists(), isTrue);
    expect(await candidate.file('report.txt').exists(), isTrue);
    final lifecycle = DataLifecycleService(
        db: delivery.database,
        managedMediaDirectory: await delivery.database.mediaDir);
    await lifecycle.cleanupOrphanMedia();
    expect(await candidate.file('report.txt').exists(), isTrue);
    final message = delivery.database.messageBox.values.single;
    await lifecycle.deleteMessage(message.id, groupId: work.groupId);
    expect(await candidate.file('report.txt').exists(), isFalse);
    expect(await File('${candidate.directory.path}/candidate.json').exists(),
        isFalse);
    expect(await File(work.lastArtifactPaths.single).exists(), isTrue);
    await expectLater(
        delivery.resendCandidateMessage(work, message.id), throwsStateError);
    expect(delivery.database.agentTaskBox.containsKey(work.id), isFalse);
  });

  test('P6 frozen candidate guard rejects false DOCX and empty HTML body',
      () async {
    final delivery = await runner();
    final work = await task(delivery, format: 'docx');
    await expectLater(
        delivery.publishCandidate(work, publicationId: 'fake-docx'),
        throwsStateError);
    expect(
        await WorkArtifactDeliveryGuard.validateFrozenFile(
            File(work.lastArtifactPaths.single)),
        isFalse);
    final empty = await File('${workRoot().path}/empty.html')
        .writeAsString('<html><body> <!-- empty --> </body></html>');
    expect(await WorkArtifactDeliveryGuard.validateFrozenFile(empty), isFalse);
  });
}

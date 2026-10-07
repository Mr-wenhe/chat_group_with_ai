import 'dart:convert';
import 'dart:io';
import 'package:chat_group/features/work_mode/work_candidate_publication.dart';
import 'package:chat_group/features/work_mode/work_collaboration_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'work_candidate_test_support.dart';

void main() {
  late Directory root;
  late File working;
  late WorkCandidatePublisher publisher;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('p6_candidate_');
    working =
        await File('${root.path}/working.txt').writeAsString('broken r001');
    publisher = WorkCandidatePublisher(
        Directory('${root.path}/media/work-deliveries/task-a'));
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });
  Future<WorkCandidate> publish(String id) => publisher.publish(
      publicationId: id,
      state: candidateTestState(),
      producerId: 'a',
      sources: {'report.txt': working});

  test('r001 failure and repaired r002 open different frozen bytes and reports',
      () async {
    final first = await publish('first');
    final a1 = await publisher.beginReview(
        candidate: first,
        attemptId: 'attempt1',
        actorId: 'b',
        verificationRevision: 1);
    final report1 = await publisher.appendReview(a1,
        method: 'read',
        source: 'tool',
        receipt: 'read-1',
        result: 'failed',
        acceptanceIds: ['qa'],
        report: 'expected repaired, actual broken');
    await working.writeAsString('repaired r002');
    final second = await publish('second');
    final a2 = await publisher.beginReview(
        candidate: second,
        attemptId: 'attempt1',
        actorId: 'b',
        verificationRevision: 1);
    final report2 = await publisher.appendReview(a2,
        method: 'read',
        source: 'tool',
        receipt: 'read-2',
        result: 'passed',
        acceptanceIds: ['qa'],
        report: 'repaired');
    expect(first.iterationId, 'r001');
    expect(second.iterationId, 'r002');
    expect(first.file('report.txt').readAsStringSync(), 'broken r001');
    expect(second.file('report.txt').readAsStringSync(), 'repaired r002');
    expect(first.digest, isNot(second.digest));
    expect(jsonDecode(await report1.readAsString())['artifactDigest'],
        first.digest);
    expect(jsonDecode(await report2.readAsString())['artifactDigest'],
        second.digest);
    expect(await publisher.evidenceValid(second, a1.reference), isFalse);
    expect(await publisher.evidenceValid(second, a2.reference), isTrue);
    final changedReport = jsonDecode(await report2.readAsString()) as Map;
    changedReport['report'] = 'externally replaced report';
    await report2.writeAsString(jsonEncode(changedReport));
    expect(await publisher.evidenceValid(second, a2.reference), isFalse);
  });

  test('P8 public review fields omit local paths without losing identity',
      () async {
    final candidate = await publish('portable-report');
    final review = await publisher.beginReview(
        candidate: candidate,
        attemptId: 'portable',
        actorId: 'b',
        verificationRevision: 1);
    final report = await publisher.appendReview(review,
        method: 'read /sandbox/private.txt',
        source: 'tool',
        receipt: r'C:\sandbox\receipt.json',
        result: 'failed',
        acceptanceIds: ['qa'],
        report: r'checked \\server\private.txt');
    final raw = await report.readAsString();
    expect(raw, isNot(contains('/sandbox/')));
    expect(raw, isNot(contains('receipt.json')));
    expect(raw, isNot(contains('server')));
    expect(jsonDecode(raw)['artifactDigest'], candidate.digest);
    expect(await publisher.evidenceValid(candidate, review.reference), isTrue);
  });

  test('unchanged candidate cannot allocate a new repair iteration', () async {
    final first = await publish('first');
    await expectLater(publish('second'), throwsStateError);
    expect((await publisher.recover()).single.digest, first.digest);
    await publisher.discardUnpublished('second');
    await working.writeAsString('changed repair');
    expect((await publish('second')).iterationId, 'r002');
  });

  for (final phase in ['beforePublish', 'afterPublish', 'beforeIndex']) {
    test(
        'crash $phase retries same reservation and recovers without duplicate iteration',
        () async {
      var crashed = false;
      final failing =
          WorkCandidatePublisher(publisher.directory, fault: (at) async {
        final hasCandidate =
            await Directory('${publisher.directory.path}/r001').exists();
        if (!crashed &&
            at == phase &&
            (phase != 'beforeIndex' || hasCandidate)) {
          crashed = true;
          throw const FileSystemException('interrupted');
        }
      });
      await expectLater(
          failing.publish(
              publicationId: 'first',
              state: candidateTestState(),
              producerId: 'a',
              sources: {'report.txt': working}),
          throwsA(isA<FileSystemException>()));
      final candidate = await publish('first');
      expect(candidate.iterationId, 'r001');
      expect((await publisher.recover()).length, 1);
      expect((await publisher.recover()).length, 1);
      expect((await publish('first')).digest, candidate.digest);
      expect(await File('${publisher.directory.path}/pending.json').exists(),
          isFalse);
    });
  }

  test('partial copy or disk failure never publishes a complete candidate',
      () async {
    final failing = WorkCandidatePublisher(publisher.directory,
        copy: (source, target) async {
      await target.writeAsString('partial');
      throw const FileSystemException('disk full');
    });
    await expectLater(
        failing.publish(
            publicationId: 'first',
            state: candidateTestState(),
            producerId: 'a',
            sources: {'report.txt': working}),
        throwsA(isA<FileSystemException>()));
    expect((await publisher.recover()), isEmpty);
    expect(
        await Directory('${publisher.directory.path}/r001').exists(), isFalse);
    expect((await publish('first')).iterationId, 'r001');
  });

  test('source changes during copy and missing contract files fail closed',
      () async {
    final failing = WorkCandidatePublisher(publisher.directory,
        copy: (source, target) async {
      await source.copy(target.path);
      await source.writeAsString('changed by external editor');
    });
    await expectLater(
        failing.publish(
            publicationId: 'first',
            state: candidateTestState(),
            producerId: 'a',
            sources: {'report.txt': working}),
        throwsStateError);
    expect(await publisher.recover(), isEmpty);
    await expectLater(
        publisher.publish(
            publicationId: 'first',
            state: candidateTestState(),
            producerId: 'a',
            sources: {'report.txt': File('${root.path}/missing')}),
        throwsStateError);
  });

  test(
      'candidate tampering, extra content and tested workspace mutations invalidate evidence',
      () async {
    final candidate = await publish('first');
    final review = await publisher.beginReview(
        candidate: candidate,
        attemptId: 'test1',
        actorId: 'b',
        verificationRevision: 1,
        testedFiles: {'report.txt': working});
    await working.writeAsString('modified during test');
    final report = await publisher.appendReview(review,
        method: 'run',
        source: 'tool',
        receipt: 'run-1',
        result: 'passed',
        acceptanceIds: ['qa'],
        report: 'exit 0');
    expect(jsonDecode(await report.readAsString())['result'], 'invalidated');
    expect(await publisher.evidenceValid(candidate, review.reference), isFalse);
    await candidate.file('injected.txt').writeAsString('unexpected');
    await expectLater(
        publisher.verify(candidate, expectedDigest: candidate.digest),
        throwsStateError);
    await candidate.file('injected.txt').delete();
    await candidate.file('report.txt').writeAsString('tampered');
    await expectLater(
        publisher.verify(candidate, expectedDigest: candidate.digest),
        throwsStateError);
  });

  test(
      'passed workspace evidence becomes invalid after subsequent external edit',
      () async {
    final candidate = await publish('first');
    final review = await publisher.beginReview(
        candidate: candidate,
        attemptId: 'test1',
        actorId: 'b',
        verificationRevision: 1,
        testedFiles: {'report.txt': working});
    await publisher.appendReview(review,
        method: 'run',
        source: 'tool',
        receipt: 'run-1',
        result: 'passed',
        acceptanceIds: ['qa'],
        report: 'exit 0');
    expect(await publisher.evidenceValid(candidate, review.reference), isTrue);
    await working.writeAsString('external edit');
    expect(await publisher.evidenceValid(candidate, review.reference), isFalse);
  });

  test(
      'reports append by attempt and cannot overwrite a signed report or outcome',
      () async {
    final candidate = await publish('first');
    final review = await publisher.beginReview(
        candidate: candidate,
        attemptId: 'test1',
        actorId: 'b',
        verificationRevision: 1);
    await publisher.appendReview(review,
        method: 'read',
        source: 'tool',
        receipt: 'read-1',
        result: 'passed',
        acceptanceIds: ['qa'],
        report: 'all checked');
    await expectLater(
        publisher.appendReview(review,
            method: 'read',
            source: 'tool',
            receipt: 'read-1',
            result: 'failed',
            acceptanceIds: ['qa'],
            report: 'replacement'),
        throwsStateError);
    final json = candidateTestState().toJson()
      ..['phase'] = 'reviewing'
      ..['iterations'] = [
        {
          'id': candidate.iterationId,
          'artifactDigest': candidate.digest,
          'requestRevision': 1,
          'teamRevision': 1,
          'manifestRef': 'candidate:r001',
          'reviewRef': review.reference,
          'status': 'reviewed'
        }
      ]
      ..['acceptances'] = [
        {
          'id': 'qa',
          'method': 'read',
          'requiredCapability': 'command',
          'status': 'passed',
          'evidenceRef': review.reference,
          'requestRevision': 1,
          'verificationRevision': 1
        }
      ];
    final approvals = [
      ...candidateTestState().approvals,
      for (final member in ['a', 'b'])
        candidateTestApproval(member, 'delivery', 'r001',
            iteration: 'r001', digest: candidate.digest)
    ];
    json['approvals'] = approvals;
    final state = WorkCollaborationState.tryParse(json)!;
    expect(state.deliveryReady, isTrue);
    final outcome =
        await publisher.sealOutcome(candidate, state, accepted: true);
    final bytes = await outcome.readAsBytes();
    await publisher.sealOutcome(candidate, state, accepted: true);
    expect(await outcome.readAsBytes(), bytes);
    await expectLater(publisher.sealOutcome(candidate, state, accepted: false),
        throwsStateError);
  });

  test('missing game assets, credentials, cache and traversal cannot publish',
      () async {
    final html = await File('${root.path}/game.html').writeAsString(
        '<html><body><script src="game.js"></script></body></html>');
    await expectLater(
        publisher.publish(
            publicationId: 'game',
            state: candidateTestState(type: 'software', format: 'html'),
            producerId: 'a',
            sources: {'game.html': html}),
        throwsStateError);
    for (final name in [
      '.env',
      'node_modules/cache.js',
      '../escape',
      'private.key'
    ]) {
      await expectLater(
          publisher.publish(
              publicationId: 'bad',
              state: candidateTestState(),
              producerId: 'a',
              sources: {name: working}),
          throwsStateError);
    }
  });

  test('candidate manifest content mutation fails authoritative digest check',
      () async {
    final candidate = await publish('first');
    final file = File('${candidate.directory.path}/candidate.json');
    final json = jsonDecode(await file.readAsString()) as Map;
    json['producerId'] = 'b';
    await file.writeAsString(jsonEncode(json));
    await expectLater(
        publisher.verify(candidate, expectedDigest: candidate.digest),
        throwsStateError);
  });
}

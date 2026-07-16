import 'dart:io';

import 'package:chat_group/core/database/data_lifecycle_service.dart';
import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/media_attachment.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/lifecycle_hive.dart';

void main() {
  late Directory hiveDirectory;
  late Directory mediaDirectory;
  late DatabaseService db;
  late DataLifecycleService service;

  setUp(() async {
    hiveDirectory = await openLifecycleHive();
    mediaDirectory = Directory('${hiveDirectory.path}/media');
    await mediaDirectory.create();
    db = DatabaseService();
    service = DataLifecycleService(
      db: db,
      managedMediaDirectory: mediaDirectory,
      credentials: testCredentials(MemoryCredentialStore()),
      clearExternalSettings: () async {},
    );
  });

  tearDown(() => closeLifecycleHive(hiveDirectory));

  test(
      'manual cleanup deletes only unreferenced regular files under media root',
      () async {
    final referenced = File('${mediaDirectory.path}/referenced.txt');
    final orphan = File('${mediaDirectory.path}/orphan.txt');
    final external = File('${hiveDirectory.path}/user-original.txt');
    await referenced.writeAsString('keep');
    await orphan.writeAsString('remove');
    await external.writeAsString('outside');
    final link = Link('${mediaDirectory.path}/outside-link.txt');
    await link.create(external.path);
    await db.messageBox.put(
      'm1',
      Message(
        id: 'm1',
        groupId: 'g1',
        senderId: 'user',
        senderType: 'user',
        content: 'files',
        media: [
          MediaAttachment(type: 'file', localPath: referenced.path),
          MediaAttachment(type: 'file', localPath: external.path),
        ],
      ),
    );

    final usage = await service.mediaUsage();
    expect(usage.totalFiles, 2);
    expect(usage.orphanFiles, 1);
    expect(usage.orphanBytes, await orphan.length());

    final result = await service.cleanupOrphanMedia();
    expect(result.isComplete, isTrue);
    expect(result.reclaimedFiles, 1);
    expect(await orphan.exists(), isFalse);
    expect(await referenced.exists(), isTrue);
    expect(await external.exists(), isTrue);
    expect(await link.exists(), isTrue);
  });

  test('single-message deletion reclaims managed copy but not external source',
      () async {
    final managed = File('${mediaDirectory.path}/managed.txt');
    final shared = File('${mediaDirectory.path}/shared.txt');
    final unrelatedOrphan = File('${mediaDirectory.path}/unrelated.txt');
    final external = File('${hiveDirectory.path}/source.txt');
    await managed.writeAsString('copy');
    await shared.writeAsString('shared');
    await unrelatedOrphan.writeAsString('leave for scheduled cleanup');
    await external.writeAsString('source');
    await db.messageBox.put(
      'm1',
      Message(
        id: 'm1',
        groupId: 'g1',
        senderId: 'user',
        senderType: 'user',
        content: 'files',
        media: [
          MediaAttachment(type: 'file', localPath: managed.path),
          MediaAttachment(type: 'file', localPath: shared.path),
          MediaAttachment(type: 'file', localPath: external.path),
        ],
      ),
    );
    await db.messageBox.put(
      'm2',
      Message(
        id: 'm2',
        groupId: 'g2',
        senderId: 'user',
        senderType: 'user',
        content: 'shared file',
        media: [MediaAttachment(type: 'file', localPath: shared.path)],
      ),
    );
    await db.addMessageToGroupIndex(db.messageBox.get('m1')!);

    final result = await service.deleteMessage('m1', groupId: 'g1');

    expect(result.isComplete, isTrue);
    expect(await managed.exists(), isFalse);
    expect(await shared.exists(), isTrue);
    expect(await unrelatedOrphan.exists(), isTrue);
    expect(await external.exists(), isTrue);
    expect(await db.messagesForGroup('g1'), isEmpty);
  });

  test('a symlinked media root is never treated as app-managed storage',
      () async {
    final externalDirectory = Directory('${hiveDirectory.path}/external');
    await externalDirectory.create();
    final external = File('${externalDirectory.path}/user.txt');
    await external.writeAsString('user data');
    final linkedRoot = Link('${hiveDirectory.path}/linked-media');
    await linkedRoot.create(externalDirectory.path);
    final linkedService = DataLifecycleService(
      db: db,
      managedMediaDirectory: Directory(linkedRoot.path),
      credentials: testCredentials(MemoryCredentialStore()),
      clearExternalSettings: () async {},
    );

    expect((await linkedService.mediaUsage()).totalFiles, 0);
    expect((await linkedService.cleanupOrphanMedia()).reclaimedFiles, 0);
    expect(await external.exists(), isTrue);
  });
}

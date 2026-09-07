import 'dart:io';

import 'package:chat_group/core/database/data_lifecycle_service.dart';
import 'package:chat_group/core/database/data_lifecycle_models.dart';
import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/lifecycle_hive.dart';

void main() {
  late Directory hiveDirectory;
  late DatabaseService db;

  setUp(() async {
    hiveDirectory = await openLifecycleHive();
    db = DatabaseService();
  });

  tearDown(() => closeLifecycleHive(hiveDirectory));

  test('global clear quiesces and resumes work mode around app artifacts',
      () async {
    final calls = <String>[];
    final service = DataLifecycleService(
      db: db,
      clearExternalSettings: () async {},
      stopWorkModeTasks: () async => calls.add('stop'),
      clearWorkModeArtifacts: () async => calls.add('clear'),
      resumeWorkModeTasks: () async => calls.add('resume'),
    );

    final result = await service.clear(DataClearScope.chatContent);

    expect(result.isComplete, isTrue);
    expect(calls, ['stop', 'clear', 'resume']);
    expect(service.hasPendingOperation, isFalse);
  });

  test('failed task stop leaves work artifacts for a safe retry', () async {
    final calls = <String>[];
    await db.messageBox.put(
      'keep-until-safe-stop',
      Message(
        id: 'keep-until-safe-stop',
        groupId: 'group-1',
        senderId: 'user',
        senderType: 'user',
        content: 'must remain when work mode is still running',
      ),
    );
    final service = DataLifecycleService(
      db: db,
      clearExternalSettings: () async {},
      stopWorkModeTasks: () async {
        calls.add('stop');
        throw StateError('still running');
      },
      clearWorkModeArtifacts: () async => calls.add('clear'),
      resumeWorkModeTasks: () async => calls.add('resume'),
    );

    final result = await service.clear(DataClearScope.chatContent);

    expect(result.isComplete, isFalse);
    expect(result.incompleteItems, contains('工作任务停止失败'));
    expect(calls, ['stop']);
    expect(db.messageBox.get('keep-until-safe-stop'), isNotNull);
  });
}

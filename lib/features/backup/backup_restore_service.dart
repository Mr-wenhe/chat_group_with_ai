import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';

import 'backup_exporter.dart';
import 'backup_inspector.dart';
import 'backup_models.dart';
import 'restore_executor.dart';

class BackupRestoreService {
  final DatabaseService db;
  final Directory mediaDirectory;
  final Directory tempRoot;
  final CommitWriteHook? onCommitWrite;

  const BackupRestoreService({
    required this.db,
    required this.mediaDirectory,
    required this.tempRoot,
    this.onCommitWrite,
  });

  Future<BackupExportResult> createBackup({
    required File destination,
    BackupSelection selection = const BackupSelection.all(),
    String appVersion = '1.1.0',
  }) =>
      BackupExporter(
        db: db,
        mediaDirectory: mediaDirectory,
        tempRoot: tempRoot,
      ).create(
        destination: destination,
        selection: selection,
        appVersion: appVersion,
      );

  Future<BackupEstimate> estimate(
    BackupSelection selection,
  ) =>
      BackupExporter(
        db: db,
        mediaDirectory: mediaDirectory,
        tempRoot: tempRoot,
      ).estimate(selection);

  Future<PreparedBackup> inspect(File package) => BackupInspector(
        db: db,
        tempRoot: tempRoot,
      ).inspect(package);

  Future<RestoreReport> restore(
    PreparedBackup prepared, {
    required RestoreConflictStrategy strategy,
  }) =>
      RestoreExecutor(
        db: db,
        mediaDirectory: mediaDirectory,
        onCommitWrite: onCommitWrite,
      ).restore(prepared, strategy);
}

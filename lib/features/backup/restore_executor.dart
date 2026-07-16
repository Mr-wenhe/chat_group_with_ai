import 'dart:async';
import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:crypto/crypto.dart';
import 'package:hive/hive.dart';
import 'package:uuid/uuid.dart';

import 'backup_entity_codec.dart';
import 'backup_models.dart';
import 'staged_backup_data.dart';

part 'restore_plan.dart';

typedef CommitWriteHook = FutureOr<void> Function(int writeCount);

class RestoreExecutor {
  final DatabaseService db;
  final Directory mediaDirectory;
  final CommitWriteHook? onCommitWrite;

  const RestoreExecutor({
    required this.db,
    required this.mediaDirectory,
    this.onCommitWrite,
  });

  Future<RestoreReport> restore(
    PreparedBackup prepared,
    RestoreConflictStrategy strategy,
  ) async {
    if (!await prepared.stagingDirectory.exists()) {
      throw const BackupException('导入临时区已失效，请重新选择备份');
    }
    await _verifyStaging(prepared);
    final data = await StagedBackupData.load(
      prepared.stagingDirectory,
      prepared.manifest,
    );
    if (strategy == RestoreConflictStrategy.emptyOnly && !_coreIsEmpty) {
      throw const BackupException('当前数据库不是空库，请选择其他冲突策略');
    }
    final plan = _RestorePlan.build(db, data, strategy);
    plan.validate(db);
    final inserted = <String, int>{};
    final transaction = _RestoreTransaction(onCommitWrite);
    try {
      await mediaDirectory.create(recursive: true);
      if (await FileSystemEntity.type(mediaDirectory.path,
              followLinks: false) !=
          FileSystemEntityType.directory) {
        throw const BackupException('媒体目录不是安全的普通目录');
      }
      final attachmentPaths = await _commitAttachments(
        prepared.stagingDirectory,
        prepared.manifest,
        plan,
        transaction,
      );
      String resolveAttachment(String path) =>
          attachmentPaths[path] ?? (throw BackupException('附件未进入提交计划：$path'));

      await _putRecords(
          db.apiConfigBox,
          plan.apiConfigs,
          BackupEntityCodec.decodeApiConfig,
          'apiConfigs',
          inserted,
          transaction);
      await _putRecords(db.characterSkillBox, plan.skills,
          BackupEntityCodec.decodeSkill, 'skills', inserted, transaction);
      await _putRecords(
          db.aiCharacterBox,
          plan.characters,
          BackupEntityCodec.decodeCharacter,
          'characters',
          inserted,
          transaction);
      await _putRecords(db.chatGroupBox, plan.groups,
          BackupEntityCodec.decodeGroup, 'groups', inserted, transaction);
      await _putRecords(
          db.messageBox,
          plan.messages,
          (json) => BackupEntityCodec.decodeMessage(json, resolveAttachment),
          'messages',
          inserted,
          transaction);
      await _putRecords(
          db.groupMemoryBox,
          plan.groupMemories,
          BackupEntityCodec.decodeGroupMemory,
          'groupMemories',
          inserted,
          transaction);
      await _putRecords(
          db.characterMemoryBox,
          plan.characterMemories,
          BackupEntityCodec.decodeCharacterMemory,
          'characterMemories',
          inserted,
          transaction);
      await _putRecords(
          db.relationshipStateBox,
          plan.relationships,
          BackupEntityCodec.decodeRelationship,
          'relationships',
          inserted,
          transaction);
      await _putRecords(db.agentTaskBox, plan.tasks,
          BackupEntityCodec.decodeTask, 'agentTasks', inserted, transaction);
      await _putRecords(db.workModeWorkspaceBox, plan.workspaces,
          BackupEntityCodec.decodeWorkspace, 'workMode', inserted, transaction);
      for (final entry in plan.settings.entries) {
        await transaction.putSetting(db.appSettingsBox, entry.key, entry.value);
        inserted['settings'] = (inserted['settings'] ?? 0) + 1;
      }
      db.resetLifecycleCaches();
      await db.ensureMessageIndex();
      return RestoreReport(
        inserted: inserted,
        skipped: plan.skipped,
        remapped: plan.remapped,
      );
    } on Object catch (error) {
      final rollbackErrors = await transaction.rollback();
      db.resetLifecycleCaches();
      try {
        await db.ensureMessageIndex();
      } on Object catch (rebuildError) {
        rollbackErrors.add(rebuildError);
      }
      final suffix =
          rollbackErrors.isEmpty ? '' : '；但有 ${rollbackErrors.length} 个回滚步骤失败';
      throw BackupException('恢复失败，已回滚：$error$suffix');
    }
  }

  bool get _coreIsEmpty =>
      db.apiConfigBox.isEmpty &&
      db.aiCharacterBox.isEmpty &&
      db.chatGroupBox.isEmpty &&
      db.messageBox.isEmpty &&
      db.groupMemoryBox.isEmpty &&
      db.characterMemoryBox.isEmpty &&
      db.relationshipStateBox.isEmpty &&
      db.characterSkillBox.isEmpty &&
      db.agentTaskBox.isEmpty &&
      db.workModeWorkspaceBox.isEmpty;

  Future<Map<String, String>> _commitAttachments(
    Directory staging,
    BackupManifest manifest,
    _RestorePlan plan,
    _RestoreTransaction transaction,
  ) async {
    final paths = <String, String>{};
    for (final archivePath in plan.attachmentPaths) {
      final name = archivePath.split('/').last;
      final source = File('${staging.path}/$archivePath');
      final target = File('${mediaDirectory.path}/$name');
      final targetType =
          await FileSystemEntity.type(target.path, followLinks: false);
      if (targetType == FileSystemEntityType.file) {
        final actual = (await sha256.bind(target.openRead()).first).toString();
        if (actual != manifest.files[archivePath]?.sha256) {
          throw BackupException('目标附件内容校验失败：$name');
        }
      } else if (targetType == FileSystemEntityType.notFound) {
        await source.openRead().pipe(target.openWrite());
        transaction.createdFile(target);
      } else {
        throw BackupException('目标附件路径不是普通文件：$name');
      }
      paths[archivePath] = target.path;
    }
    return paths;
  }

  Future<void> _verifyStaging(PreparedBackup prepared) async {
    for (final entry in prepared.manifest.files.entries) {
      final file = File('${prepared.stagingDirectory.path}/${entry.key}');
      if (!await file.exists() || await file.length() != entry.value.bytes) {
        throw BackupException('提交前文件大小校验失败：${entry.key}');
      }
      final digest = (await sha256.bind(file.openRead()).first).toString();
      if (digest != entry.value.sha256) {
        throw BackupException('提交前文件校验和失败：${entry.key}');
      }
    }
  }

  Future<void> _putRecords<T>(
    Box<T> box,
    List<Map<String, dynamic>> records,
    T Function(Map<String, dynamic> json) decode,
    String countKey,
    Map<String, int> inserted,
    _RestoreTransaction transaction,
  ) async {
    for (final record in records) {
      await transaction.put(
        box,
        BackupEntityCodec.key(record),
        decode(BackupEntityCodec.value(record)),
      );
      inserted[countKey] = (inserted[countKey] ?? 0) + 1;
    }
  }
}

class _RestoreTransaction {
  final CommitWriteHook? hook;
  final List<Future<void> Function()> _rollbacks = [];
  int _writes = 0;

  _RestoreTransaction(this.hook);

  Future<void> put<T>(Box<T> box, Object key, T value) async {
    if (box.containsKey(key)) throw BackupException('提交时检测到并发冲突：$key');
    await box.put(key, value);
    _rollbacks.add(() => box.delete(key));
    await _afterWrite();
  }

  Future<void> putSetting(Box<dynamic> box, String key, dynamic value) async {
    final existed = box.containsKey(key);
    final previous = box.get(key);
    await box.put(key, value);
    _rollbacks.add(() => existed ? box.put(key, previous) : box.delete(key));
    await _afterWrite();
  }

  void createdFile(File file) => _rollbacks.add(() async {
        if (await file.exists()) await file.delete();
      });

  Future<void> _afterWrite() async {
    _writes++;
    final result = hook?.call(_writes);
    if (result is Future) await result;
  }

  Future<List<Object>> rollback() async {
    final errors = <Object>[];
    for (final rollback in _rollbacks.reversed) {
      try {
        await rollback();
      } on Object catch (error) {
        errors.add(error);
      }
    }
    return errors;
  }
}

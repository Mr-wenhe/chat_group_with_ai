import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/features/ai_character/character_gender_migrator.dart';
import 'package:chat_group/features/ai_character/character_gender_migration_state.dart';
import 'package:chat_group/features/memory/memory_migrator.dart';
import 'package:chat_group/features/memory/relationship_event_service.dart';
import 'package:crypto/crypto.dart';
import 'package:hive/hive.dart';
import 'package:uuid/uuid.dart';
import 'package:chat_group/features/document/document_understanding_service.dart';
import 'package:chat_group/features/web_search/data/search_settings_store.dart';
import 'package:chat_group/features/ai_governance/ai_governance_store.dart';

import 'backup_entity_codec.dart';
import 'backup_models.dart';
import 'staged_backup_data.dart';

part 'restore_plan.dart';
part 'restore_plan_validation.dart';
part 'restore_plan_rewrite.dart';

typedef CommitWriteHook = FutureOr<void> Function(int writeCount);
typedef AttachmentCopyHook = FutureOr<void> Function(File source, File target);

class RestoreExecutor {
  final DatabaseService db;
  final Directory mediaDirectory;
  final CommitWriteHook? onCommitWrite;
  final AttachmentCopyHook? attachmentCopy;
  final CharacterGenderMigrator? genderMigrator;

  const RestoreExecutor({
    required this.db,
    required this.mediaDirectory,
    this.onCommitWrite,
    this.attachmentCopy,
    this.genderMigrator,
  });

  Future<RestoreReport> restore(
    PreparedBackup prepared,
    RestoreConflictStrategy strategy,
  ) async {
    final stagingType = await FileSystemEntity.type(
      prepared.stagingDirectory.path,
      followLinks: false,
    );
    if (stagingType == FileSystemEntityType.notFound) {
      throw const BackupException('导入临时区已失效，请重新选择备份');
    }
    if (stagingType != FileSystemEntityType.directory) {
      throw const BackupException('导入临时区不是安全目录');
    }
    await _verifyStaging(prepared);
    final data = prepared.validatedData is StagedBackupData
        ? prepared.validatedData! as StagedBackupData
        : await StagedBackupData.load(
            prepared.stagingDirectory,
            prepared.manifest,
          );
    if (strategy == RestoreConflictStrategy.emptyOnly && !_coreIsEmpty) {
      throw const BackupException('当前数据库不是空库，请选择其他冲突策略');
    }
    final importKey = _restoreImportKey(prepared.manifest);
    if (db.appSettingsBox.get(importKey) == true) {
      return const RestoreReport(
        inserted: {},
        skipped: {'duplicateImport': 1},
        remapped: {},
      );
    }
    final plan = _RestorePlan.build(
      db,
      data,
      strategy,
      prepared.manifest,
    );
    plan.validate(db);
    final inserted = <String, int>{};
    var genderMigrationQueued = false;
    final transaction = _RestoreTransaction(onCommitWrite);
    try {
      if (plan.isV1) {
        transaction.snapshotBox(db.userProfileBox);
        transaction.snapshotBox(db.permanentMemoryBox);
        transaction.snapshotBox(db.relationshipStateBox);
        transaction.snapshotBox(db.relationshipEventBox);
        transaction.snapshotBox(db.appSettingsBox);
      }
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
      genderMigrationQueued =
          await _queueLegacyGenderMigration(plan.characters, transaction);
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
        db.userProfileBox,
        plan.userProfiles,
        BackupEntityCodec.decodeUserProfile,
        'userProfiles',
        inserted,
        transaction,
      );
      await _putRecords(
        db.permanentMemoryBox,
        plan.permanentMemories,
        BackupEntityCodec.decodePermanentMemory,
        'permanentMemories',
        inserted,
        transaction,
      );
      await _putRecords(
        db.relationshipEventBox,
        plan.relationshipEvents,
        BackupEntityCodec.decodeRelationshipEvent,
        'relationshipEvents',
        inserted,
        transaction,
      );
      if (plan.restoreGlobalRelationships) {
        await _putRecords(
            db.relationshipStateBox,
            plan.relationships,
            BackupEntityCodec.decodeRelationship,
            'relationships',
            inserted,
            transaction);
      }
      await _putRecords(db.agentTaskBox, plan.tasks,
          BackupEntityCodec.decodeTask, 'agentTasks', inserted, transaction);
      await _putRecords(db.workModeWorkspaceBox, plan.workspaces,
          BackupEntityCodec.decodeWorkspace, 'workMode', inserted, transaction);
      for (final entry in plan.settings.entries) {
        await transaction.putSetting(db.appSettingsBox, entry.key, entry.value);
        inserted['settings'] = (inserted['settings'] ?? 0) + 1;
      }
      if (plan.isConversation && plan.relationshipEvents.isNotEmpty) {
        await RelationshipEventService(db).replayImportedEvents(
          plan.relationshipEvents
              .map((record) => BackupEntityCodec.decodeRelationshipEvent(
                    BackupEntityCodec.value(record),
                  )),
          writeState: (state) async {
            await transaction.replace(
              db.relationshipStateBox,
              state.id,
              state,
            );
          },
        );
      }
      if (plan.isV1) {
        await MemoryMigrator(db).migrate(force: true);
      }
      if (plan.requiresImportMarker) {
        await transaction.putSetting(db.appSettingsBox, importKey, true);
      }
      db.resetLifecycleCaches();
      await db.ensureMessageIndex();
      DocumentUnderstandingService.clearCache();
      if (genderMigrationQueued) {
        await (genderMigrator ?? CharacterGenderMigrator(db)).migrate();
      }
      return RestoreReport(
        inserted: inserted,
        skipped: plan.skipped,
        remapped: plan.remapped,
      );
    } on Object catch (error) {
      final rollbackErrors = await transaction.rollback();
      db.resetLifecycleCaches();
      DocumentUnderstandingService.clearCache();
      try {
        await db.ensureMessageIndex();
      } on Object catch (rebuildError) {
        rollbackErrors.add(rebuildError);
      }
      final suffix =
          rollbackErrors.isEmpty ? '' : '；但有 ${rollbackErrors.length} 个回滚步骤失败';
      throw BackupException(
        '恢复失败，已回滚：${sanitizeBackupError(error)}$suffix',
      );
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
      db.userProfileBox.isEmpty &&
      db.permanentMemoryBox.isEmpty &&
      db.relationshipEventBox.isEmpty &&
      db.characterSkillBox.isEmpty &&
      db.agentTaskBox.isEmpty &&
      db.workModeWorkspaceBox.isEmpty;

  static String _restoreImportKey(BackupManifest manifest) {
    final material = manifest.files.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final fingerprint = [
      manifest.schemaVersion,
      manifest.backupKind.name,
      manifest.conversationId ?? '',
      ...material.map(
          (entry) => '${entry.key}:${entry.value.bytes}:${entry.value.sha256}'),
    ].join('|');
    return 'backup_restore:${manifest.schemaVersion}:${sha256.convert(
      utf8.encode(fingerprint),
    )}';
  }

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
      final sourceType = await FileSystemEntity.type(
        source.path,
        followLinks: false,
      );
      if (sourceType != FileSystemEntityType.file) {
        throw BackupException('暂存附件不是安全的普通文件：$name');
      }
      final target = File('${mediaDirectory.path}/$name');
      final targetType =
          await FileSystemEntity.type(target.path, followLinks: false);
      if (targetType == FileSystemEntityType.file) {
        final actual = (await sha256.bind(target.openRead()).first).toString();
        if (actual != manifest.files[archivePath]?.sha256) {
          throw BackupException('目标附件内容校验失败：$name');
        }
      } else if (targetType == FileSystemEntityType.notFound) {
        // Register the staging target before opening the source. A stream can
        // fail after writing a partial file; rollback must remove that partial
        // artifact even though the final destination has not been renamed yet.
        final temporary = File(
          '${target.path}.restore-${const Uuid().v4()}',
        );
        transaction.createdFile(temporary);
        await (attachmentCopy ?? _copyAttachment)(source, temporary);
        await _verifyFile(
          temporary,
          manifest.files[archivePath] ??
              (throw BackupException('附件缺少校验清单：$name')),
          '暂存附件',
        );
        await temporary.rename(target.path);
        transaction.createdFile(target);
      } else {
        throw BackupException('目标附件路径不是普通文件：$name');
      }
      paths[archivePath] = target.path;
    }
    return paths;
  }

  Future<void> _copyAttachment(File source, File target) =>
      source.openRead().pipe(target.openWrite());

  Future<void> _verifyStaging(PreparedBackup prepared) async {
    for (final entry in prepared.manifest.files.entries) {
      final file = File('${prepared.stagingDirectory.path}/${entry.key}');
      await _verifyFile(file, entry.value, '提交前文件');
    }
  }

  Future<void> _verifyFile(
    File file,
    BackupFileEntry expected,
    String label,
  ) async {
    final type = await FileSystemEntity.type(
      file.path,
      followLinks: false,
    );
    if (type != FileSystemEntityType.file) {
      throw BackupException('$label不是安全的普通文件');
    }
    if (!await file.exists() || await file.length() != expected.bytes) {
      throw BackupException('$label大小校验失败');
    }
    final digest = (await sha256.bind(file.openRead()).first).toString();
    if (digest != expected.sha256) {
      throw BackupException('$label校验和失败');
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

  Future<bool> _queueLegacyGenderMigration(
    List<Map<String, dynamic>> characters,
    _RestoreTransaction transaction,
  ) async {
    final missingGenderIds = characters
        .where(
          (record) => !BackupEntityCodec.hasValidGender(
              BackupEntityCodec.value(record)),
        )
        .map(BackupEntityCodec.key)
        .toSet();
    if (missingGenderIds.isEmpty) return false;

    final existing = db.appSettingsBox.get(CharacterGenderMigrator.stateKey);
    final migrationCompleted =
        db.appSettingsBox.get(CharacterGenderMigrator.migrationKey) == true;
    final current = existing is Map
        ? (migrationCompleted
            ? null
            : CharacterGenderMigrationState.tryFromMap(existing))
        : null;
    final databaseCharacterIds = db.aiCharacterBox.values
        .where((character) => !character.hasKnownGender)
        .map((character) => character.id);
    final rebuildAllCandidates = !migrationCompleted && current == null;
    final completedIds = {...?current?.completedIds}
      ..removeAll(missingGenderIds);
    final decisions = {...?current?.decisions}
      ..removeWhere((id, _) => missingGenderIds.contains(id));
    final state = CharacterGenderMigrationState(
      candidateIds: {
        ...?current?.candidateIds,
        if (rebuildAllCandidates) ...databaseCharacterIds,
        ...missingGenderIds,
      },
      completedIds: completedIds,
      decisions: decisions,
    );
    await transaction.putSetting(
      db.appSettingsBox,
      CharacterGenderMigrator.stateKey,
      state.toMap(),
    );
    await transaction.putSetting(
      db.appSettingsBox,
      CharacterGenderMigrator.migrationKey,
      false,
    );
    return true;
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

  Future<void> replace<T>(Box<T> box, Object key, T value) async {
    final existed = box.containsKey(key);
    final previous = box.get(key);
    await box.put(key, value);
    _rollbacks.add(
      () => existed ? box.put(key, previous as T) : box.delete(key),
    );
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

  void snapshotBox<T>(Box<T> box) {
    final snapshot = Map<dynamic, dynamic>.from(box.toMap());
    _rollbacks.add(() async {
      await box.clear();
      for (final entry in snapshot.entries) {
        await box.put(entry.key, entry.value as T);
      }
    });
  }

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

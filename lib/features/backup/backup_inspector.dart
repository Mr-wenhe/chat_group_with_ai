import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:chat_group/core/database/database_service.dart';
import 'package:crypto/crypto.dart';

import 'backup_entity_codec.dart';
import 'backup_models.dart';
import 'staged_backup_data.dart';

class BackupInspector {
  static const maxPackageBytes = 1024 * 1024 * 1024;
  static const maxEntryBytes = 256 * 1024 * 1024;
  static const maxExpandedBytes = 2 * 1024 * 1024 * 1024;
  static const maxEntries = 20000;
  static const maxExpansionRatio = 200;
  static const _dataPaths = {
    'data/api_configs.json',
    'data/characters.json',
    'data/groups.json',
    'data/messages.jsonl',
    'data/group_memories.json',
    'data/character_memories.json',
    'data/relationships.json',
    'data/skills.json',
    'data/agent_tasks.json',
    'data/work_mode.json',
    'data/settings.json',
    'data/user_profile.json',
    'data/permanent_memories.json',
    'data/relationship_events.json',
  };

  final DatabaseService db;
  final Directory tempRoot;

  const BackupInspector({required this.db, required this.tempRoot});

  Future<PreparedBackup> inspect(File package) async {
    if (!await package.exists()) throw const BackupException('备份文件不存在');
    final packageBytes = await package.length();
    if (packageBytes <= 0 || packageBytes > maxPackageBytes) {
      throw const BackupException('备份文件大小超出限制');
    }
    await tempRoot.create(recursive: true);
    final staging = await tempRoot.createTemp('chat_group_backup_import_');
    InputFileStream? input;
    Archive? archive;
    try {
      input = InputFileStream(package.path);
      archive = ZipDecoder().decodeStream(input);
      _validateEntries(archive, packageBytes);
      await _extract(archive, staging);
      final manifestFile = File('${staging.path}/manifest.json');
      if (!await manifestFile.exists()) {
        throw const BackupException('备份缺少 manifest.json');
      }
      final manifest = BackupManifest.fromJson(
        Map<String, dynamic>.from(
          jsonDecode(await manifestFile.readAsString()) as Map,
        ),
      );
      if (manifest.formatVersion != BackupManifest.currentFormatVersion ||
          !manifest.isSupportedSchema) {
        throw BackupException(
          '不支持的备份版本：format=${manifest.formatVersion}, '
          'schema=${manifest.schemaVersion}',
        );
      }
      _validateManifestShape(manifest);
      await _validateManifestFiles(staging, manifest, archive);
      final data = await StagedBackupData.load(staging, manifest);
      _assertNoSecrets(data);
      final credentials = data.apiConfigs.where((record) {
        return BackupEntityCodec.value(record)['credentialRequired'] == true;
      }).length;
      return PreparedBackup(
        stagingDirectory: staging,
        preview: BackupPreview(
          manifest: manifest,
          packageBytes: packageBytes,
          attachmentCount: manifest.counts['attachments'] ?? 0,
          credentialsToRebind: credentials,
          conflicts: data.conflicts(db),
          checksumsValid: true,
        ),
      );
    } on BackupException {
      await _delete(staging);
      rethrow;
    } on Object catch (error) {
      await _delete(staging);
      throw BackupException('备份校验失败：$error');
    } finally {
      if (archive != null) {
        for (final entry in archive) {
          await entry.close();
        }
      }
      await input?.close();
    }
  }

  void _validateManifestShape(BackupManifest manifest) {
    if (manifest.schemaVersion == 1) return;
    if (manifest.backupKind == BackupKind.conversation &&
        manifest.conversationId == null) {
      throw const BackupException('会话备份缺少 conversationId');
    }
    if (manifest.backupKind == BackupKind.full &&
        manifest.conversationId != null) {
      throw const BackupException('完整备份不应包含 conversationId');
    }
    const globalFiles = {
      'data/permanent_memories.json',
      'data/relationship_events.json',
    };
    final allGlobalFiles = {
      'data/user_profile.json',
      ...globalFiles,
      'data/relationships.json',
    };
    if (manifest.backupKind == BackupKind.conversation) {
      if (manifest.includesGlobalData ||
          manifest.files.containsKey('data/user_profile.json') ||
          manifest.files.containsKey('data/relationships.json') ||
          !manifest.files.keys.toSet().containsAll(globalFiles)) {
        throw const BackupException('会话备份包含非法全局数据');
      }
    } else if (manifest.includesGlobalData) {
      if (!manifest.files.keys.toSet().containsAll(allGlobalFiles)) {
        throw const BackupException('完整备份缺少全局数据文件');
      }
    } else if (manifest.files.keys.any(allGlobalFiles.contains)) {
      throw const BackupException('配置备份不应包含全局数据文件');
    }
  }

  void _validateEntries(Archive archive, int packageBytes) {
    if (archive.isEmpty || archive.length > maxEntries) {
      throw const BackupException('压缩包条目数量超出限制');
    }
    final names = <String>{};
    var expandedBytes = 0;
    for (final entry in archive) {
      final name = entry.name;
      if (entry.isSymbolicLink ||
          name.contains('\\') ||
          name.startsWith('/') ||
          name.split('/').contains('..') ||
          !names.add(name)) {
        throw BackupException('压缩包包含不安全路径：$name');
      }
      final allowed = name == 'manifest.json' ||
          _dataPaths.contains(name) ||
          name == 'data/' ||
          name == 'attachments/' ||
          RegExp(r'^attachments/[0-9a-f]{64}(\.[a-z0-9]+)?$').hasMatch(name);
      if (!allowed) throw BackupException('压缩包包含未知条目：$name');
      if (entry.size > maxEntryBytes) {
        throw BackupException('压缩包单文件过大：$name');
      }
      expandedBytes += entry.size;
    }
    if (expandedBytes > maxExpandedBytes ||
        expandedBytes > packageBytes * maxExpansionRatio) {
      throw const BackupException('压缩包解压体积异常');
    }
  }

  Future<void> _extract(Archive archive, Directory staging) async {
    for (final entry in archive) {
      if (entry.isDirectory) continue;
      final target = File('${staging.path}/${entry.name}');
      await target.parent.create(recursive: true);
      final output = OutputFileStream(target.path);
      entry.writeContent(output);
      await output.close();
    }
  }

  Future<void> _validateManifestFiles(
    Directory staging,
    BackupManifest manifest,
    Archive archive,
  ) async {
    final actualPaths = archive
        .where((entry) => entry.isFile && entry.name != 'manifest.json')
        .map((entry) => entry.name)
        .toSet();
    if (actualPaths.length != manifest.files.length ||
        !actualPaths.containsAll(manifest.files.keys)) {
      throw const BackupException('manifest 文件清单与压缩包不一致');
    }
    for (final entry in manifest.files.entries) {
      final file = File('${staging.path}/${entry.key}');
      if (!await file.exists() || await file.length() != entry.value.bytes) {
        throw BackupException('文件大小校验失败：${entry.key}');
      }
      final digest = (await sha256.bind(file.openRead()).first).toString();
      if (digest != entry.value.sha256) {
        throw BackupException('文件校验和失败：${entry.key}');
      }
      if (entry.key.startsWith('attachments/') &&
          !entry.key.substring('attachments/'.length).startsWith(digest)) {
        throw BackupException('附件内容 ID 不匹配：${entry.key}');
      }
    }
    final attachmentCount = manifest.files.keys
        .where((path) => path.startsWith('attachments/'))
        .length;
    if (manifest.counts['attachments'] != attachmentCount) {
      throw const BackupException('附件计数不一致');
    }
  }

  void _assertNoSecrets(StagedBackupData data) {
    final values = <Object?>[
      data.apiConfigs,
      data.characters,
      data.groups,
      data.messages,
      data.groupMemories,
      data.characterMemories,
      data.relationships,
      data.skills,
      data.tasks,
      data.workspaces,
      data.userProfiles,
      data.permanentMemories,
      data.relationshipEvents,
      data.settings,
    ];
    for (final value in values) {
      _scan(value);
    }
  }

  static const _secretKeys = {
    'apikey',
    'legacyapikey',
    'credentialid',
    'authorization',
    'corpsecret',
    'password',
    'accesstoken',
    'refreshtoken',
    'secret',
  };

  void _scan(Object? value) {
    if (value is Map) {
      for (final entry in value.entries) {
        final key = entry.key.toString().toLowerCase().replaceAll('_', '');
        if (_secretKeys.contains(key)) {
          throw BackupException('备份包含禁止字段：${entry.key}');
        }
        _scan(entry.value);
      }
    } else if (value is Iterable) {
      for (final item in value) {
        _scan(item);
      }
    }
  }

  Future<void> _delete(Directory directory) async {
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

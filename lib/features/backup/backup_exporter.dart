import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/attachment_data_uri.dart';
import 'package:chat_group/core/models/media_attachment.dart';
import 'package:chat_group/core/models/permanent_memory.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import 'backup_entity_codec.dart';
import 'backup_models.dart';

part 'backup_snapshot.dart';

class BackupExporter {
  static const _dataFiles = <String, String>{
    'apiConfigs': 'data/api_configs.json',
    'characters': 'data/characters.json',
    'groups': 'data/groups.json',
    'groupMemories': 'data/group_memories.json',
    'characterMemories': 'data/character_memories.json',
    'relationships': 'data/relationships.json',
    'skills': 'data/skills.json',
    'agentTasks': 'data/agent_tasks.json',
    'workMode': 'data/work_mode.json',
    'settings': 'data/settings.json',
    'userProfile': 'data/user_profile.json',
    'permanentMemories': 'data/permanent_memories.json',
    'relationshipEvents': 'data/relationship_events.json',
  };

  final DatabaseService db;
  final Directory mediaDirectory;
  final Directory tempRoot;

  const BackupExporter({
    required this.db,
    required this.mediaDirectory,
    required this.tempRoot,
  });

  Future<BackupEstimate> estimate(BackupSelection selection) async {
    final snapshot = _Snapshot.capture(db, selection);
    final paths = <String>{};
    var bytes = 0;
    var missing = 0;
    for (final entry in snapshot.messages) {
      for (final attachment in entry.value.media ?? const <MediaAttachment>[]) {
        if (!paths.add(attachment.localPath)) continue;
        if (isAttachmentDataUri(attachment.localPath)) {
          final decoded = decodeAttachmentDataUri(attachment.localPath);
          if (decoded == null) {
            missing++;
          } else {
            bytes += decoded.bytes.lengthInBytes;
          }
          continue;
        }
        final file = File(attachment.localPath);
        if (!await file.exists() || !_isManagedFile(file)) {
          missing++;
        } else {
          bytes += await file.length();
        }
      }
    }
    return BackupEstimate(
      counts: {
        'apiConfigs': snapshot.apiConfigs.length,
        'characters': snapshot.characters.length,
        'groups': snapshot.groups.length,
        'messages': snapshot.messages.length,
        'memories': snapshot.groupMemories.length +
            snapshot.characterMemories.length +
            snapshot.relationships.length +
            snapshot.permanentMemories.length +
            snapshot.relationshipEvents.length,
      },
      attachmentBytes: bytes,
      attachmentCount: paths.length - missing,
      missingAttachments: missing,
    );
  }

  Future<BackupExportResult> create({
    required File destination,
    required BackupSelection selection,
    required String appVersion,
  }) async {
    if (await destination.exists()) {
      throw const BackupException('目标备份文件已存在');
    }
    await destination.parent.create(recursive: true);
    await tempRoot.create(recursive: true);
    final staging = await tempRoot.createTemp('chat_group_backup_export_');
    final partial = File('${destination.path}.partial-${const Uuid().v4()}');
    try {
      final snapshot = _Snapshot.capture(db, selection);
      final files = <String, BackupFileEntry>{};
      final counts = <String, int>{};
      final missing = <String>[];

      await _writeJson(
          staging,
          _dataFiles['apiConfigs']!,
          snapshot.apiConfigs,
          (item) => BackupEntityCodec.apiConfig(item),
          files,
          counts,
          'apiConfigs');
      await _writeJson(
          staging,
          _dataFiles['characters']!,
          snapshot.characters,
          (item) => BackupEntityCodec.characterForBackup(
                item,
                includeMemorySummary:
                    selection.scope != BackupScope.conversation,
              ),
          files,
          counts,
          'characters');
      await _writeJson(staging, _dataFiles['groups']!, snapshot.groups,
          (item) => BackupEntityCodec.group(item), files, counts, 'groups');
      await _writeMessages(staging, snapshot, files, counts, missing);
      await _writeJson(
          staging,
          _dataFiles['groupMemories']!,
          snapshot.groupMemories,
          (item) => BackupEntityCodec.groupMemory(item),
          files,
          counts,
          'groupMemories');
      await _writeJson(
          staging,
          _dataFiles['characterMemories']!,
          snapshot.characterMemories,
          (item) => BackupEntityCodec.characterMemory(item),
          files,
          counts,
          'characterMemories');
      if (selection.scope == BackupScope.all) {
        await _writeJson(
            staging,
            _dataFiles['relationships']!,
            snapshot.relationships,
            (item) => BackupEntityCodec.relationship(item),
            files,
            counts,
            'relationships');
      }
      if (selection.scope != BackupScope.configurationOnly) {
        await _writeJson(
            staging,
            _dataFiles['permanentMemories']!,
            snapshot.permanentMemories,
            (item) => item,
            files,
            counts,
            'permanentMemories');
        await _writeJson(
            staging,
            _dataFiles['relationshipEvents']!,
            snapshot.relationshipEvents,
            (item) => item,
            files,
            counts,
            'relationshipEvents');
      }
      if (selection.scope == BackupScope.all) {
        await _writeJson(
            staging,
            _dataFiles['userProfile']!,
            snapshot.userProfiles,
            (item) => BackupEntityCodec.userProfile(item),
            files,
            counts,
            'userProfiles');
      }
      await _writeJson(staging, _dataFiles['skills']!, snapshot.skills,
          (item) => BackupEntityCodec.skill(item), files, counts, 'skills');
      await _writeJson(staging, _dataFiles['agentTasks']!, snapshot.tasks,
          (item) => BackupEntityCodec.task(item), files, counts, 'agentTasks');
      await _writeJson(
          staging,
          _dataFiles['workMode']!,
          snapshot.workspaces,
          (item) => BackupEntityCodec.workspace(item),
          files,
          counts,
          'workMode');
      await _writeSettings(staging, snapshot.settings, files, counts);

      final manifest = BackupManifest(
        formatVersion: BackupManifest.currentFormatVersion,
        schemaVersion: BackupManifest.currentSchemaVersion,
        appVersion: appVersion,
        createdAt: DateTime.now(),
        scope: selection.scope,
        backupKind: selection.scope == BackupScope.conversation
            ? BackupKind.conversation
            : BackupKind.full,
        includesGlobalData: selection.scope == BackupScope.all,
        conversationId: selection.conversationId,
        counts: counts,
        files: files,
        missingAttachments: missing,
        compatibilityData: selection.scope == BackupScope.conversation &&
                snapshot.characterMemories.isNotEmpty
            ? const ['data/character_memories.json']
            : const [],
      );
      final manifestFile = File('${staging.path}/manifest.json');
      await manifestFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(manifest.toJson()),
        flush: true,
      );
      await _validateStaging(staging, files);
      await ZipFileEncoder().zipDirectory(
        staging,
        filename: partial.path,
        followLinks: false,
      );
      await partial.rename(destination.path);
      return BackupExportResult(file: destination, manifest: manifest);
    } on BackupException {
      rethrow;
    } on Object catch (error) {
      throw BackupException('创建备份失败：$error');
    } finally {
      if (await staging.exists()) await staging.delete(recursive: true);
      if (await partial.exists()) await partial.delete();
    }
  }

  Future<void> _validateStaging(
    Directory staging,
    Map<String, BackupFileEntry> files,
  ) async {
    final actualPaths = <String>{};
    await for (final entity in staging.list(recursive: true)) {
      if (entity is File) {
        actualPaths
            .add(entity.path.substring(staging.path.length + 1).replaceAll(
                  Platform.pathSeparator,
                  '/',
                ));
      }
    }
    actualPaths.remove('manifest.json');
    if (actualPaths.length != files.length ||
        !actualPaths.containsAll(files.keys)) {
      throw const BackupException('备份 staging 文件清单不一致');
    }
    for (final entry in files.entries) {
      final file = File('${staging.path}/${entry.key}');
      if (!await file.exists() || await file.length() != entry.value.bytes) {
        throw BackupException('备份 staging 文件无效：${entry.key}');
      }
      if (entry.key.endsWith('.json')) {
        try {
          jsonDecode(await file.readAsString());
        } on Object catch (error) {
          throw BackupException('备份 JSON 无法解析：${entry.key}：$error');
        }
      } else if (entry.key.endsWith('.jsonl')) {
        await for (final line in file
            .openRead()
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
          if (line.trim().isNotEmpty) jsonDecode(line);
        }
      }
    }
  }

  Future<void> _writeMessages(
    Directory staging,
    _Snapshot snapshot,
    Map<String, BackupFileEntry> files,
    Map<String, int> counts,
    List<String> missing,
  ) async {
    const relativePath = 'data/messages.jsonl';
    final file = await _createFile(staging, relativePath);
    final sink = file.openWrite();
    final attachmentsByHash = <String, String>{};
    final missingAttachmentIds = <String>{};
    try {
      for (final entry in snapshot.messages) {
        final media = <Map<String, dynamic>>[];
        for (final attachment
            in entry.value.media ?? const <MediaAttachment>[]) {
          final archivePath = await _stageAttachment(
            staging,
            attachment,
            attachmentsByHash,
            files,
          );
          if (archivePath == null) {
            if (missingAttachmentIds.add(attachment.id)) {
              missing
                  .add(attachment.fileName ?? _basename(attachment.localPath));
            }
            continue;
          }
          media.add(BackupEntityCodec.attachment(attachment, archivePath));
        }
        final record = BackupEntityCodec.record(
          entry.key,
          BackupEntityCodec.message(entry.value, media),
        );
        _assertNoSecrets(record);
        sink.writeln(jsonEncode(record));
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
    if (snapshot.messages.isEmpty) await file.writeAsString('\n', flush: true);
    files[relativePath] = await _fileEntry(file);
    counts['messages'] = snapshot.messages.length;
    counts['attachments'] = attachmentsByHash.length;
    counts['missingAttachments'] = missing.length;
  }

  Future<String?> _stageAttachment(
    Directory staging,
    MediaAttachment attachment,
    Map<String, String> attachmentsByHash,
    Map<String, BackupFileEntry> files,
  ) async {
    final source = File(attachment.localPath);
    if (!isAttachmentDataUri(attachment.localPath) &&
        (!await source.exists() || !_isManagedFile(source))) {
      return null;
    }
    final bytes = isAttachmentDataUri(attachment.localPath)
        ? decodeAttachmentDataUri(attachment.localPath)?.bytes
        : null;
    final digest = bytes == null
        ? await sha256.bind(source.openRead()).first
        : sha256.convert(bytes);
    final existing = attachmentsByHash[digest.toString()];
    if (existing != null) return existing;
    final extension = _safeExtension(attachment.fileName ?? source.path);
    final relativePath = 'attachments/${digest.toString()}$extension';
    final target = await _createFile(staging, relativePath);
    if (bytes != null) {
      await target.writeAsBytes(bytes, flush: true);
    } else {
      await source.openRead().pipe(target.openWrite());
    }
    files[relativePath] = await _fileEntry(target);
    attachmentsByHash[digest.toString()] = relativePath;
    return relativePath;
  }

  bool _isManagedFile(File file) {
    final root = '${mediaDirectory.absolute.path}${Platform.pathSeparator}';
    return file.absolute.path.startsWith(root) &&
        file.statSync().type == FileSystemEntityType.file;
  }

  Future<void> _writeJson<T>(
    Directory staging,
    String relativePath,
    List<MapEntry<Object, T>> entries,
    Map<String, dynamic> Function(T value) encode,
    Map<String, BackupFileEntry> files,
    Map<String, int> counts,
    String countKey,
  ) async {
    final records = entries
        .map(
            (entry) => BackupEntityCodec.record(entry.key, encode(entry.value)))
        .toList(growable: false);
    _assertNoSecrets(records);
    final file = await _createFile(staging, relativePath);
    await file.writeAsString(jsonEncode(records), flush: true);
    files[relativePath] = await _fileEntry(file);
    counts[countKey] = records.length;
  }

  Future<void> _writeSettings(
    Directory staging,
    Map<String, dynamic> settings,
    Map<String, BackupFileEntry> files,
    Map<String, int> counts,
  ) async {
    _assertNoSecrets(settings);
    final path = _dataFiles['settings']!;
    final file = await _createFile(staging, path);
    await file.writeAsString(jsonEncode(settings), flush: true);
    files[path] = await _fileEntry(file);
    counts['settings'] = settings.length;
  }

  Future<File> _createFile(Directory root, String relativePath) async {
    final file = File('${root.path}/$relativePath');
    await file.parent.create(recursive: true);
    return file;
  }

  Future<BackupFileEntry> _fileEntry(File file) async => BackupFileEntry(
        bytes: await file.length(),
        sha256: (await sha256.bind(file.openRead()).first).toString(),
      );

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

  void _assertNoSecrets(Object? value) {
    if (value is Map) {
      for (final entry in value.entries) {
        final normalized =
            entry.key.toString().toLowerCase().replaceAll('_', '');
        if (_secretKeys.contains(normalized)) {
          throw BackupException('备份数据包含禁止字段：${entry.key}');
        }
        _assertNoSecrets(entry.value);
      }
    } else if (value is Iterable) {
      for (final item in value) {
        _assertNoSecrets(item);
      }
    }
  }

  String _safeExtension(String name) {
    final base = _basename(name);
    final dot = base.lastIndexOf('.');
    if (dot <= 0 || base.length - dot > 12) return '';
    final extension = base.substring(dot).toLowerCase();
    return RegExp(r'^\.[a-z0-9]+$').hasMatch(extension) ? extension : '';
  }

  String _basename(String path) => path.replaceAll('\\', '/').split('/').last;
}

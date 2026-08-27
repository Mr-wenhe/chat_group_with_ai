import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:chat_group/core/database/database_service.dart';
import 'package:crypto/crypto.dart';

import 'backup_entity_codec.dart';
import 'backup_models.dart';
import 'backup_zip_preflight.dart';
import 'staged_backup_data.dart';
import 'package:chat_group/features/web_search/security/search_secret_scanner.dart';
import 'package:chat_group/features/web_search/data/search_settings_store.dart';

class BackupInspector {
  static const maxPackageBytes = 1024 * 1024 * 1024;
  static const maxEntryBytes = 256 * 1024 * 1024;

  /// The manifest is parsed before any data files. Keep its independent cap
  /// small enough that metadata cannot become a pre-decode memory bomb.
  static const maxManifestBytes = 4 * 1024 * 1024;
  static const maxManifestEntries = 20000;
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
  final int _entryByteLimit;
  final int _expandedByteLimit;

  const BackupInspector({
    required this.db,
    required this.tempRoot,
    int entryByteLimit = maxEntryBytes,
    int expandedByteLimit = maxExpandedBytes,
  })  : _entryByteLimit = entryByteLimit,
        _expandedByteLimit = expandedByteLimit,
        assert(entryByteLimit > 0 && entryByteLimit <= maxEntryBytes),
        assert(expandedByteLimit > 0 && expandedByteLimit <= maxExpandedBytes);

  Future<PreparedBackup> inspect(File package) async {
    if (!await package.exists()) throw const BackupException('备份文件不存在');
    final packageBytes = await package.length();
    if (packageBytes <= 0 || packageBytes > maxPackageBytes) {
      throw const BackupException('备份文件大小超出限制');
    }
    await ZipPreflight.validate(package, maxEntries: maxEntries);
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
      final manifest =
          BackupManifest.fromJson(await _readManifest(manifestFile));
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
      var credentials = data.apiConfigs.where((record) {
        return BackupEntityCodec.value(record)['credentialRequired'] == true;
      }).length;
      final searchConfigs = data.settings[SearchProviderConfigStore.configsKey];
      if (searchConfigs is List) {
        credentials += searchConfigs.whereType<Map>().where((record) {
          return record['credentialRequired'] == true;
        }).length;
      }
      return PreparedBackup(
        stagingDirectory: staging,
        validatedData: data,
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

  Future<Map<String, dynamic>> _readManifest(File manifestFile) async {
    final bytes = await manifestFile.length();
    if (bytes > maxManifestBytes) {
      throw const BackupException('manifest.json 文件过大');
    }
    final decoded = StagedBackupData.decodeBoundedJsonText(
      await manifestFile.readAsString(),
      'manifest.json',
      maxBytes: maxManifestBytes,
      maxArrayItems: maxManifestEntries,
      maxMapEntries: maxManifestEntries,
      textAlreadyByteBounded: true,
    );
    if (decoded is! Map) {
      throw const BackupException('manifest.json 格式无效');
    }
    return Map<String, dynamic>.from(decoded);
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
      if (entry.size > _entryByteLimit) {
        throw BackupException('压缩包单文件过大：$name');
      }
      expandedBytes += entry.size;
    }
    if (expandedBytes > _expandedByteLimit ||
        expandedBytes > packageBytes * maxExpansionRatio) {
      throw const BackupException('压缩包解压体积异常');
    }
  }

  Future<void> _extract(Archive archive, Directory staging) async {
    final budget = _BackupOutputBudget();
    for (final entry in archive) {
      if (entry.isDirectory) continue;
      final target = File('${staging.path}/${entry.name}');
      await target.parent.create(recursive: true);
      final output = OutputFileStream(target.path);
      final boundedOutput = _LimitedBackupOutputStream(
        output,
        entryName: entry.name,
        budget: budget,
        entryByteLimit: _entryByteLimit,
        expandedByteLimit: _expandedByteLimit,
      );
      try {
        // ArchiveFile.writeContent() materializes a compressed entry before
        // writing it.  Decompress directly into the file instead, keeping the
        // peak memory close to the decoder buffer even for 256 MB entries.
        if (entry.rawContent != null) {
          entry.decompress(boundedOutput);
        } else {
          entry.writeContent(boundedOutput);
        }
      } finally {
        await output.close();
        // Release any content materialized by a stored/special entry before
        // moving on to the next archive member.
        entry.clear();
      }
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
    'cookie',
    'setcookie',
    'pem',
    'privatekey',
    'jwt',
  };

  void _scan(Object? value) {
    if (value is Map) {
      for (final entry in value.entries) {
        final key = entry.key
            .toString()
            .toLowerCase()
            .replaceAll(RegExp(r'[^a-z0-9]'), '');
        if (_secretKeys.contains(key)) {
          throw BackupException('备份包含禁止字段：${entry.key}');
        }
        _scan(entry.value);
      }
    } else if (value is Iterable) {
      for (final item in value) {
        _scan(item);
      }
    } else if (value is String &&
        const SearchSecretScanner().containsSensitiveData(value)) {
      throw const BackupException('备份内容包含敏感信息');
    }
  }

  Future<void> _delete(Directory directory) async {
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

class _BackupOutputBudget {
  int expandedBytes = 0;
}

/// Counts decompressed bytes while preserving the archive package's streaming
/// output path. ZIP headers are untrusted metadata, so the actual bytes written
/// must be bounded independently of [ArchiveFile.size].
class _LimitedBackupOutputStream extends OutputStream {
  final OutputStream _delegate;
  final String entryName;
  final _BackupOutputBudget budget;
  final int entryByteLimit;
  final int expandedByteLimit;
  int _length = 0;

  _LimitedBackupOutputStream(
    this._delegate, {
    required this.entryName,
    required this.budget,
    required this.entryByteLimit,
    required this.expandedByteLimit,
  }) : super(byteOrder: _delegate.byteOrder);

  @override
  int get length => _length;

  @override
  bool get isOpen => _delegate.isOpen;

  @override
  void open() => _delegate.open();

  @override
  Future<void> close() => _delegate.close();

  @override
  void closeSync() => _delegate.closeSync();

  @override
  void clear() => _delegate.clear();

  @override
  void flush() => _delegate.flush();

  @override
  void writeByte(int value) {
    _checkLimit(1);
    _delegate.writeByte(value);
    _record(1);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final count = length ?? bytes.length;
    if (count < 0 || count > bytes.length) {
      throw BackupException('压缩包条目写入长度无效：$entryName');
    }
    _checkLimit(count);
    _delegate.writeBytes(bytes, length: count);
    _record(count);
  }

  @override
  void writeStream(InputStream stream) {
    var remaining = stream.length;
    const chunkSize = 1024 * 1024;
    while (remaining > 0) {
      final requested = remaining > chunkSize ? chunkSize : remaining;
      final bytes = stream.readBytes(requested).toUint8List();
      if (bytes.isEmpty) {
        throw BackupException('压缩包条目内容读取失败：$entryName');
      }
      writeBytes(bytes);
      remaining -= bytes.length;
    }
  }

  @override
  Uint8List subset(int start, [int? end]) => _delegate.subset(start, end);

  @override
  Uint8List getBytes() => _delegate.getBytes();

  void _checkLimit(int count) {
    final nextEntryBytes = _length + count;
    final nextExpandedBytes = budget.expandedBytes + count;
    if (nextEntryBytes > entryByteLimit) {
      throw BackupException('压缩包条目解压后超过单文件限制：$entryName');
    }
    if (nextExpandedBytes > expandedByteLimit) {
      throw const BackupException('压缩包实际解压体积超过限制');
    }
  }

  void _record(int count) {
    _length += count;
    budget.expandedBytes += count;
  }
}

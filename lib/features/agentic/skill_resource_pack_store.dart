import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/character_skill.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'skill_resource_pack.dart';

class SkillResourceRead {
  final String path;
  final String encoding;
  final String content;
  final int bytes;
  final String sha256;

  const SkillResourceRead({
    required this.path,
    required this.encoding,
    required this.content,
    required this.bytes,
    required this.sha256,
  });

  Map<String, dynamic> toJson() => {
        'path': path,
        'encoding': encoding,
        'content': content,
        'bytes': bytes,
        'sha256': sha256,
      };
}

class SkillResourcePackStore {
  static const int maxUsageEntries = 256;

  final Directory root;
  Future<void> _writeQueue = Future<void>.value();

  SkillResourcePackStore({required this.root});

  static String draftFingerprint(CharacterSkill skill) => sha256
      .convert(utf8.encode(jsonEncode({
        'characterId': skill.characterId,
        'name': skill.name,
        'domain': skill.domain,
        'description': skill.description,
        'instructions': skill.instructions,
        'requiredPermissions': skill.requiredPermissions
            .map((permission) => permission.name)
            .toList()
          ..sort(),
      })))
      .toString();

  Future<bool> recordDraftSuccessfulUse({
    required DatabaseService database,
    required CharacterSkill skill,
    required String fingerprint,
    required String taskId,
    required String conversationId,
    required String characterId,
  }) =>
      _serialize<bool>(() async {
        if (skill.resourcePackId != null ||
            skill.isGlobal ||
            skill.characterId != characterId ||
            draftFingerprint(skill) != fingerprint) {
          return false;
        }
        final direct = conversationId.startsWith('dm:');
        if (direct
            ? conversationId.substring(3) != characterId
            : !database.chatGroupBox.containsKey(conversationId)) {
          return false;
        }
        await _ensureRoot();
        final file = File(p.join(root.path, 'draft-usage.json'));
        final type = await FileSystemEntity.type(file.path, followLinks: false);
        if (type == FileSystemEntityType.link ||
            (type != FileSystemEntityType.notFound &&
                type != FileSystemEntityType.file)) {
          throw const FileSystemException('本地技能验证证据不是普通文件');
        }
        final usage = type == FileSystemEntityType.notFound
            ? <String, dynamic>{'schemaVersion': 1, 'trials': <dynamic>[]}
            : await _readDraftUsage(file);
        final trials = usage['trials'] as List;
        final duplicate = trials.any((raw) =>
            raw is Map &&
            raw['skillId'] == skill.id &&
            raw['fingerprint'] == fingerprint &&
            raw['taskId'] == taskId);
        if (!duplicate) {
          if (trials.length >= maxUsageEntries) {
            throw StateError('本地技能验证证据容量已满，未激活技能。');
          }
          trials.add({
            'skillId': skill.id,
            'characterId': characterId,
            'fingerprint': fingerprint,
            'taskId': taskId,
            'kind': direct ? 'dm' : 'group',
          });
          await _atomicWrite(
            file,
            const JsonEncoder.withIndent('  ').convert(usage),
          );
        }
        return trials.any((raw) =>
                raw is Map &&
                raw['skillId'] == skill.id &&
                raw['characterId'] == characterId &&
                raw['fingerprint'] == fingerprint &&
                raw['kind'] == 'group') &&
            trials.any((raw) =>
                raw is Map &&
                raw['skillId'] == skill.id &&
                raw['characterId'] == characterId &&
                raw['fingerprint'] == fingerprint &&
                raw['kind'] == 'dm');
      });

  Future<Map<String, dynamic>> _readDraftUsage(File file) async {
    if (await file.length() > 1024 * 1024) {
      throw const FormatException('本地技能验证证据超出限制。');
    }
    final value = jsonDecode(await file.readAsString());
    if (value is! Map ||
        value.length != 2 ||
        value['schemaVersion'] != 1 ||
        value['trials'] is! List ||
        (value['trials'] as List).length > maxUsageEntries ||
        (value['trials'] as List).any((raw) =>
            raw is! Map ||
            raw.length != 5 ||
            raw['skillId'] is! String ||
            raw['characterId'] is! String ||
            raw['fingerprint'] is! String ||
            raw['taskId'] is! String ||
            !{'group', 'dm'}.contains(raw['kind']))) {
      throw const FormatException('本地技能验证证据损坏。');
    }
    return Map<String, dynamic>.from(value);
  }

  factory SkillResourcePackStore.forDatabase(DatabaseService database) {
    final dataPath = database.dataDirPath;
    if (dataPath == null || dataPath.trim().isEmpty) {
      throw StateError('应用数据目录尚未就绪。');
    }
    return SkillResourcePackStore(
      root: Directory(p.join(dataPath, 'skill_resource_packs')),
    );
  }

  Future<bool> save(SkillResourcePack pack) => _serialize<bool>(() async {
        await _ensureRoot();
        final target = _packDirectory(pack.id);
        final targetType = await FileSystemEntity.type(
          target.path,
          followLinks: false,
        );
        if (targetType == FileSystemEntityType.link) {
          throw const FileSystemException('技能包目录不能是符号链接');
        }
        if (targetType == FileSystemEntityType.directory) {
          await _verifyPackFiles(pack.id);
          return false;
        }
        if (targetType != FileSystemEntityType.notFound) {
          throw const FileSystemException('技能包目标不是目录');
        }
        final staging = Directory(
          p.join(root.path, '.pending-${const Uuid().v4()}'),
        );
        await staging.create();
        try {
          for (final file in pack.files) {
            if (!_safePackPath(file.path) ||
                const {'pack.json', 'usage.json'}
                    .contains(file.path.toLowerCase())) {
              throw const FileSystemException('技能包文件路径无效');
            }
            final output =
                File(p.joinAll([staging.path, ...file.path.split('/')]));
            await output.parent.create(recursive: true);
            await output.writeAsBytes(file.bytes, flush: true);
          }
          await File(p.join(staging.path, 'pack.json')).writeAsString(
            const JsonEncoder.withIndent('  ').convert(pack.toLocalManifest()),
            flush: true,
          );
          await staging.rename(target.path);
          return true;
        } on Object {
          if (await staging.exists()) await staging.delete(recursive: true);
          rethrow;
        }
      });

  Future<SkillResourceRead> readResource({
    required String packId,
    required String path,
    required String taskId,
    required String conversationId,
    required String characterId,
  }) async {
    if (!_validPackId(packId) || !_safePackPath(path)) {
      throw const FormatException('技能资源引用无效。');
    }
    final manifest = await _readManifest(packId);
    final entry = _manifestFile(manifest, path);
    final file = await _regularPackFile(packId, path);
    final bytes = await file.readAsBytes();
    if (bytes.length != entry['bytes'] ||
        sha256.convert(bytes).toString() != entry['sha256']) {
      throw const FileSystemException('技能资源摘要不匹配');
    }
    final isText = SkillResourcePack.textFileExtensions
        .contains(p.extension(path).toLowerCase());
    final content = isText
        ? utf8.decode(bytes, allowMalformed: false)
        : base64Encode(bytes);
    await _recordRead(packId, taskId, conversationId, characterId, path);
    return SkillResourceRead(
      path: path,
      encoding: isText ? 'utf8' : 'base64',
      content: content,
      bytes: bytes.length,
      sha256: entry['sha256'] as String,
    );
  }

  Future<bool> recordScriptExecution({
    required String taskId,
    required String characterId,
    required int? exitCode,
    required String executable,
    required List<String> arguments,
    required String workingDirectory,
    required String workspaceRoot,
  }) =>
      _serialize<bool>(() async {
        if (exitCode != 0) return false;
        const scriptExtensions = {'.sh', '.py', '.js', '.ts', '.dart'};
        final executableName =
            p.basenameWithoutExtension(executable).toLowerCase();
        final executableExtension = p.extension(executable).toLowerCase();
        const interpreters = {
          'sh',
          'bash',
          'zsh',
          'python',
          'python2',
          'python3',
          'node',
          'deno',
          'tsx',
          'ts-node',
          'dart',
        };
        final scriptArgument = scriptExtensions.contains(executableExtension)
            ? executable
            : interpreters.contains(executableName) &&
                    arguments.isNotEmpty &&
                    !arguments.first.startsWith('-')
                ? arguments.first
                : null;
        if (scriptArgument == null ||
            !scriptExtensions
                .contains(p.extension(scriptArgument).toLowerCase())) {
          return false;
        }
        await _ensureRoot();
        var recorded = false;
        await for (final entity in root.list(followLinks: false)) {
          if (entity is! Directory || !_validPackId(p.basename(entity.path))) {
            continue;
          }
          final type =
              await FileSystemEntity.type(entity.path, followLinks: false);
          if (type != FileSystemEntityType.directory) continue;
          final manifest = await _readManifest(p.basename(entity.path));
          final usage = await _readUsage(entity);
          final hasPriorRead = (usage['reads'] as List).any((raw) =>
              raw is Map &&
              raw['taskId'] == taskId &&
              raw['characterId'] == characterId &&
              raw['path'] == 'SKILL.md');
          if (!hasPriorRead) continue;
          final files = manifest['files'] as List;
          for (final raw in files) {
            if (raw is! Map || raw['path'] is! String) continue;
            final path = raw['path'] as String;
            if (path != scriptArgument &&
                p.basename(path) != p.basename(scriptArgument)) {
              continue;
            }
            final candidate = p.isAbsolute(scriptArgument)
                ? p.normalize(scriptArgument)
                : p.normalize(p.join(workingDirectory, scriptArgument));
            final absoluteRoot = p.normalize(p.absolute(workspaceRoot));
            if (!p.isWithin(absoluteRoot, p.normalize(p.absolute(candidate))) ||
                await FileSystemEntity.type(candidate, followLinks: false) !=
                    FileSystemEntityType.file) {
              continue;
            }
            final resolvedRoot = p.normalize(
              p.absolute(await Directory(absoluteRoot).resolveSymbolicLinks()),
            );
            final resolved = await File(candidate).resolveSymbolicLinks();
            if (!p.isWithin(resolvedRoot, p.normalize(p.absolute(resolved)))) {
              continue;
            }
            final actual = await File(resolved).readAsBytes();
            if (actual.length != raw['bytes'] ||
                sha256.convert(actual).toString() != raw['sha256']) {
              continue;
            }
            final runs = usage['scriptRuns'] as List;
            if (!runs.any((entry) =>
                entry is Map &&
                entry['taskId'] == taskId &&
                entry['characterId'] == characterId &&
                entry['path'] == path)) {
              if (runs.length >= maxUsageEntries) {
                throw StateError('技能使用证据容量已满，未验证该技能。');
              }
              runs.add({
                'taskId': taskId,
                'characterId': characterId,
                'path': path,
                'at': DateTime.now().toUtc().toIso8601String(),
              });
              await _writeUsage(entity, usage);
            }
            recorded = true;
            break;
          }
        }
        return recorded;
      });

  Future<List<String>> recordSuccessfulUse({
    required DatabaseService database,
    required String taskId,
    required String conversationId,
    required String characterId,
  }) =>
      _serialize<List<String>>(() async {
        final isDirect = conversationId.startsWith('dm:');
        if (isDirect
            ? conversationId.substring(3) != characterId
            : !database.chatGroupBox.containsKey(conversationId)) {
          return const <String>[];
        }
        await _ensureRoot();
        final activated = <String>[];
        await for (final entity in root.list(followLinks: false)) {
          if (entity is! Directory || !_validPackId(p.basename(entity.path))) {
            continue;
          }
          final type =
              await FileSystemEntity.type(entity.path, followLinks: false);
          if (type != FileSystemEntityType.directory) continue;
          final packId = p.basename(entity.path);
          final manifest = await _readManifest(packId);
          final usage = await _readUsage(entity);
          final readSkill = (usage['reads'] as List).any((raw) =>
              raw is Map &&
              raw['taskId'] == taskId &&
              raw['characterId'] == characterId &&
              raw['path'] == 'SKILL.md');
          final ranScript = (usage['scriptRuns'] as List).any((raw) =>
              raw is Map &&
              raw['taskId'] == taskId &&
              raw['characterId'] == characterId);
          final hasScript = (manifest['files'] as List).any((raw) =>
              raw is Map &&
              (raw['path'] as String).startsWith('scripts/') &&
              const {
                '.sh',
                '.py',
                '.js',
                '.mjs',
                '.cjs',
                '.ts',
                '.dart',
                '.rb',
                '.php',
                '.pl',
                '.ps1',
                '.bat',
              }.contains(p.extension(raw['path'] as String).toLowerCase()));
          if (!readSkill || hasScript && !ranScript) {
            continue;
          }
          final trials = usage['trials'] as List;
          if (!trials.any((raw) => raw is Map && raw['taskId'] == taskId)) {
            if (trials.length >= maxUsageEntries) {
              throw StateError('技能使用证据容量已满，未验证该技能。');
            }
            trials.add({
              'taskId': taskId,
              'conversationId': conversationId,
              'characterId': characterId,
              'status': 'passed',
              'at': DateTime.now().toUtc().toIso8601String(),
            });
            await _writeUsage(entity, usage);
          }
          final hasGroup = trials.any((raw) =>
              raw is Map &&
              raw['characterId'] == characterId &&
              raw['status'] == 'passed' &&
              raw['conversationId'] is String &&
              !(raw['conversationId'] as String).startsWith('dm:'));
          final hasDirectChat = trials.any((raw) =>
              raw is Map &&
              raw['characterId'] == characterId &&
              raw['status'] == 'passed' &&
              raw['conversationId'] is String &&
              (raw['conversationId'] as String).startsWith('dm:'));
          if (manifest['licenseStatus'] != 'recognized' ||
              !hasGroup ||
              !hasDirectChat) {
            continue;
          }
          manifest['validationStatus'] = 'verified';
          manifest['verified'] = true;
          await _writeManifest(entity, manifest);
          final matchingSkills = database.characterSkillBox.values
              .where((item) =>
                  item.resourcePackId == packId &&
                  item.characterId == characterId)
              .toList();
          final skill = matchingSkills.isEmpty ? null : matchingSkills.first;
          final character = database.aiCharacterBox.get(characterId);
          if (skill != null &&
              character != null &&
              !character.skillIds.contains(skill.id)) {
            character.skillIds = [...character.skillIds, skill.id];
            await database.aiCharacterBox.put(character.id, character);
          }
          if (skill != null) activated.add(skill.id);
        }
        return activated;
      });

  Future<({List<Map<String, dynamic>> records, List<String> missing})>
      backupRecords(Iterable<String> packIds) async {
    final records = <Map<String, dynamic>>[];
    final missing = <String>[];
    for (final packId in packIds.toSet()) {
      try {
        final value = await _backupValue(packId);
        records.add({'key': packId, 'value': value});
      } on Object {
        missing.add('skill-resource-pack:$packId');
      }
    }
    return (records: records, missing: missing);
  }

  Future<bool> restoreBackupValue(Object? value) async {
    final pack = SkillResourcePack.fromBackupValue(value);
    return save(pack);
  }

  Future<void> deletePack(String packId) async {
    if (!_validPackId(packId)) return;
    final directory = _packDirectory(packId);
    if (await FileSystemEntity.type(directory.path, followLinks: false) ==
        FileSystemEntityType.directory) {
      await directory.delete(recursive: true);
    }
  }

  Future<void> pruneUnreferenced(DatabaseService database) async {
    if (await FileSystemEntity.type(root.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return;
    }
    final referenced = database.characterSkillBox.values
        .map((skill) => skill.resourcePackId)
        .whereType<String>()
        .toSet();
    await for (final entity in root.list(followLinks: false)) {
      final packId = p.basename(entity.path);
      if (entity is Directory &&
          _validPackId(packId) &&
          !referenced.contains(packId)) {
        await entity.delete(recursive: true);
      }
    }
  }

  Future<void> _recordRead(
    String packId,
    String taskId,
    String conversationId,
    String characterId,
    String path,
  ) =>
      _serialize(() async {
        final directory = _packDirectory(packId);
        final usage = await _readUsage(directory);
        final reads = usage['reads'] as List;
        if (reads.any((raw) =>
            raw is Map &&
            raw['taskId'] == taskId &&
            raw['characterId'] == characterId &&
            raw['path'] == path)) {
          return;
        }
        if (reads.length >= maxUsageEntries) {
          throw StateError('技能使用证据容量已满，未记录本次资源读取。');
        }
        reads.add({
          'taskId': taskId,
          'conversationId': conversationId,
          'characterId': characterId,
          'path': path,
          'at': DateTime.now().toUtc().toIso8601String(),
        });
        await _writeUsage(directory, usage);
      });

  Future<Map<String, dynamic>> _backupValue(String packId) async {
    final manifest = await _readManifest(packId);
    final files = <Map<String, dynamic>>[];
    for (final raw in manifest['files'] as List) {
      if (raw is! Map || raw['path'] is! String) {
        throw const FormatException('技能包清单损坏。');
      }
      final path = raw['path'] as String;
      final entry = await _regularPackFile(packId, path);
      final bytes = await entry.readAsBytes();
      if (bytes.length != raw['bytes'] ||
          sha256.convert(bytes).toString() != raw['sha256']) {
        throw const FileSystemException('技能包资源缺失或摘要不匹配');
      }
      files.add({
        'path': path,
        'content': base64Encode(bytes),
        'sha256': raw['sha256'],
      });
    }
    return {
      'packId': packId,
      'source': manifest['source'],
      'license': manifest['license'],
      'licenseStatus': manifest['licenseStatus'],
      'applicability': manifest['applicability'],
      'requestedTools': manifest['requestedTools'],
      'validationStatus': 'imported_unverified',
      'verified': false,
      'files': files,
    };
  }

  Future<Map<String, dynamic>> _readManifest(String packId) async {
    if (!_validPackId(packId)) throw const FormatException('技能包 ID 无效。');
    final file = await _regularPackFile(packId, 'pack.json');
    if (await file.length() > 64 * 1024) {
      throw const FormatException('技能包元数据超出限制。');
    }
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) throw const FormatException('技能包元数据无效。');
    final manifest = Map<String, dynamic>.from(decoded);
    const allowed = {
      'schemaVersion',
      'packId',
      'source',
      'license',
      'licenseStatus',
      'applicability',
      'requestedTools',
      'validationStatus',
      'verified',
      'files',
    };
    if (manifest.keys.any((key) => !allowed.contains(key)) ||
        manifest.length != allowed.length ||
        manifest['schemaVersion'] != 1 ||
        manifest['packId'] != packId ||
        manifest['source'] is! Map ||
        manifest['license'] is! String ||
        manifest['licenseStatus'] is! String ||
        manifest['applicability'] is! String ||
        manifest['requestedTools'] is! List ||
        (manifest['validationStatus'] != 'imported_unverified' &&
            manifest['validationStatus'] != 'verified') ||
        manifest['verified'] != (manifest['validationStatus'] == 'verified') ||
        manifest['files'] is! List ||
        (manifest['files'] as List).length > maxSkillPackFiles) {
      throw const FormatException('技能包元数据结构无效。');
    }
    return manifest;
  }

  Future<void> _verifyPackFiles(String packId) async {
    final manifest = await _readManifest(packId);
    var total = 0;
    for (final raw in manifest['files'] as List) {
      if (raw is! Map ||
          raw['path'] is! String ||
          raw['sha256'] is! String ||
          raw['bytes'] is! int) {
        throw const FormatException('技能包文件清单无效。');
      }
      final file = await _regularPackFile(packId, raw['path'] as String);
      final bytes = await file.readAsBytes();
      if (bytes.length != raw['bytes'] ||
          sha256.convert(bytes).toString() != raw['sha256']) {
        throw const FileSystemException('技能包资源摘要不匹配');
      }
      total += bytes.length;
    }
    if (total > maxSkillPackBytes) throw const FormatException('技能包总大小超出限制。');
  }

  Future<File> _regularPackFile(String packId, String path) async {
    if (!_safePackPath(path)) throw const FormatException('技能资源路径无效。');
    if (await FileSystemEntity.type(root.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const FileSystemException('技能资源根目录不存在或不是安全目录');
    }
    final directory = _packDirectory(packId);
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const FileSystemException('技能资源包不存在');
    }
    var current = directory;
    final segments = path.split('/');
    for (final segment in segments.take(segments.length - 1)) {
      current = Directory(p.join(current.path, segment));
      if (await FileSystemEntity.type(current.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        throw const FileSystemException('技能资源目录不存在或无效');
      }
    }
    final file = File(p.joinAll([directory.path, ...segments]));
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const FileSystemException('技能资源不是普通文件');
    }
    if (await file.length() > maxSkillPackBytes) {
      throw const FileSystemException('技能资源文件超出限制');
    }
    return file;
  }

  Future<Map<String, dynamic>> _readUsage(Directory directory) async {
    final file = File(p.join(directory.path, 'usage.json'));
    if (await FileSystemEntity.type(file.path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return {
        'reads': <dynamic>[],
        'scriptRuns': <dynamic>[],
        'trials': <dynamic>[]
      };
    }
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const FileSystemException('技能使用凭据不是普通文件');
    }
    if (await file.length() > 1024 * 1024) {
      throw const FormatException('技能使用凭据超出限制。');
    }
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map ||
        decoded.keys
            .toSet()
            .difference(const {'reads', 'scriptRuns', 'trials'}).isNotEmpty ||
        decoded.length != 3 ||
        decoded.values.any((value) => value is! List) ||
        decoded.values
            .any((value) => (value as List).length > maxUsageEntries)) {
      throw const FormatException('技能使用凭据损坏。');
    }
    return Map<String, dynamic>.from(decoded);
  }

  Future<void> _writeUsage(
      Directory directory, Map<String, dynamic> usage) async {
    final file = File(p.join(directory.path, 'usage.json'));
    await _atomicWrite(file, const JsonEncoder.withIndent('  ').convert(usage));
  }

  Future<void> _writeManifest(
      Directory directory, Map<String, dynamic> manifest) async {
    final file = File(p.join(directory.path, 'pack.json'));
    await _atomicWrite(
        file, const JsonEncoder.withIndent('  ').convert(manifest));
  }

  Future<void> _atomicWrite(File file, String contents) async {
    final temporary = File('${file.path}.pending-${const Uuid().v4()}');
    await temporary.writeAsString(contents, flush: true);
    try {
      await temporary.rename(file.path);
    } on Object {
      if (await file.exists()) await file.delete();
      await temporary.rename(file.path);
    }
  }

  Future<void> _ensureRoot() async {
    final type = await FileSystemEntity.type(root.path, followLinks: false);
    if (type == FileSystemEntityType.link ||
        (type != FileSystemEntityType.notFound &&
            type != FileSystemEntityType.directory)) {
      throw const FileSystemException('技能资源目录不是安全目录');
    }
    await root.create(recursive: true);
  }

  Map<String, dynamic> _manifestFile(
      Map<String, dynamic> manifest, String path) {
    for (final raw in manifest['files'] as List) {
      if (raw is Map && raw['path'] == path) {
        return Map<String, dynamic>.from(raw);
      }
    }
    throw const FileSystemException('技能包不包含请求的资源');
  }

  Directory _packDirectory(String packId) =>
      Directory(p.join(root.path, packId));

  Future<T> _serialize<T>(Future<T> Function() action) async {
    final previous = _writeQueue;
    final completion = Completer<void>();
    _writeQueue = completion.future.catchError((Object _) {});
    await previous.catchError((Object _) {});
    try {
      final result = await action();
      completion.complete();
      return result;
    } on Object catch (error, stack) {
      completion.completeError(error, stack);
      rethrow;
    }
  }

  static bool _validPackId(String value) =>
      RegExp(r'^[0-9a-f]{64}$').hasMatch(value);

  static bool _safePackPath(String value) =>
      value.isNotEmpty &&
      value.length <= 500 &&
      !value.startsWith('/') &&
      !value.contains('\\') &&
      !value.contains('%') &&
      !RegExp(r'[\u0000-\u001f\u007f]').hasMatch(value) &&
      value.split('/').every(
          (segment) => segment.isNotEmpty && segment != '.' && segment != '..');
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:chat_group/features/document/binary_document_parser.dart';

import 'package:crypto/crypto.dart';
import 'work_artifact_delivery_guard.dart';
import 'work_public_update_stream.dart';
import 'package:chat_group/features/web_search/security/search_secret_scanner.dart';
import 'package:chat_group/features/work_mode/work_collaboration_state.dart';
import 'package:path/path.dart' as p;

part 'work_candidate_evidence.dart';

/// Publication I/O under the existing media tree, independent of rollback
/// snapshots. The directory rename commits content; index writing is repairable.
class WorkCandidatePublisher {
  static const maxFiles = 64;
  static const maxFileBytes = 50 * 1024 * 1024;
  static const maxCandidateBytes = 200 * 1024 * 1024;
  static const maxHistoryBytes = 1024 * 1024 * 1024;
  static const maxMetadataBytes = 1024 * 1024;
  final Directory directory;
  final Future<void> Function(File source, File target)? copy;
  final Future<void> Function(String phase)? fault;
  WorkCandidatePublisher(this.directory, {this.copy, this.fault});

  // ponytail: serialize app-local publications; per-task locks if publication
  // throughput matters. One app owns these media files, not multiple processes.
  static Future<void> _tail = Future.value();
  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<WorkCandidate> publish({
    required String publicationId,
    required WorkCollaborationState state,
    required String producerId,
    required Map<String, File> sources,
    String baseline = '',
  }) =>
      _serial(() async {
        _id(publicationId);
        _id(producerId);
        if (const SearchSecretScanner().containsSensitiveData(baseline) ||
            RegExp(r'(?:/Users/|/Volumes/|/home/|[A-Za-z]:[\\/])')
                .hasMatch(baseline)) {
          throw StateError('重建基线必须为无凭据的便携说明。');
        }
        if (!state.activeMembers.contains(producerId) ||
            sources.isEmpty ||
            sources.length > maxFiles ||
            baseline.length > 4096) {
          throw StateError('候选合同、制作者或文件数量无效。');
        }
        final names = sources.keys.toList()..sort();
        for (final name in names) {
          _relative(name);
          _allowed(name);
        }
        await _prepareDirectory(directory);
        final binding = {
          'schemaVersion': 1,
          'publicationId': publicationId,
          'taskId': state.taskId,
          'conversationId': state.conversationId,
          'requestRevision': state.requestRevision,
          'teamRevision': state.teamRevision,
          'producerId': producerId,
          'teamMemberIds': state.activeMembers.toList()..sort(),
          'contract': {
            'type': state.artifactContract['type'],
            'format': state.artifactContract['format'],
          },
          'baseline': WorkPublicUpdateStream.sanitize(baseline),
          'requiredPaths': names,
        };
        final existing = await _recoverUnlocked();
        for (final candidate in existing) {
          if (candidate.manifest['publicationId'] != publicationId) continue;
          if (jsonEncode(_binding(candidate.manifest)) != jsonEncode(binding)) {
            throw StateError('同一发布标识不能替换内容基线。');
          }
          await verify(candidate, expectedDigest: candidate.digest);
          return candidate;
        }
        final reservation = File('${directory.path}/pending.json');
        final pending = await _reserve(binding, reservation, existing, state);
        return _publishReserved(
            pending, sources, reservation, existing.lastOrNull);
      });

  Future<Map<String, dynamic>> _reserve(
      Map<String, dynamic> binding,
      File reservation,
      List<WorkCandidate> existing,
      WorkCollaborationState state) async {
    Map<String, dynamic> pending;
    if (await reservation.exists()) {
      pending = await readMetadata(reservation);
      if (jsonEncode(_binding(pending)) != jsonEncode(binding)) {
        throw StateError('上次候选发布尚未完成，请恢复或明确清理后继续。');
      }
    } else {
      final allocated = [
        ...existing.map((c) => int.parse(c.iterationId.substring(1))),
        ...state.iterations
            .map((i) => int.parse((i['id'] as String).substring(1))),
      ]..sort();
      final next = allocated.isEmpty ? 1 : allocated.last + 1;
      pending = {
        ...binding,
        'iterationId': 'r${next.toString().padLeft(3, '0')}',
        'createdAt': DateTime.now().toUtc().toIso8601String()
      };
      await _atomicJson(reservation, pending);
    }
    return pending;
  }

  Future<WorkCandidate> _publishReserved(
      Map<String, dynamic> pending,
      Map<String, File> sources,
      File reservation,
      WorkCandidate? previous) async {
    final id = pending['iterationId'] as String;
    if (!RegExp(r'^r[0-9]{3,}$').hasMatch(id)) throw StateError('候选保留编号损坏。');
    final staging = Directory('${directory.path}/.$id.staging');
    if (await staging.exists()) await staging.delete(recursive: true);
    await _prepareDirectory(staging);
    final entries = await _copyContract(staging, pending, sources);
    if (previous != null &&
        previous.manifest['requestRevision'] == pending['requestRevision'] &&
        previous.manifest['teamRevision'] == pending['teamRevision'] &&
        jsonEncode(previous.files) == jsonEncode(entries)) {
      throw StateError('候选内容没有变化，不能制造新的修复迭代。');
    }
    await _validateLocalReferences(staging, entries);
    final content = {...pending, 'files': entries};
    final manifest = {...content, 'artifactDigest': _jsonHash(content)};
    await _atomicJson(File('${staging.path}/candidate.json'), manifest);
    final candidate = WorkCandidate(staging, manifest);
    await verify(candidate, expectedDigest: candidate.digest);
    await fault?.call('beforePublish');
    final published = Directory('${directory.path}/$id');
    if (await published.exists()) throw StateError('候选版本已存在，禁止覆盖。');
    await staging.rename(published.path);
    await fault?.call('afterPublish');
    // A crash here leaves a complete directory. Recovery repairs the catalog
    // before returning it; the same publicationId cannot allocate another rNNN.
    await _recoverUnlocked();
    if (await reservation.exists()) await reservation.delete();
    return WorkCandidate(published, manifest);
  }

  Future<List<Map<String, dynamic>>> _copyContract(Directory staging,
      Map<String, dynamic> pending, Map<String, File> sources) async {
    var total = 0;
    final entries = <Map<String, dynamic>>[];
    for (final name in pending['requiredPaths'] as List) {
      final source = sources[name]!;
      await _plainFile(source);
      final size = await source.length();
      total += size;
      if (size <= 0 ||
          size > maxFileBytes ||
          total > maxCandidateBytes ||
          await _historyBytes() + total * 2 > maxHistoryBytes) {
        throw StateError('候选包或磁盘保留额度不足，请调整合同或明确清理附件。');
      }
      if (!await WorkArtifactDeliveryGuard.validateFrozenFile(source)) {
        throw StateError('候选包含格式无效或空正文文件。');
      }
      await _checkSecrets(source, name as String);
      final before = await fileDigest(source);
      final target = File('${staging.path}/artifacts/$name');
      await _prepareDirectory(target.parent);
      await (copy == null ? source.copy(target.path) : copy!(source, target));
      await _plainFile(target);
      if (await target.length() != size ||
          await fileDigest(target) != before ||
          await fileDigest(source) != before) {
        throw StateError('复制中断或工作文件发生变化，未发布候选。');
      }
      entries.add({'path': name, 'bytes': size, 'sha256': before});
    }
    return entries;
  }

  /// Explicitly abandon a failed unpublished attempt before changing its file
  /// contract. Published versions and user working files are never deleted.
  Future<void> discardUnpublished(String publicationId) => _serial(() async {
        _id(publicationId);
        await _prepareDirectory(directory);
        final reservation = File('${directory.path}/pending.json');
        if (!await reservation.exists()) return;
        final pending = await readMetadata(reservation);
        final id = pending['iterationId'] as String;
        if (pending['publicationId'] != publicationId ||
            !RegExp(r'^r[0-9]{3,}$').hasMatch(id) ||
            await Directory('${directory.path}/$id').exists()) {
          throw StateError('不能丢弃已发布或其他候选。');
        }
        final staging = Directory('${directory.path}/.$id.staging');
        if (await FileSystemEntity.type(staging.path, followLinks: false) ==
            FileSystemEntityType.link) {
          throw StateError('候选暂存目录为符号链接。');
        }
        if (await staging.exists()) await staging.delete(recursive: true);
        await reservation.delete();
      });

  Future<List<WorkCandidate>> recover() => _serial(() async {
        await _prepareDirectory(directory);
        return _recoverUnlocked();
      });

  Future<List<WorkCandidate>> _recoverUnlocked() async {
    final candidates = <WorkCandidate>[];
    await for (final entity in directory.list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (!RegExp(r'^r[0-9]{3,}$').hasMatch(name)) continue;
      if (await FileSystemEntity.type(entity.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        throw StateError('候选目录损坏。');
      }
      final manifest =
          await readMetadata(File('${entity.path}/candidate.json'));
      final candidate = WorkCandidate(Directory(entity.path), manifest);
      if (candidate.iterationId != name) throw StateError('候选索引身份不一致。');
      await verify(candidate, expectedDigest: candidate.digest);
      candidates.add(candidate);
    }
    candidates.sort((a, b) => int.parse(a.iterationId.substring(1))
        .compareTo(int.parse(b.iterationId.substring(1))));
    if (candidates.map((c) => c.manifest['publicationId']).toSet().length !=
        candidates.length) {
      throw StateError('候选发布标识重复。');
    }
    await fault?.call('beforeIndex');
    await _atomicJson(File('${directory.path}/index.json'), {
      'schemaVersion': 1,
      'iterations': candidates
          .map((c) => {
                ...c.reference,
                'publicationId': c.manifest['publicationId'],
                'manifest': '${c.iterationId}/candidate.json',
              })
          .toList(),
    });
    final reservation = File('${directory.path}/pending.json');
    if (await reservation.exists()) {
      final pending = await readMetadata(reservation);
      if (candidates.any(
          (c) => c.manifest['publicationId'] == pending['publicationId'])) {
        await reservation.delete();
      }
    }
    return candidates;
  }

  /// Checks the authoritative expected digest, not merely the hash stored next
  /// to files. Call before and after testing, before signing, and on resend.
  Future<void> verify(WorkCandidate candidate,
      {required String expectedDigest, Map<String, File>? testedFiles}) async {
    if (!p.isWithin(directory.path, candidate.directory.path)) {
      throw StateError('候选不在当前任务媒体目录。');
    }
    final manifest =
        await readMetadata(File('${candidate.directory.path}/candidate.json'));
    final content = {...manifest}..remove('artifactDigest');
    if (manifest['schemaVersion'] != 1 ||
        manifest['artifactDigest'] != expectedDigest ||
        _jsonHash(content) != expectedDigest ||
        jsonEncode(manifest) != jsonEncode(candidate.manifest)) {
      throw StateError('候选身份已变化，原测试和签字无效。');
    }
    final files = candidate.files;
    if (files.isEmpty || files.length > maxFiles) throw StateError('候选文件清单无效。');
    final names = files.map((f) => f['path']).toList();
    if (jsonEncode(names) != jsonEncode(manifest['requiredPaths'])) {
      throw StateError('候选缺少合同文件。');
    }
    final actualNames = <String>{};
    final artifacts = Directory('${candidate.directory.path}/artifacts');
    await _assertParents(artifacts);
    await for (final entity
        in artifacts.list(recursive: true, followLinks: false)) {
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      if (type == FileSystemEntityType.link) throw StateError('候选内容出现符号链接。');
      if (type == FileSystemEntityType.file) {
        actualNames.add(p
            .relative(entity.path, from: artifacts.path)
            .replaceAll('\\', '/'));
      }
    }
    if (actualNames.length != names.length || !actualNames.containsAll(names)) {
      throw StateError('候选文件集合已变化，原测试和签字无效。');
    }
    for (final entry in files) {
      final name = entry['path'] as String;
      _relative(name);
      _allowed(name);
      final file = candidate.file(name);
      await _plainFile(file);
      if (await file.length() != entry['bytes'] ||
          await fileDigest(file) != entry['sha256']) {
        throw StateError('候选文件被外部修改，原测试和签字无效。');
      }
      if (testedFiles != null) {
        final tested = testedFiles[name];
        if (tested == null) throw StateError('被测工作区缺少合同文件。');
        await _plainFile(tested);
        if (await fileDigest(tested) != entry['sha256']) {
          throw StateError('被测工作区已变化，原测试和签字无效。');
        }
      }
    }
  }

  Future<int> _historyBytes() async {
    var bytes = 0;
    await for (final entity
        in directory.list(recursive: true, followLinks: false)) {
      if (entity is File) bytes += await entity.length();
    }
    return bytes;
  }

  static Map<String, dynamic> _binding(Map<String, dynamic> m) => {
        for (final key in const [
          'schemaVersion',
          'publicationId',
          'taskId',
          'conversationId',
          'requestRevision',
          'teamRevision',
          'producerId',
          'teamMemberIds',
          'contract',
          'baseline',
          'requiredPaths'
        ])
          key: m[key],
      };
  static String _jsonHash(Object value) =>
      sha256.convert(utf8.encode(jsonEncode(value))).toString();
  static Future<String> fileDigest(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();
  static void _id(String value) {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(value)) {
      throw StateError('发布标识无效。');
    }
  }

  static void _relative(String value) {
    if (value.length > 512 ||
        p.isAbsolute(value) ||
        value.contains('\\') ||
        value.contains(':') ||
        value.split('/').any((s) => s.isEmpty || s == '.' || s == '..') ||
        value.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      throw StateError('候选相对路径无效。');
    }
  }

  static void _allowed(String name) {
    final segments = name.toLowerCase().split('/');
    if (segments.any((s) =>
        const {
          '.git',
          'node_modules',
          '.dart_tool',
          'build',
          '__pycache__',
          '.cache',
          '.env',
          'credentials',
          '.ssh',
          '.npmrc',
          '.netrc',
          '.aws',
          '.azure',
          'api_configs.hive',
          'dev_credentials.hive'
        }.contains(s) ||
        s.startsWith('.env.') ||
        RegExp(r'\.(pem|key|p12|pfx)$').hasMatch(s))) {
      throw StateError('合同包含凭据或无关缓存，请调整交付清单。');
    }
  }

  static Future<void> _checkSecrets(File file, String name) async {
    if (name.toLowerCase().endsWith('.docx')) {
      final sections = BinaryDocumentParser.validateDocxForDelivery(
          await file.readAsBytes());
      if (sections.any((section) =>
          const SearchSecretScanner().containsSensitiveData(section.text))) {
        throw StateError('候选包含敏感信息，未发布。');
      }
      return;
    }
    if (!RegExp(r'\.(txt|md|html?|json|ya?ml|js|ts|py|dart|css|sh|xml|csv)$',
            caseSensitive: false)
        .hasMatch(name)) {
      return;
    }
    if (const SearchSecretScanner()
        .containsSensitiveData(await file.readAsString())) {
      throw StateError('候选包含敏感信息，未发布。');
    }
  }

  static Future<void> _plainFile(File file) async {
    await _assertParents(file.parent);
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw StateError('候选文件缺失或为符号链接。');
    }
  }

  static Future<void> _assertParents(Directory dir) async {
    var current = dir.absolute;
    for (;;) {
      final type =
          await FileSystemEntity.type(current.path, followLinks: false);
      final platformAlias =
          Platform.isMacOS && {'/var', '/tmp'}.contains(current.path);
      if (type == FileSystemEntityType.link && !platformAlias) {
        throw StateError('候选父目录为符号链接。');
      }
      final parent = current.parent;
      if (parent.path == current.path) break;
      current = parent;
    }
  }

  static Future<void> _prepareDirectory(Directory dir) async {
    if (await FileSystemEntity.type(dir.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw StateError('候选目录为符号链接。');
    }
    if (!await dir.exists()) {
      if (dir.parent.path != dir.path) await _prepareDirectory(dir.parent);
      await dir.create();
    }
    await _assertParents(dir);
  }

  static Future<Map<String, dynamic>> readMetadata(File file) async {
    await _plainFile(file);
    if (await file.length() > maxMetadataBytes) throw StateError('候选元数据过大。');
    return Map<String, dynamic>.from(
        jsonDecode(await file.readAsString()) as Map);
  }

  static Future<void> _atomicJson(File file, Object value) async {
    final text = jsonEncode(value);
    if (utf8.encode(text).length > maxMetadataBytes) {
      throw StateError('候选元数据过大。');
    }
    await _prepareDirectory(file.parent);
    final temporary = File('${file.path}.tmp');
    if (await FileSystemEntity.type(temporary.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw StateError('候选临时路径无效。');
    }
    await temporary.writeAsString(text, flush: true);
    await temporary.rename(file.path);
  }

  static Future<void> _validateLocalReferences(
      Directory staging, List<Map<String, dynamic>> entries) async {
    final names = entries.map((e) => e['path'] as String).toSet();
    for (final name in names
        .where((n) => RegExp(r'\.html?$', caseSensitive: false).hasMatch(n))) {
      final html = await File('${staging.path}/artifacts/$name').readAsString();
      for (final match in RegExp(r'''(?:src|href)\s*=\s*["']([^"']+)["']''',
              caseSensitive: false)
          .allMatches(html)) {
        final ref = match.group(1)!;
        if (ref.startsWith('#') ||
            ref.startsWith('data:') ||
            Uri.tryParse(ref)?.hasScheme == true) {
          continue;
        }
        final clean = ref.split(RegExp(r'[?#]')).first;
        if (clean.isEmpty) continue;
        final target =
            p.posix.normalize(p.posix.join(p.posix.dirname(name), clean));
        if (clean.startsWith('/') || !names.contains(target)) {
          throw StateError('候选缺少网页引用的素材或脚本：$clean');
        }
      }
    }
  }
}

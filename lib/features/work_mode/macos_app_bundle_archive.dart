import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'work_candidate_publication.dart';

class MacAppBundleDescription {
  final String appPath;
  final String archivePath;
  final String bundleId;
  final String executablePath;
  final String archiveSha256;
  final String treeSha256;
  final String dataEnvironment;
  final int archiveBytes;
  final int fileCount;

  const MacAppBundleDescription({
    required this.appPath,
    required this.archivePath,
    required this.bundleId,
    required this.executablePath,
    required this.archiveSha256,
    required this.treeSha256,
    required this.dataEnvironment,
    required this.archiveBytes,
    required this.fileCount,
  });

  Map<String, dynamic> toJson() => {
        'schemaVersion': 1,
        'appPath': appPath,
        'archivePath': archivePath,
        'bundleId': bundleId,
        'executablePath': executablePath,
        'archiveSha256': archiveSha256,
        'treeSha256': treeSha256,
        'dataEnvironment': dataEnvironment,
        'archiveBytes': archiveBytes,
        'fileCount': fileCount,
      };

  static MacAppBundleDescription? tryParse(Object? value) {
    if (value is! Map ||
        value.length != 10 ||
        value.keys.any((key) => key is! String) ||
        value['schemaVersion'] != 1 ||
        value['appPath'] is! String ||
        value['archivePath'] is! String ||
        value['bundleId'] is! String ||
        value['executablePath'] is! String ||
        value['archiveSha256'] is! String ||
        value['treeSha256'] is! String ||
        value['dataEnvironment'] != 'CHAT_GROUP_TEST_DATA_DIR' ||
        value['archiveBytes'] is! int ||
        value['fileCount'] is! int) {
      return null;
    }
    final appPath = value['appPath'] as String;
    final archivePath = value['archivePath'] as String;
    final executablePath = value['executablePath'] as String;
    if (!MacAppBundleArchive._validRelative(appPath) ||
        !appPath.endsWith('.app') ||
        !MacAppBundleArchive._validRelative(archivePath) ||
        !archivePath.endsWith('.zip') ||
        !MacAppBundleArchive._validRelative(executablePath) ||
        !p.posix.isWithin(appPath, executablePath) ||
        !(value['bundleId'] as String).contains('.') ||
        (value['bundleId'] as String).length > 255 ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9.-]{1,254}$')
            .hasMatch(value['bundleId'] as String) ||
        p.posix.dirname(executablePath) != '$appPath/Contents/MacOS' ||
        !MacAppBundleArchive._validExecutableName(
            p.posix.basename(executablePath)) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(value['archiveSha256'] as String) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(value['treeSha256'] as String) ||
        (value['archiveBytes'] as int) <= 0 ||
        (value['archiveBytes'] as int) > MacAppBundleArchive.maxArchiveBytes ||
        (value['fileCount'] as int) <= 0 ||
        (value['fileCount'] as int) > MacAppBundleArchive.maxEntries) {
      return null;
    }
    return MacAppBundleDescription(
      appPath: appPath,
      archivePath: archivePath,
      bundleId: value['bundleId'] as String,
      executablePath: executablePath,
      archiveSha256: value['archiveSha256'] as String,
      treeSha256: value['treeSha256'] as String,
      dataEnvironment: value['dataEnvironment'] as String,
      archiveBytes: value['archiveBytes'] as int,
      fileCount: value['fileCount'] as int,
    );
  }
}

/// Narrow `.app` ZIP contract. Archive entries are checked before any regular
/// file content is decompressed, then rechecked after extraction.
class MacAppBundleArchive {
  static const int maxArchiveBytes = 512 * 1024 * 1024;
  static const int maxExpandedBytes = 1024 * 1024 * 1024;
  static const int maxEntryBytes = 256 * 1024 * 1024;
  static const int maxEntries = 20000;
  static const int _maxInfoPlistBytes = 2 * 1024 * 1024;
  static const int _maxLinkBytes = 4096;

  static Future<MacAppBundleDescription> package({
    required Directory app,
    required Directory workspaceRoot,
    required File destination,
    required String appPath,
    required String archivePath,
  }) async {
    if (!Platform.isMacOS ||
        !_validRelative(appPath) ||
        !appPath.endsWith('.app') ||
        !_validRelative(archivePath) ||
        !archivePath.endsWith('.zip') ||
        await FileSystemEntity.type(app.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        p.basename(app.path) != p.posix.basename(appPath)) {
      throw StateError('仅接受 macOS 上的真实 .app 目录。');
    }
    final rootPath = await workspaceRoot.resolveSymbolicLinks();
    final appPathResolved = await app.resolveSymbolicLinks();
    if (p.posix.relative(appPathResolved, from: rootPath) != appPath) {
      throw StateError('App 实际路径与工作区候选路径不一致。');
    }
    await Directory(destination.parent.path).create(recursive: true);
    if (await FileSystemEntity.type(destination.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw StateError('App ZIP 目标已存在，禁止覆盖。');
    }
    final before = await _inspectTree(Directory(appPathResolved), appPath);
    final signature = await Process.run(
        '/usr/bin/codesign', ['--verify', '--strict', appPathResolved]);
    if (signature.exitCode != 0) {
      throw StateError('源 App 包签名结构校验失败。');
    }
    try {
      final result = await Process.run(
        '/usr/bin/zip',
        ['-q', '-r', '-y', destination.path, '--', appPath],
        workingDirectory: rootPath,
      );
      if (result.exitCode != 0) {
        throw StateError('系统 ZIP 工具未能封装 App 包。');
      }
      final description = await inspect(destination,
          appPath: appPath, archivePath: archivePath);
      if (description.archiveBytes > maxArchiveBytes) {
        throw StateError('App ZIP 超过 512 MiB 上限。');
      }
      final after = await _inspectTree(Directory(appPathResolved), appPath);
      if (jsonEncode(before) != jsonEncode(after)) {
        throw StateError('App 包在冻结期间发生变化，不能生成候选。');
      }
      if (after['treeSha256'] != description.treeSha256 ||
          after['fileCount'] != description.fileCount) {
        throw StateError('ZIP 未保留 App 包内文件、链接或执行权限。');
      }
      return description;
    } on Object {
      if (await destination.exists()) await destination.delete();
      rethrow;
    }
  }

  static Future<MacAppBundleDescription> inspect(
    File archive, {
    required String appPath,
    required String archivePath,
  }) async {
    final bytes = await archive.length();
    if (!Platform.isMacOS ||
        !_validRelative(appPath) ||
        !appPath.endsWith('.app') ||
        !_validRelative(archivePath) ||
        !archivePath.endsWith('.zip') ||
        bytes <= 0 ||
        bytes > maxArchiveBytes) {
      throw StateError('App ZIP 路径或大小无效。');
    }
    final headerInput = InputFileStream(archive.path);
    final directory = ZipDirectory();
    try {
      directory.read(headerInput);
    } finally {
      await headerInput.close();
    }
    _validateHeaders(directory.fileHeaders, appPath);

    final input = InputFileStream(archive.path);
    final decoded = ZipDecoder().decodeStream(input);
    await input.close();
    final entries = _validateEntries(decoded, appPath);
    for (final entry in entries) {
      if (entry.name == appPath) continue;
      WorkCandidatePublisher.validateDeliveryPath(
          p.posix.relative(entry.name, from: appPath));
    }
    final plistName = '$appPath/Contents/Info.plist';
    final plist =
        entries.where((entry) => entry.name == plistName).singleOrNull;
    if (plist == null ||
        plist.isSymbolicLink ||
        plist.size <= 0 ||
        plist.size > _maxInfoPlistBytes) {
      throw StateError('App 包缺少受限大小内的 Contents/Info.plist。');
    }
    final plistBytes = plist.readBytes();
    if (plistBytes == null || plistBytes.length != plist.size) {
      throw StateError('Info.plist 解压结果不完整。');
    }
    final plistData = await _parsePlist(plistBytes);
    final bundleId = plistData['CFBundleIdentifier'];
    final executable = plistData['CFBundleExecutable'];
    final dataEnvironment = plistData['ChatGroupTestDataEnvironment'];
    if (bundleId is! String ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9.-]{1,254}$').hasMatch(bundleId) ||
        executable is! String ||
        !_validExecutableName(executable) ||
        dataEnvironment != 'CHAT_GROUP_TEST_DATA_DIR') {
      throw StateError('Info.plist 的包身份或执行文件字段无效。');
    }
    final executablePath = '$appPath/Contents/MacOS/$executable';
    final executableEntry =
        entries.where((entry) => entry.name == executablePath).singleOrNull;
    if (executableEntry == null ||
        !executableEntry.isFile ||
        executableEntry.isSymbolicLink ||
        executableEntry.size <= 0 ||
        executableEntry.unixPermissions & 0x49 == 0) {
      throw StateError('App 主执行文件缺失、为空或没有执行权限。');
    }
    final canonicalEntries = <Map<String, Object?>>[];
    for (final entry in entries) {
      if (entry.isDirectory && !entry.isSymbolicLink) continue;
      if (entry.isSymbolicLink) {
        canonicalEntries.add({
          'path': entry.name,
          'type': 'link',
          'mode': 0,
          'target': entry.symbolicLink,
        });
      } else {
        final content = entry.readBytes();
        if (content == null || content.length != entry.size) {
          throw StateError('App 包文件解压不完整。');
        }
        await WorkCandidatePublisher.checkDeliveredBytes(
            p.posix.relative(entry.name, from: appPath), content);
        canonicalEntries.add({
          'path': entry.name,
          'type': 'file',
          'mode': entry.unixPermissions,
          'sha256': sha256.convert(content).toString(),
        });
      }
    }
    canonicalEntries
        .sort((a, b) => (a['path'] as String).compareTo(b['path'] as String));
    return MacAppBundleDescription(
      appPath: appPath,
      archivePath: archivePath,
      bundleId: bundleId,
      executablePath: executablePath,
      archiveSha256: await _fileDigest(archive),
      treeSha256: _jsonDigest(canonicalEntries),
      dataEnvironment: dataEnvironment as String,
      archiveBytes: bytes,
      fileCount: canonicalEntries.length,
    );
  }

  static Future<Directory> extractVerified({
    required File archive,
    required MacAppBundleDescription expected,
    required Directory destination,
  }) async {
    final actual = await inspect(archive,
        appPath: expected.appPath, archivePath: expected.archivePath);
    if (jsonEncode(actual.toJson()) != jsonEncode(expected.toJson())) {
      throw StateError('App ZIP 或包内摘要与冻结候选不一致。');
    }
    if (await FileSystemEntity.type(destination.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw StateError('测试副本目录已存在，拒绝覆盖。');
    }
    await destination.create(recursive: true);
    try {
      final input = InputFileStream(archive.path);
      final decoded = ZipDecoder().decodeStream(input);
      await input.close();
      for (final entry in _validateEntries(decoded, expected.appPath)) {
        final target =
            p.joinAll([destination.path, ...p.posix.split(entry.name)]);
        if (entry.isDirectory && !entry.isSymbolicLink) {
          await Directory(target).create(recursive: true);
          continue;
        }
        await Directory(p.dirname(target)).create(recursive: true);
        if (entry.isSymbolicLink) {
          await Link(target).create(entry.symbolicLink!);
          continue;
        }
        final output = OutputFileStream(target);
        try {
          entry.writeContent(output);
        } finally {
          await output.close();
        }
        if (entry.unixPermissions > 0) {
          final mode = entry.unixPermissions.toRadixString(8);
          final chmod = await Process.run('/bin/chmod', [mode, target]);
          if (chmod.exitCode != 0) throw StateError('不能还原 App 包文件权限。');
        }
      }
      final app = Directory(
          p.joinAll([destination.path, ...p.posix.split(expected.appPath)]));
      final tree = await _inspectTree(app, expected.appPath);
      if (tree['treeSha256'] != expected.treeSha256 ||
          tree['fileCount'] != expected.fileCount) {
        throw StateError('解包 App 的内容、链接或权限摘要不匹配。');
      }
      final signature = await Process.run(
          '/usr/bin/codesign', ['--verify', '--strict', app.path]);
      if (signature.exitCode != 0) throw StateError('解包后的 App 签名结构校验失败。');
      final info =
          await _readBundleInfo(File(p.join(app.path, 'Contents/Info.plist')));
      if (info['CFBundleIdentifier'] != expected.bundleId ||
          info['CFBundleExecutable'] != p.basename(expected.executablePath) ||
          info['ChatGroupTestDataEnvironment'] != expected.dataEnvironment) {
        throw StateError('解包后的 App 包身份变化。');
      }
      return app;
    } on Object {
      await destination.delete(recursive: true);
      rethrow;
    }
  }

  static Future<void> verifyExtractedTree({
    required Directory app,
    required MacAppBundleDescription expected,
  }) async {
    if (await FileSystemEntity.type(app.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw StateError('当前试用副本缺失或不是安全目录。');
    }
    final actual = await _inspectTree(app, expected.appPath);
    if (actual['treeSha256'] != expected.treeSha256 ||
        actual['fileCount'] != expected.fileCount) {
      throw StateError('当前试用副本已偏离冻结候选，使用证据作废。');
    }
  }

  static void _validateHeaders(List<ZipFileHeader> headers, String appPath) {
    if (headers.isEmpty || headers.length > maxEntries) {
      throw StateError('App ZIP 文件数为空或超过上限。');
    }
    var total = 0;
    final names = <String>{};
    for (final header in headers) {
      final name =
          header.filename.replaceAll('\\', '/').replaceFirst(RegExp(r'/$'), '');
      if (!_validRelative(name) ||
          name != appPath && !p.posix.isWithin(appPath, name) ||
          !names.add(name.toLowerCase()) ||
          header.uncompressedSize < 0 ||
          header.compressedSize < 0 ||
          header.uncompressedSize > maxEntryBytes) {
        throw StateError('App ZIP 路径重复、越界或单项超过解压上限。');
      }
      final type = (header.externalFileAttributes >> 28) & 0xf;
      if (type != 0 && type != 4 && type != 8 && type != 10) {
        throw StateError('App ZIP 包含特殊文件类型。');
      }
      if (type == 10 && header.uncompressedSize > _maxLinkBytes) {
        throw StateError('App ZIP 符号链接目标超过上限。');
      }
      if (header.uncompressedSize > 1024 * 1024 &&
          header.compressedSize > 0 &&
          header.uncompressedSize / header.compressedSize > 200) {
        throw StateError('App ZIP 压缩比超过上限。');
      }
      if (header.uncompressedSize > 0 && header.compressedSize == 0) {
        throw StateError('App ZIP 文件压缩长度无效。');
      }
      total += header.uncompressedSize;
      if (total > maxExpandedBytes) throw StateError('App ZIP 展开体积超过上限。');
    }
  }

  static List<ArchiveFile> _validateEntries(Archive archive, String appPath) {
    if (archive.isEmpty || archive.length > maxEntries) {
      throw StateError('App ZIP 文件数为空或超过上限。');
    }
    var total = 0;
    final names = <String>{};
    final entries = archive.toList(growable: false);
    for (final entry in entries) {
      final name =
          entry.name.replaceAll('\\', '/').replaceFirst(RegExp(r'/$'), '');
      if (!_validRelative(name) ||
          name != appPath && !p.posix.isWithin(appPath, name) ||
          !names.add(name.toLowerCase()) ||
          entry.size < 0 ||
          entry.size > maxEntryBytes) {
        throw StateError('App ZIP 路径重复、越界或单项超过解压上限。');
      }
      if (entry.isSymbolicLink) {
        _validateLink(name, entry.symbolicLink ?? '', appPath);
      } else {
        final type = (entry.mode >> 12) & 0xf;
        if (type != 0 && type != 4 && type != 8) {
          throw StateError('App ZIP 包含特殊文件类型。');
        }
        if (type == 4 && !entry.isDirectory || type == 8 && !entry.isFile) {
          throw StateError('App ZIP 文件类型标记不匹配。');
        }
      }
      total += entry.size;
      if (total > maxExpandedBytes) throw StateError('App ZIP 展开体积超过上限。');
    }
    final byName = {for (final entry in entries) entry.name: entry};
    for (final entry in entries) {
      var parent = p.posix.dirname(entry.name);
      while (parent != appPath && p.posix.isWithin(appPath, parent)) {
        final ancestor = byName[parent];
        if (ancestor != null &&
            (!ancestor.isDirectory || ancestor.isSymbolicLink)) {
          throw StateError('App ZIP 子项不能穿过文件或符号链接。');
        }
        parent = p.posix.dirname(parent);
      }
    }
    return entries;
  }

  static void _validateLink(String name, String target, String appPath) {
    if (target.isEmpty ||
        p.posix.isAbsolute(target) ||
        target.contains('\\') ||
        target.contains('\u0000')) {
      throw StateError('App ZIP 符号链接必须使用包内相对目标。');
    }
    final resolved =
        p.posix.normalize(p.posix.join(p.posix.dirname(name), target));
    if (resolved != appPath && !p.posix.isWithin(appPath, resolved)) {
      throw StateError('App ZIP 符号链接指向 .app 包外。');
    }
  }

  static Future<Map<String, dynamic>> _parsePlist(List<int> bytes) async {
    final temp = await Directory.systemTemp.createTemp('chat-group-plist-');
    try {
      final file = File(p.join(temp.path, 'Info.plist'));
      await file.writeAsBytes(bytes, flush: true);
      return await _readBundleInfo(file);
    } finally {
      await temp.delete(recursive: true);
    }
  }

  static Future<Map<String, dynamic>> _readBundleInfo(File file) async {
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await file.length() > _maxInfoPlistBytes) {
      throw StateError('App 包 Info.plist 类型或大小无效。');
    }
    final result = await Process.run(
        '/usr/bin/plutil', ['-convert', 'json', '-o', '-', file.path]);
    if (result.exitCode != 0 || result.stdout is! String) {
      throw StateError('App 包 Info.plist 不能由 macOS plutil 解析。');
    }
    final decoded = jsonDecode(result.stdout as String);
    if (decoded is! Map || decoded.keys.any((key) => key is! String)) {
      throw StateError('App 包 Info.plist 不是属性字典。');
    }
    return Map<String, dynamic>.from(decoded);
  }

  static Future<Map<String, dynamic>> _inspectTree(
      Directory app, String archiveRoot) async {
    final entries = <Map<String, Object?>>[];
    var entryCount = 1;
    var totalBytes = 0;
    Future<void> visit(Directory directory, String relative) async {
      await for (final entity in directory.list(followLinks: false)) {
        if (++entryCount > maxEntries) {
          throw StateError('App 包文件数超过上限。');
        }
        final childRelative =
            p.relative(entity.path, from: app.path).replaceAll('\\', '/');
        final name = '$archiveRoot/$childRelative';
        final type =
            await FileSystemEntity.type(entity.path, followLinks: false);
        if (type == FileSystemEntityType.directory) {
          await visit(Directory(entity.path), relative);
        } else if (type == FileSystemEntityType.file) {
          final stat = await entity.stat();
          if (stat.size > maxEntryBytes ||
              (totalBytes += stat.size) > maxExpandedBytes) {
            throw StateError('App 包文件或总解压体积超过上限。');
          }
          entries.add({
            'path': name,
            'type': 'file',
            'mode': stat.mode & 0x1ff,
            'sha256': await _fileDigest(File(entity.path)),
          });
        } else if (type == FileSystemEntityType.link) {
          final target = await Link(entity.path).target();
          _validateLink(name, target, archiveRoot);
          final targetBytes = utf8.encode(target).length;
          if (targetBytes > _maxLinkBytes ||
              (totalBytes += targetBytes) > maxExpandedBytes) {
            throw StateError('App 包符号链接或总解压体积超过上限。');
          }
          entries.add({
            'path': name,
            'type': 'link',
            'mode': 0,
            'target': target,
          });
        } else {
          throw StateError('App 包包含特殊文件。');
        }
      }
    }

    await visit(app, archiveRoot);
    entries
        .sort((a, b) => (a['path'] as String).compareTo(b['path'] as String));
    return {'treeSha256': _jsonDigest(entries), 'fileCount': entries.length};
  }

  static Future<String> _fileDigest(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();

  static String _jsonDigest(Object value) =>
      sha256.convert(utf8.encode(jsonEncode(value))).toString();

  static bool _validRelative(String path) =>
      path.isNotEmpty &&
      !p.posix.isAbsolute(path) &&
      !RegExp(r'^[A-Za-z]:').hasMatch(path) &&
      !path.contains('\\') &&
      !path.contains('\u0000') &&
      p.posix.normalize(path) == path &&
      !path
          .split('/')
          .any((part) => part.isEmpty || part == '.' || part == '..');

  static bool _validExecutableName(String name) =>
      name.isNotEmpty &&
      name.length <= 128 &&
      name != '.' &&
      name != '..' &&
      !RegExp(r'[/\\:\x00-\x1f\x7f]').hasMatch(name);
}

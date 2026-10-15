import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:chat_group/features/web_search/security/search_secret_scanner.dart';
import 'package:yaml/yaml.dart';

const int maxSkillPackFiles = 32;
const int maxSkillPackFileBytes = 256 * 1024;
const int maxSkillPackBytes = 1024 * 1024;

class SkillResourceFile {
  final String path;
  final Uint8List bytes;
  final String sha256;

  const SkillResourceFile({
    required this.path,
    required this.bytes,
    required this.sha256,
  });

  String get extension => path.contains('.')
      ? path.substring(path.lastIndexOf('.')).toLowerCase()
      : '';

  bool get isText =>
      !const {'.png', '.jpg', '.jpeg', '.webp', '.gif'}.contains(extension);

  String get text => utf8.decode(bytes, allowMalformed: false);

  Map<String, dynamic> toManifestJson() => {
        'path': path,
        'bytes': bytes.length,
        'sha256': sha256,
      };

  Map<String, dynamic> toBackupJson() => {
        'path': path,
        'content': base64Encode(bytes),
        'sha256': sha256,
      };
}

class SkillResourcePack {
  final String id;
  final String owner;
  final String repo;
  final String sourcePath;
  final String commit;
  final String license;
  final String licenseStatus;
  final String applicability;
  final List<String> requestedTools;
  final String validationStatus;
  final List<SkillResourceFile> files;
  final String name;
  final String description;
  final String domain;
  final List<String> instructions;

  const SkillResourcePack({
    required this.id,
    required this.owner,
    required this.repo,
    required this.sourcePath,
    required this.commit,
    required this.license,
    required this.licenseStatus,
    required this.applicability,
    required this.requestedTools,
    required this.validationStatus,
    required this.files,
    required this.name,
    required this.description,
    required this.domain,
    required this.instructions,
  });

  SkillResourceFile? file(String path) {
    for (final file in files) {
      if (file.path == path) return file;
    }
    return null;
  }

  Map<String, dynamic> toLocalManifest() => {
        'schemaVersion': 1,
        'packId': id,
        'source': {
          'provider': 'github',
          'owner': owner,
          'repo': repo,
          'path': sourcePath,
          'commit': commit,
        },
        'license': license,
        'licenseStatus': licenseStatus,
        'applicability': applicability,
        'requestedTools': requestedTools,
        'validationStatus': validationStatus,
        'verified': validationStatus == 'verified',
        'files': files.map((file) => file.toManifestJson()).toList(),
      };

  Map<String, dynamic> toBackupValue() => {
        'packId': id,
        'source': {
          'provider': 'github',
          'owner': owner,
          'repo': repo,
          'path': sourcePath,
          'commit': commit,
        },
        'license': license,
        'licenseStatus': licenseStatus,
        'applicability': applicability,
        'requestedTools': requestedTools,
        // Backups carry source data, never device-local validation trust.
        'validationStatus': 'imported_unverified',
        'verified': false,
        'files': files.map((file) => file.toBackupJson()).toList(),
      };

  static SkillResourcePack fromGatewayJson(Object? raw) {
    final map = _strictMap(raw, const {
      'owner',
      'repo',
      'path',
      'commit',
      'license',
      'files',
    });
    return _parseFilesAndMetadata(
      owner: _string(map, 'owner', 100),
      repo: _string(map, 'repo', 100),
      sourcePath: _string(map, 'path', 500),
      commit: _string(map, 'commit', 40),
      license: _string(map, 'license', 100),
      rawFiles: map['files'],
      backup: false,
    );
  }

  static SkillResourcePack fromBackupValue(Object? raw) {
    final map = _strictMap(raw, const {
      'packId',
      'source',
      'license',
      'licenseStatus',
      'applicability',
      'requestedTools',
      'validationStatus',
      'verified',
      'files',
    });
    final source = _strictMap(map['source'], const {
      'provider',
      'owner',
      'repo',
      'path',
      'commit',
    });
    if (source['provider'] != 'github') {
      throw const FormatException('不支持的技能包来源。');
    }
    final pack = _parseFilesAndMetadata(
      owner: _string(source, 'owner', 100),
      repo: _string(source, 'repo', 100),
      sourcePath: _string(source, 'path', 500),
      commit: _string(source, 'commit', 40),
      license: _string(map, 'license', 100),
      rawFiles: map['files'],
      backup: true,
    );
    if (map['packId'] != pack.id ||
        map['verified'] != false ||
        map['validationStatus'] != 'imported_unverified' ||
        map['licenseStatus'] != pack.licenseStatus ||
        map['applicability'] != pack.applicability ||
        map['requestedTools'] is! List ||
        !_sameStrings(map['requestedTools'] as List, pack.requestedTools)) {
      throw const FormatException('技能包摘要不匹配。');
    }
    return pack;
  }

  static SkillResourcePack _parseFilesAndMetadata({
    required String owner,
    required String repo,
    required String sourcePath,
    required String commit,
    required String license,
    required Object? rawFiles,
    required bool backup,
  }) {
    if (!_ownerPattern.hasMatch(owner) ||
        !_repoPattern.hasMatch(repo) ||
        !_safePath(sourcePath) ||
        !RegExp(r'^[0-9a-f]{40}$', caseSensitive: false).hasMatch(commit)) {
      throw const FormatException('技能包来源字段无效。');
    }
    if (rawFiles is! List ||
        rawFiles.isEmpty ||
        rawFiles.length > maxSkillPackFiles) {
      throw const FormatException('技能包文件清单超出限制。');
    }
    final files = <SkillResourceFile>[];
    final seen = <String>{};
    var totalBytes = 0;
    for (final raw in rawFiles) {
      final allowed = backup
          ? const {'path', 'content', 'sha256'}
          : const {'path', 'encoding', 'content', 'sha256'};
      final file = _strictMap(raw, allowed);
      final path = _string(file, 'path', 500);
      final normalized = path.toLowerCase();
      if (!_safePath(path) ||
          path.contains('/') && path.split('/').any((part) => part.isEmpty) ||
          const {'pack.json', 'usage.json'}.contains(normalized) ||
          !_supportedExtension(path) ||
          !seen.add(normalized)) {
        throw const FormatException('技能包路径或文件类型无效。');
      }
      final encoded = _string(file, 'content', maxSkillPackFileBytes * 2);
      final Uint8List bytes;
      if (backup || file['encoding'] == 'base64') {
        try {
          bytes = Uint8List.fromList(base64Decode(encoded));
        } on FormatException {
          throw const FormatException('技能包文件编码无效。');
        }
        if (base64Encode(bytes) != encoded.replaceAll(RegExp(r'\s'), '')) {
          throw const FormatException('技能包 Base64 非规范编码。');
        }
      } else if (file['encoding'] == 'utf8') {
        bytes = Uint8List.fromList(utf8.encode(encoded));
      } else {
        throw const FormatException('技能包文件编码类型无效。');
      }
      if (bytes.length > maxSkillPackFileBytes ||
          (!_assetExtension(path) && bytes.contains(0))) {
        throw const FormatException('技能包文件大小或内容无效。');
      }
      final digest = sha256.convert(bytes).toString();
      if (file['sha256'] != digest) {
        throw const FormatException('技能包文件摘要不匹配。');
      }
      totalBytes += bytes.length;
      if (totalBytes > maxSkillPackBytes) {
        throw const FormatException('技能包总大小超出限制。');
      }
      if (!_assetExtension(path)) {
        final text = utf8.decode(bytes, allowMalformed: false);
        if (const SearchSecretScanner()
            .containsSensitiveData(text, includeOpaqueTokens: true)) {
          throw const FormatException('技能包包含疑似凭据，已拒绝保存。');
        }
      }
      files.add(SkillResourceFile(path: path, bytes: bytes, sha256: digest));
    }
    files.sort((a, b) => a.path.compareTo(b.path));
    final skillFiles = files.where((file) => file.path == 'SKILL.md').toList();
    if (skillFiles.length != 1 || !skillFiles.single.isText) {
      throw const FormatException('技能包缺少 SKILL.md。');
    }
    final skillFile = skillFiles.single;
    final parsed = _parseSkillMarkdown(skillFile.text);
    _validateMarkdownReferences(files);
    final normalizedLicense =
        license.trim().isEmpty ? 'NOASSERTION' : license.trim();
    final packId = _contentId(owner, repo, sourcePath, commit, files);
    return SkillResourcePack(
      id: packId,
      owner: owner,
      repo: repo,
      sourcePath: sourcePath,
      commit: commit.toLowerCase(),
      license: normalizedLicense.isEmpty ? 'NOASSERTION' : normalizedLicense,
      licenseStatus: _knownLicenses.contains(normalizedLicense) &&
              (parsed.license == null || parsed.license == normalizedLicense)
          ? 'recognized'
          : 'unknown',
      applicability: parsed.compatibility ?? 'unspecified',
      requestedTools: parsed.requestedTools,
      validationStatus: 'imported_unverified',
      files: List.unmodifiable(files),
      name: parsed.name,
      description: parsed.description,
      domain: parsed.domain,
      instructions: parsed.instructions,
    );
  }

  static _SkillFrontmatter _parseSkillMarkdown(String source) {
    if (!source.startsWith('---\n') && !source.startsWith('---\r\n')) {
      throw const FormatException('SKILL.md 缺少 YAML frontmatter。');
    }
    final frontmatterStart = source.startsWith('---\r\n') ? 5 : 4;
    final closing = RegExp(r'\r?\n---\s*(?:\r?\n|$)')
        .firstMatch(source.substring(frontmatterStart));
    if (closing == null || closing.start > 16 * 1024) {
      throw const FormatException('SKILL.md frontmatter 不完整或过大。');
    }
    final frontmatter = source.substring(
      frontmatterStart,
      frontmatterStart + closing.start,
    );
    final yamlToken = RegExp(r'(?:^|[\s:,])(?:\*|&)[A-Za-z0-9_-]+');
    if (frontmatter
        .split(RegExp(r'\r?\n'))
        .any((line) => yamlToken.hasMatch(line))) {
      throw const FormatException('SKILL.md 不允许 YAML anchor 或 alias。');
    }
    final Object? decoded;
    try {
      decoded = loadYaml(frontmatter);
    } on YamlException {
      throw const FormatException('SKILL.md YAML 无法解析。');
    }
    if (decoded is! YamlMap) {
      throw const FormatException('SKILL.md YAML 必须是 object。');
    }
    final map = <String, Object?>{};
    for (final entry in decoded.entries) {
      if (entry.key is! String || !_frontmatterKeys.contains(entry.key)) {
        throw const FormatException('SKILL.md 包含不支持的 YAML 字段。');
      }
      map[entry.key as String] = entry.value;
    }
    final name = _frontmatterString(map['name'], 'name', 80);
    final description =
        _frontmatterString(map['description'], 'description', 1000);
    if (!_skillNamePattern.hasMatch(name)) {
      throw const FormatException('SKILL.md name 无效。');
    }
    final rawMetadata = map['metadata'];
    final metadata = <String, String>{};
    if (rawMetadata != null) {
      if (rawMetadata is! YamlMap || rawMetadata.length > 32) {
        throw const FormatException('SKILL.md metadata 无效。');
      }
      for (final entry in rawMetadata.entries) {
        if (entry.key is! String ||
            entry.value is! String ||
            (entry.value as String).length > 200) {
          throw const FormatException('SKILL.md metadata 只能包含短字符串。');
        }
        metadata[entry.key as String] = entry.value as String;
      }
    }
    final requestedTools = _requestedTools(map['allowed-tools']);
    final bodyStart = frontmatterStart + closing.end;
    final body = source.substring(bodyStart).trim();
    if (body.isEmpty || body.length > maxSkillPackFileBytes) {
      throw const FormatException('SKILL.md 正文为空或过大。');
    }
    return _SkillFrontmatter(
      name: name,
      description: description,
      license: map['license'] == null
          ? null
          : _frontmatterString(map['license'], 'license', 100),
      compatibility: map['compatibility'] == null
          ? null
          : _frontmatterString(map['compatibility'], 'compatibility', 500),
      requestedTools: requestedTools,
      domain: metadata['domain'] ?? 'github',
      instructions: body.split('\n').map((line) => line.trimRight()).toList(),
    );
  }

  static List<String> _requestedTools(Object? raw) {
    final values = raw is String
        ? raw.split(RegExp(r'\s+'))
        : raw is YamlList && raw.every((value) => value is String)
            ? raw.cast<String>()
            : raw == null
                ? const <String>[]
                : throw const FormatException('SKILL.md allowed-tools 格式无效。');
    if (values.length > 32 ||
        values.any((value) => value.trim().isEmpty || value.length > 120)) {
      throw const FormatException('SKILL.md allowed-tools 超出限制。');
    }
    return List.unmodifiable(values.map((value) => value.trim()));
  }

  static void _validateMarkdownReferences(List<SkillResourceFile> files) {
    final names = files.map((file) => file.path).toSet();
    for (final file
        in files.where((file) => file.path.toLowerCase().endsWith('.md'))) {
      final source = file.text;
      if (RegExp(r'\b(?:https?|file):\/\/', caseSensitive: false)
          .hasMatch(source)) {
        throw const FormatException('技能包 Markdown 不允许外部链接。');
      }
      final targets = <String>[
        ...RegExp(r'\]\(\s*<?([^\s)>]+)>?[^)]*\)')
            .allMatches(source)
            .map((match) => match[1]!),
        ...RegExp(r'^\s*\[[^\]]+\]:\s*<?([^\s>]+)>?', multiLine: true)
            .allMatches(source)
            .map((match) => match[1]!),
        ...RegExp(r'''\b(?:href|src)\s*=\s*["']([^"']+)["']''',
                caseSensitive: false)
            .allMatches(source)
            .map((match) => match[1]!),
      ];
      for (var target in targets) {
        if (target.startsWith('#')) continue;
        if (target.startsWith('/') ||
            target.contains('\\') ||
            RegExp(r'^(?:[a-z][a-z0-9+.-]*:|//)', caseSensitive: false)
                .hasMatch(target)) {
          throw const FormatException('技能包资源引用必须保持在包内。');
        }
        target = Uri.decodeComponent(target.split(RegExp(r'[?#]')).first);
        final resolved = _resolveRelative(file.path, target);
        if (resolved == null || !names.contains(resolved)) {
          throw const FormatException('技能包引用的资源不在文件清单中。');
        }
      }
    }
  }

  static String? _resolveRelative(String source, String target) {
    final parts = <String>[];
    parts.addAll(source.split('/')..removeLast());
    for (final part in target.split('/')) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        if (parts.isEmpty) return null;
        parts.removeLast();
      } else {
        parts.add(part);
      }
    }
    return parts.join('/');
  }

  static String _contentId(
    String owner,
    String repo,
    String sourcePath,
    String commit,
    List<SkillResourceFile> files,
  ) {
    final bytes = BytesBuilder(copy: false);
    bytes.add(utf8.encode('$owner/$repo/$sourcePath@$commit\u0000'));
    for (final file in files) {
      bytes
        ..add(utf8.encode(file.path))
        ..add(const [0])
        ..add(file.bytes)
        ..add(const [0xff]);
    }
    return sha256.convert(bytes.takeBytes()).toString();
  }

  static bool _sameStrings(List values, List<String> expected) =>
      values.length == expected.length &&
      List<String>.generate(values.length, (index) => values[index] as String)
              .join('\u0000') ==
          expected.join('\u0000');

  static bool _safePath(String path) =>
      path.isNotEmpty &&
      path.length <= 500 &&
      !path.startsWith('/') &&
      !path.contains('\\') &&
      !path.contains('%') &&
      !RegExp(r'[\u0000-\u001f\u007f]').hasMatch(path) &&
      path
          .split('/')
          .every((part) => part.isNotEmpty && part != '.' && part != '..');

  static bool _supportedExtension(String path) {
    final extension = path.contains('.')
        ? path.substring(path.lastIndexOf('.')).toLowerCase()
        : '';
    return textFileExtensions.contains(extension) ||
        assetFileExtensions.contains(extension);
  }

  static bool _assetExtension(String path) => assetFileExtensions
      .contains(path.substring(path.lastIndexOf('.')).toLowerCase());

  static String _string(Map<String, Object?> map, String key, int max) {
    final value = map[key];
    if (value is! String || value.isEmpty || value.length > max) {
      throw FormatException('技能包字段无效：$key');
    }
    return value;
  }

  static Map<String, Object?> _strictMap(Object? raw, Set<String> fields) {
    if (raw is! Map ||
        raw.keys.any((key) => key is! String || !fields.contains(key)) ||
        raw.keys.length != fields.length) {
      throw const FormatException('技能包字段不完整或包含未知字段。');
    }
    return raw.map((key, value) => MapEntry(key as String, value));
  }

  static String _frontmatterString(Object? raw, String name, int max) {
    if (raw is! String || raw.trim().isEmpty || raw.length > max) {
      throw FormatException('SKILL.md $name 无效。');
    }
    return raw.trim();
  }

  static const Set<String> _frontmatterKeys = {
    'name',
    'description',
    'license',
    'compatibility',
    'allowed-tools',
    'metadata',
  };
  static const Set<String> textFileExtensions = {
    '.md',
    '.txt',
    '.yaml',
    '.yml',
    '.json',
    '.sh',
    '.py',
    '.js',
    '.ts',
    '.dart',
    '.html',
    '.css',
    '.xml',
    '.toml',
    '.csv',
  };
  static const Set<String> assetFileExtensions = {
    '.png',
    '.jpg',
    '.jpeg',
    '.webp',
    '.gif',
  };
  static const Set<String> _knownLicenses = {
    'MIT',
    'Apache-2.0',
    'BSD-2-Clause',
    'BSD-3-Clause',
    'ISC',
    'GPL-2.0-only',
    'GPL-2.0-or-later',
    'GPL-3.0-only',
    'GPL-3.0-or-later',
    'LGPL-2.1-only',
    'LGPL-3.0-only',
    'MPL-2.0',
    'Unlicense',
  };
  static final RegExp _ownerPattern =
      RegExp(r'^[A-Za-z0-9](?:[A-Za-z0-9-]{0,98}[A-Za-z0-9])?$');
  static final RegExp _repoPattern =
      RegExp(r'^[A-Za-z0-9](?:[A-Za-z0-9_.-]{0,98}[A-Za-z0-9])?$');
  static final RegExp _skillNamePattern =
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9 _.-]{0,79}$');
}

class _SkillFrontmatter {
  final String name;
  final String description;
  final String? license;
  final String? compatibility;
  final List<String> requestedTools;
  final String domain;
  final List<String> instructions;

  const _SkillFrontmatter({
    required this.name,
    required this.description,
    required this.license,
    required this.compatibility,
    required this.requestedTools,
    required this.domain,
    required this.instructions,
  });
}

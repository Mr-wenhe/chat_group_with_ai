import 'dart:io';

import 'package:chat_group/features/web_search/security/search_secret_scanner.dart';

enum BackupScope { all, configurationOnly, conversation }

enum BackupKind { full, conversation }

enum RestoreConflictStrategy { emptyOnly, skipExisting, copyWithNewIds }

class BackupSelection {
  final BackupScope scope;
  final String? conversationId;

  const BackupSelection._(this.scope, this.conversationId);

  const BackupSelection.all() : this._(BackupScope.all, null);

  const BackupSelection.configurationOnly()
      : this._(BackupScope.configurationOnly, null);

  const BackupSelection.conversation(String conversationId)
      : this._(BackupScope.conversation, conversationId);
}

class BackupFileEntry {
  final int bytes;
  final String sha256;

  const BackupFileEntry({required this.bytes, required this.sha256});

  Map<String, dynamic> toJson() => {'bytes': bytes, 'sha256': sha256};

  factory BackupFileEntry.fromJson(Map<String, dynamic> json) =>
      BackupFileEntry(
        bytes: (json['bytes'] as num?)?.toInt() ?? -1,
        sha256: json['sha256']?.toString() ?? '',
      );
}

class BackupManifest {
  static const currentFormatVersion = 1;
  static const currentSchemaVersion = 2;
  static const supportedSchemaVersions = {1, 2};
  static const formatName = 'chat_group_backup';

  final int formatVersion;
  final int schemaVersion;
  final String appVersion;
  final DateTime createdAt;
  final BackupScope scope;
  final BackupKind backupKind;
  final bool includesGlobalData;
  final String? conversationId;
  final Map<String, int> counts;
  final Map<String, BackupFileEntry> files;
  final List<String> missingAttachments;
  final List<String> compatibilityData;

  const BackupManifest({
    required this.formatVersion,
    required this.schemaVersion,
    required this.appVersion,
    required this.createdAt,
    required this.scope,
    BackupKind? backupKind,
    bool? includesGlobalData,
    required this.counts,
    required this.files,
    required this.missingAttachments,
    List<String>? compatibilityData,
    this.conversationId,
  })  : backupKind = backupKind ??
            (scope == BackupScope.conversation
                ? BackupKind.conversation
                : BackupKind.full),
        includesGlobalData = includesGlobalData ?? false,
        compatibilityData = compatibilityData ?? const [];

  Map<String, dynamic> toJson() => {
        'format': formatName,
        'formatVersion': formatVersion,
        'schemaVersion': schemaVersion,
        'appVersion': appVersion,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'scope': scope.name,
        if (schemaVersion >= 2) 'backupKind': backupKind.name,
        if (schemaVersion >= 2) 'includesGlobalData': includesGlobalData,
        if (conversationId != null) 'conversationId': conversationId,
        'counts': counts,
        'files': files.map((key, value) => MapEntry(key, value.toJson())),
        'missingAttachments': missingAttachments,
        if (schemaVersion >= 2) 'compatibilityData': compatibilityData,
        'credentialsIncluded': false,
      };

  factory BackupManifest.fromJson(Map<String, dynamic> json) {
    if (json['format'] != formatName) {
      throw const FormatException('不是 Chat Group 备份文件');
    }
    final scopeName = json['scope']?.toString();
    final scope = BackupScope.values.firstWhere(
      (scope) => scope.name == scopeName,
      orElse: () => throw const FormatException('未知备份范围'),
    );
    final kindName = json['backupKind']?.toString();
    final backupKind = kindName == null
        ? (scope == BackupScope.conversation
            ? BackupKind.conversation
            : BackupKind.full)
        : BackupKind.values.firstWhere(
            (kind) => kind.name == kindName,
            orElse: () => throw const FormatException('未知备份类型'),
          );
    return BackupManifest(
      formatVersion: (json['formatVersion'] as num?)?.toInt() ?? -1,
      schemaVersion: (json['schemaVersion'] as num?)?.toInt() ?? -1,
      appVersion: json['appVersion']?.toString() ?? '',
      createdAt: DateTime.parse(json['createdAt']?.toString() ?? ''),
      scope: scope,
      backupKind: backupKind,
      includesGlobalData: json['includesGlobalData'] as bool? ??
          ((json['schemaVersion'] as num?)?.toInt() == 2 &&
              backupKind == BackupKind.full),
      conversationId: json['conversationId']?.toString(),
      counts: _intMap(json['counts']),
      files: _fileMap(json['files']),
      missingAttachments: (json['missingAttachments'] as List? ?? const [])
          .map((item) => item.toString())
          .toList(growable: false),
      compatibilityData: (json['compatibilityData'] as List? ?? const [])
          .map((item) => item.toString())
          .toList(growable: false),
    );
  }

  bool get isSupportedSchema => supportedSchemaVersions.contains(schemaVersion);

  static Map<String, int> _intMap(Object? value) =>
      Map<String, dynamic>.from(value as Map? ?? const {})
          .map((key, value) => MapEntry(key, (value as num).toInt()));

  static Map<String, BackupFileEntry> _fileMap(Object? value) =>
      Map<String, dynamic>.from(value as Map? ?? const {}).map(
        (key, value) => MapEntry(
          key,
          BackupFileEntry.fromJson(Map<String, dynamic>.from(value as Map)),
        ),
      );
}

class BackupPreview {
  final BackupManifest manifest;
  final int packageBytes;
  final int attachmentCount;
  final int credentialsToRebind;
  final int conflicts;
  final bool checksumsValid;

  const BackupPreview({
    required this.manifest,
    required this.packageBytes,
    required this.attachmentCount,
    required this.credentialsToRebind,
    required this.conflicts,
    required this.checksumsValid,
  });
}

class PreparedBackup {
  final BackupPreview preview;
  final Directory stagingDirectory;

  /// The validated staged payload produced during inspection.
  ///
  /// Inspection already parses every staged JSON file to build the preview.
  /// Keeping that object here lets restore reuse the validated payload instead
  /// of parsing the same files a second time.  The type remains [Object] to
  /// keep this model independent from the staged-data implementation.
  final Object? validatedData;

  const PreparedBackup({
    required this.preview,
    required this.stagingDirectory,
    this.validatedData,
  });

  BackupManifest get manifest => preview.manifest;

  Future<void> dispose() async {
    await _deleteTreeNoFollow(stagingDirectory);
  }
}

Future<void> _deleteTreeNoFollow(FileSystemEntity entity) async {
  final type = await FileSystemEntity.type(entity.path, followLinks: false);
  if (type == FileSystemEntityType.notFound) return;
  if (type != FileSystemEntityType.directory) {
    await entity.delete();
    return;
  }
  await for (final child in Directory(entity.path).list(followLinks: false)) {
    await _deleteTreeNoFollow(child);
  }
  await entity.delete();
}

class BackupExportResult {
  final File file;
  final BackupManifest manifest;

  const BackupExportResult({required this.file, required this.manifest});
}

class BackupEstimate {
  final Map<String, int> counts;
  final int attachmentBytes;
  final int attachmentCount;
  final int missingAttachments;

  const BackupEstimate({
    required this.counts,
    required this.attachmentBytes,
    required this.attachmentCount,
    required this.missingAttachments,
  });
}

class RestoreReport {
  final Map<String, int> inserted;
  final Map<String, int> skipped;
  final Map<String, int> remapped;
  final List<String> errors;

  const RestoreReport({
    required this.inserted,
    required this.skipped,
    required this.remapped,
    this.errors = const [],
  });
}

class BackupException implements Exception {
  final String message;

  const BackupException(this.message);

  @override
  String toString() => message;
}

/// Keeps OS/provider error details useful without persisting credentials,
/// URLs, or device-local paths in a backup/restore diagnostic.
String sanitizeBackupError(Object? error) {
  final raw = error?.toString().trim() ?? '';
  if (raw.isEmpty) return '备份操作失败';
  var safe = const SearchSecretScanner().redact(
    raw,
    includeOpaqueTokens: true,
  );
  safe = safe.replaceAll(
    RegExp(r'https?://[^\s,;）)]+', caseSensitive: false),
    '[外部地址]',
  );
  safe = safe.replaceAll(
    RegExp(
      r'(?:(?:[A-Za-z]:[\\/])|(?:\\\\|//)|/)[^\s,;）)]*',
    ),
    '[本地路径]',
  );
  safe = safe.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (safe.isEmpty) return '备份操作失败';
  const maximum = 600;
  return safe.length <= maximum ? safe : '${safe.substring(0, maximum - 1)}…';
}

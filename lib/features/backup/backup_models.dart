import 'dart:io';

enum BackupScope { all, configurationOnly, conversation }

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
  static const currentSchemaVersion = 1;
  static const formatName = 'chat_group_backup';

  final int formatVersion;
  final int schemaVersion;
  final String appVersion;
  final DateTime createdAt;
  final BackupScope scope;
  final String? conversationId;
  final Map<String, int> counts;
  final Map<String, BackupFileEntry> files;
  final List<String> missingAttachments;

  const BackupManifest({
    required this.formatVersion,
    required this.schemaVersion,
    required this.appVersion,
    required this.createdAt,
    required this.scope,
    required this.counts,
    required this.files,
    required this.missingAttachments,
    this.conversationId,
  });

  Map<String, dynamic> toJson() => {
        'format': formatName,
        'formatVersion': formatVersion,
        'schemaVersion': schemaVersion,
        'appVersion': appVersion,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'scope': scope.name,
        if (conversationId != null) 'conversationId': conversationId,
        'counts': counts,
        'files': files.map((key, value) => MapEntry(key, value.toJson())),
        'missingAttachments': missingAttachments,
        'credentialsIncluded': false,
      };

  factory BackupManifest.fromJson(Map<String, dynamic> json) {
    if (json['format'] != formatName) {
      throw const FormatException('不是 Chat Group 备份文件');
    }
    final scopeName = json['scope']?.toString();
    return BackupManifest(
      formatVersion: (json['formatVersion'] as num?)?.toInt() ?? -1,
      schemaVersion: (json['schemaVersion'] as num?)?.toInt() ?? -1,
      appVersion: json['appVersion']?.toString() ?? '',
      createdAt: DateTime.parse(json['createdAt']?.toString() ?? ''),
      scope: BackupScope.values.firstWhere(
        (scope) => scope.name == scopeName,
        orElse: () => throw const FormatException('未知备份范围'),
      ),
      conversationId: json['conversationId']?.toString(),
      counts: _intMap(json['counts']),
      files: _fileMap(json['files']),
      missingAttachments: (json['missingAttachments'] as List? ?? const [])
          .map((item) => item.toString())
          .toList(growable: false),
    );
  }

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

  const PreparedBackup({
    required this.preview,
    required this.stagingDirectory,
  });

  BackupManifest get manifest => preview.manifest;

  Future<void> dispose() async {
    if (await stagingDirectory.exists()) {
      await stagingDirectory.delete(recursive: true);
    }
  }
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

import 'dart:convert';

import 'work_change_plan.dart';

/// Lifecycle stored in a task snapshot manifest.
enum WorkSnapshotTaskStatus {
  active,
  completed,
  failed,
  cancelled,
  partiallyCompleted,
  undone,
  partiallyUndone,
}

/// One mutation's pre-image and post-condition.
///
/// The manifest intentionally stores metadata and relative backup names only;
/// file contents remain in the sibling backup files and credentials are never
/// copied into either representation.
class WorkSnapshotAction {
  final int sequence;
  final WorkChangeActionType actionType;
  final String originalPath;
  final String? targetPath;
  final DateTime? mtime;
  final int? size;
  final String? sha256;
  final String? backupRelativePath;
  final bool existedBefore;
  final DateTime? postMtime;
  final int? postSize;
  final String? postSha256;
  final bool completed;
  final bool undone;
  final String? failureReason;

  const WorkSnapshotAction({
    required this.sequence,
    required this.actionType,
    required this.originalPath,
    required this.targetPath,
    required this.mtime,
    required this.size,
    required this.sha256,
    required this.backupRelativePath,
    required this.existedBefore,
    required this.postMtime,
    required this.postSize,
    required this.postSha256,
    required this.completed,
    required this.undone,
    this.failureReason,
  });

  WorkSnapshotAction copyWith({
    DateTime? mtime,
    int? size,
    String? sha256,
    String? backupRelativePath,
    bool? existedBefore,
    DateTime? postMtime,
    int? postSize,
    String? postSha256,
    bool? completed,
    bool? undone,
    String? failureReason,
    bool clearFailureReason = false,
  }) {
    return WorkSnapshotAction(
      sequence: sequence,
      actionType: actionType,
      originalPath: originalPath,
      targetPath: targetPath,
      mtime: mtime ?? this.mtime,
      size: size ?? this.size,
      sha256: sha256 ?? this.sha256,
      backupRelativePath: backupRelativePath ?? this.backupRelativePath,
      existedBefore: existedBefore ?? this.existedBefore,
      postMtime: postMtime ?? this.postMtime,
      postSize: postSize ?? this.postSize,
      postSha256: postSha256 ?? this.postSha256,
      completed: completed ?? this.completed,
      undone: undone ?? this.undone,
      failureReason:
          clearFailureReason ? null : failureReason ?? this.failureReason,
    );
  }

  Map<String, dynamic> toJson() => {
        'sequence': sequence,
        'actionSequence': sequence,
        'action': actionType.wireName,
        'actionType': actionType.wireName,
        'originalPath': originalPath,
        'targetPath': targetPath,
        'mtime': mtime?.toUtc().toIso8601String(),
        'mtimeMs': mtime?.millisecondsSinceEpoch,
        'size': size,
        'sha256': sha256,
        'backupRelativePath': backupRelativePath,
        'existedBefore': existedBefore,
        'postMtime': postMtime?.toUtc().toIso8601String(),
        'postSize': postSize,
        'postSha256': postSha256,
        'completed': completed,
        'undone': undone,
        'failureReason': failureReason,
      };

  factory WorkSnapshotAction.fromJson(Map<String, dynamic> json) {
    final sequence = _integer(
      json['sequence'] ?? json['actionSequence'],
      'sequence',
    );
    if (sequence <= 0) throw const FormatException('快照动作序号无效');
    final action = json['action'] ?? json['actionType'];
    final rawOriginalPath = json['originalPath'];
    if (action is! String ||
        rawOriginalPath is! String ||
        rawOriginalPath.isEmpty) {
      throw const FormatException('快照动作路径或类型无效');
    }
    late final String originalPath;
    try {
      originalPath = normalizeWorkAbsolutePath(rawOriginalPath);
    } on Object {
      throw const FormatException('快照原路径必须是绝对路径');
    }
    final target = json['targetPath'];
    late final String? targetPath;
    if (target == null) {
      targetPath = null;
    } else if (target is String && target.isNotEmpty) {
      try {
        targetPath = normalizeWorkAbsolutePath(target);
      } on Object {
        throw const FormatException('快照目标路径必须是绝对路径');
      }
    } else {
      throw const FormatException('快照目标路径无效');
    }
    final mtime = _date(json['mtime'] ?? json['mtimeMs']);
    final size = json['size'];
    if (size != null && (size is! num || size < 0)) {
      throw const FormatException('快照文件大小无效');
    }
    final sha = _optionalSha(json['sha256']);
    final postMtime = _date(json['postMtime']);
    final postSize = json['postSize'];
    if (postSize != null && (postSize is! num || postSize < 0)) {
      throw const FormatException('快照完成文件大小无效');
    }
    final postSha = _optionalSha(json['postSha256']);
    final backup = json['backupRelativePath'];
    if (backup != null && (backup is! String || backup.trim().isEmpty)) {
      throw const FormatException('快照备份路径无效');
    }
    return WorkSnapshotAction(
      sequence: sequence,
      actionType: WorkChangeActionType.fromWire(action),
      originalPath: originalPath,
      targetPath: targetPath,
      mtime: mtime,
      size: size is num ? size.toInt() : null,
      sha256: sha,
      backupRelativePath: backup as String?,
      existedBefore: json['existedBefore'] == true,
      postMtime: postMtime,
      postSize: postSize is num ? postSize.toInt() : null,
      postSha256: postSha,
      completed: json['completed'] == true,
      undone: json['undone'] == true,
      failureReason: json['failureReason'] is String
          ? json['failureReason'] as String
          : null,
    );
  }
}

/// Durable task-level snapshot index.
class WorkSnapshotManifest {
  static const int currentVersion = 1;

  final int version;
  final String taskId;
  final DateTime createdAt;
  final DateTime updatedAt;
  final WorkSnapshotTaskStatus taskStatus;
  final List<WorkSnapshotAction> actions;

  WorkSnapshotManifest({
    this.version = currentVersion,
    required this.taskId,
    required this.createdAt,
    required this.updatedAt,
    required this.taskStatus,
    required List<WorkSnapshotAction> actions,
  }) : actions = List.unmodifiable(actions);

  factory WorkSnapshotManifest.empty(String taskId, DateTime now) {
    return WorkSnapshotManifest(
      taskId: taskId,
      createdAt: now.toUtc(),
      updatedAt: now.toUtc(),
      taskStatus: WorkSnapshotTaskStatus.active,
      actions: const [],
    );
  }

  WorkSnapshotManifest copyWith({
    DateTime? updatedAt,
    WorkSnapshotTaskStatus? taskStatus,
    List<WorkSnapshotAction>? actions,
  }) {
    return WorkSnapshotManifest(
      version: version,
      taskId: taskId,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      taskStatus: taskStatus ?? this.taskStatus,
      actions: actions ?? this.actions,
    );
  }

  Map<String, dynamic> toJson() => {
        'version': version,
        'taskId': taskId,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'updatedAt': updatedAt.toUtc().toIso8601String(),
        'taskStatus': taskStatus.name,
        'actions': actions.map((action) => action.toJson()).toList(),
      };

  String toJsonString() => jsonEncode(toJson());

  factory WorkSnapshotManifest.fromJson(Map<String, dynamic> json) {
    final version = _integer(json['version'], 'version');
    if (version != currentVersion) {
      throw FormatException('不支持的快照版本：$version');
    }
    final taskId = json['taskId'];
    if (taskId is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(taskId)) {
      throw const FormatException('快照任务 ID 无效');
    }
    final createdAt = _requiredDate(json['createdAt'], 'createdAt');
    final updatedAt = _requiredDate(json['updatedAt'], 'updatedAt');
    final status = json['taskStatus'];
    if (status is! String) throw const FormatException('快照任务状态无效');
    final parsedStatus = WorkSnapshotTaskStatus.values.where(
      (item) => item.name == status,
    );
    if (parsedStatus.isEmpty) throw const FormatException('快照任务状态无效');
    final rawActions = json['actions'];
    if (rawActions is! List) throw const FormatException('快照动作列表无效');
    final actions = rawActions.map((item) {
      if (item is! Map) throw const FormatException('快照动作格式无效');
      return WorkSnapshotAction.fromJson(Map<String, dynamic>.from(item));
    }).toList(growable: false);
    for (var index = 1; index < actions.length; index++) {
      if (actions[index - 1].sequence >= actions[index].sequence) {
        throw const FormatException('快照动作序号必须递增');
      }
    }
    return WorkSnapshotManifest(
      version: version,
      taskId: taskId,
      createdAt: createdAt,
      updatedAt: updatedAt,
      taskStatus: parsedStatus.single,
      actions: actions,
    );
  }

  factory WorkSnapshotManifest.fromJsonString(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) throw const FormatException('快照 manifest 必须是对象');
    return WorkSnapshotManifest.fromJson(Map<String, dynamic>.from(decoded));
  }
}

int _integer(Object? value, String key) {
  if (value is int) return value;
  if (value is num && value == value.roundToDouble()) return value.toInt();
  throw FormatException('字段 $key 必须是整数');
}

DateTime? _date(Object? value) {
  if (value == null) return null;
  if (value is num && value == value.roundToDouble()) {
    return DateTime.fromMillisecondsSinceEpoch(value.toInt(), isUtc: true);
  }
  if (value is! String) throw const FormatException('快照时间格式无效');
  final parsed = DateTime.tryParse(value);
  if (parsed == null) throw const FormatException('快照时间格式无效');
  return parsed.toUtc();
}

DateTime _requiredDate(Object? value, String key) {
  final parsed = _date(value);
  if (parsed == null) throw FormatException('缺少快照时间：$key');
  return parsed;
}

String? _optionalSha(Object? value) {
  if (value == null) return null;
  if (value is! String || !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(value)) {
    throw const FormatException('快照 SHA-256 无效');
  }
  return value.toLowerCase();
}

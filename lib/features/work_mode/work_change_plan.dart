import 'dart:convert';

export 'work_change_policy.dart';

/// The mutation kinds understood by the task-level approval boundary.
enum WorkChangeActionType {
  create('create'),
  modify('modify'),
  patch('patch'),
  rename('rename'),
  delete('delete'),
  command('command');

  final String wireName;
  const WorkChangeActionType(this.wireName);

  static WorkChangeActionType fromWire(String value) {
    return values.firstWhere(
      (item) => item.wireName == value,
      orElse: () => throw ArgumentError('未知的变更动作：$value'),
    );
  }

  String get displayName => switch (this) {
        WorkChangeActionType.create => '创建文件',
        WorkChangeActionType.modify => '修改文件',
        WorkChangeActionType.patch => '应用局部补丁',
        WorkChangeActionType.rename => '重命名路径',
        WorkChangeActionType.delete => '删除文件（目录暂未开放）',
        WorkChangeActionType.command => '执行状态变更命令',
      };
}

/// Structured command impact information used when a command cannot enumerate
/// every file it may touch. The executable is intentionally kept separate from
/// the arguments so the approval copy cannot hide an opaque shell string.
class WorkChangeCommand {
  final String executable;
  final List<String> arguments;
  final String workingDirectory;
  final List<String> knownFiles;
  final List<String> possibleDirectories;
  final bool impactUncertain;

  const WorkChangeCommand({
    required this.executable,
    required this.arguments,
    required this.workingDirectory,
    required this.knownFiles,
    required this.possibleDirectories,
    required this.impactUncertain,
  });

  Map<String, dynamic> toJson() => {
        'executable': executable,
        'arguments': List<String>.unmodifiable(arguments),
        'workingDirectory': workingDirectory,
        'knownFiles': List<String>.unmodifiable(knownFiles),
        'possibleDirectories': List<String>.unmodifiable(possibleDirectories),
        'impactUncertain': impactUncertain,
      };

  factory WorkChangeCommand.fromJson(Map<String, dynamic> json) {
    return WorkChangeCommand(
      executable: _requiredString(json, 'executable'),
      arguments: _stringList(json['arguments'], 'arguments'),
      workingDirectory: normalizeWorkAbsolutePath(
        _requiredString(json, 'workingDirectory'),
      ),
      knownFiles: _normalizePathList(json['knownFiles'], 'knownFiles'),
      possibleDirectories: _normalizePathList(
        json['possibleDirectories'],
        'possibleDirectories',
      ),
      impactUncertain: json['impactUncertain'] == true,
    );
  }
}

// ponytail: Keep planning, scope and policy as a small pure boundary. The
// production executor and snapshot store consume these objects, but this
// layer itself still performs no I/O.
/// A normalized, reviewable description of one task mutation.
///
/// This is a planning object only. It contains no executor and deliberately
/// cannot perform file or process I/O.
class WorkChangePlan {
  final String taskId;
  final WorkChangeActionType actionType;
  final List<String> exactPaths;
  final List<String> knownAffectedDirectories;
  final int estimatedBytes;
  final bool snapshotAvailable;
  final bool reversible;
  final WorkChangeCommand? command;
  final String? commandReason;
  final String riskReason;

  WorkChangePlan({
    required this.taskId,
    required this.actionType,
    required List<String> exactPaths,
    required List<String> knownAffectedDirectories,
    required this.estimatedBytes,
    required this.snapshotAvailable,
    required this.reversible,
    WorkChangeCommand? command,
    String? commandReason,
    required this.riskReason,
  })  : exactPaths = _normalizePathList(exactPaths, 'exactPaths'),
        knownAffectedDirectories = _normalizePathList(
          knownAffectedDirectories,
          'knownAffectedDirectories',
        ),
        command = command == null ? null : _normalizeCommand(command),
        commandReason = actionType == WorkChangeActionType.command
            ? commandReason ?? riskReason
            : commandReason {
    _validatePlan(
      taskId: taskId,
      actionType: actionType,
      exactPaths: this.exactPaths,
      knownAffectedDirectories: this.knownAffectedDirectories,
      estimatedBytes: estimatedBytes,
      command: this.command,
      commandReason: commandReason,
      riskReason: riskReason,
    );
  }

  /// Convenience flag used by policy and the approval copy.
  bool get impactUncertain => command?.impactUncertain ?? false;

  String get effectiveCommandReason => commandReason ?? riskReason;

  Map<String, dynamic> toJson() => {
        'taskId': taskId,
        'actionType': actionType.wireName,
        'exactPaths': exactPaths,
        'knownAffectedDirectories': knownAffectedDirectories,
        'estimatedBytes': estimatedBytes,
        'snapshotAvailable': snapshotAvailable,
        'reversible': reversible,
        'command': command?.toJson(),
        'impactUncertain': impactUncertain,
        'commandReason': commandReason,
        'riskReason': riskReason,
      };

  String toJsonString() => jsonEncode(toJson());

  factory WorkChangePlan.fromJson(Map<String, dynamic> json) {
    final commandJson = json['command'];
    if (commandJson != null && commandJson is! Map) {
      throw const FormatException('command 必须是 JSON 对象或 null');
    }
    return WorkChangePlan(
      taskId: _requiredString(json, 'taskId'),
      actionType: WorkChangeActionType.fromWire(
        _requiredString(json, 'actionType'),
      ),
      exactPaths: _pathListFromJson(json['exactPaths'], 'exactPaths'),
      knownAffectedDirectories: _pathListFromJson(
        json['knownAffectedDirectories'],
        'knownAffectedDirectories',
      ),
      estimatedBytes: _intFromJson(json['estimatedBytes'], 'estimatedBytes'),
      snapshotAvailable: json['snapshotAvailable'] == true,
      reversible: json['reversible'] == true,
      commandReason: json['commandReason'] as String?,
      command: commandJson == null
          ? null
          : WorkChangeCommand.fromJson(
              Map<String, dynamic>.from(commandJson),
            ),
      riskReason: _requiredString(json, 'riskReason'),
    );
  }

  factory WorkChangePlan.fromJsonString(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) throw const FormatException('变更计划必须是 JSON 对象');
    return WorkChangePlan.fromJson(Map<String, dynamic>.from(decoded));
  }
}

void _validatePlan({
  required String taskId,
  required WorkChangeActionType actionType,
  required List<String> exactPaths,
  required List<String> knownAffectedDirectories,
  required int estimatedBytes,
  required WorkChangeCommand? command,
  required String? commandReason,
  required String riskReason,
}) {
  if (taskId.trim().isEmpty) {
    throw ArgumentError.value(taskId, 'taskId', '任务 ID 不能为空');
  }
  if (estimatedBytes < 0) {
    throw ArgumentError.value(
      estimatedBytes,
      'estimatedBytes',
      '预计字节数不能为负数',
    );
  }
  if (riskReason.trim().isEmpty) {
    throw ArgumentError.value(riskReason, 'riskReason', '必须说明风险理由');
  }
  if (actionType == WorkChangeActionType.command && command == null) {
    throw ArgumentError('命令变更计划必须提供结构化 command 信息');
  }
  if (actionType != WorkChangeActionType.command && command != null) {
    throw ArgumentError('非命令变更计划不能携带 command 信息');
  }
  if (actionType != WorkChangeActionType.command && commandReason != null) {
    throw ArgumentError('非命令变更计划不能携带 commandReason');
  }
  if (actionType != WorkChangeActionType.command && exactPaths.isEmpty) {
    throw ArgumentError('文件变更计划必须列出至少一个精确路径');
  }
  if (actionType != WorkChangeActionType.command) return;

  final commandValue = command!;
  if (commandValue.executable.trim().isEmpty) {
    throw ArgumentError('结构化命令必须提供 executable');
  }
  final hasImpactEntry = exactPaths.isNotEmpty ||
      knownAffectedDirectories.isNotEmpty ||
      commandValue.knownFiles.isNotEmpty ||
      commandValue.possibleDirectories.isNotEmpty;
  if (!hasImpactEntry) {
    throw ArgumentError('命令变更计划必须列出已知文件或可能目录');
  }
}

String _requiredString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('缺少字符串字段：$key');
  }
  return value;
}

int _intFromJson(Object? value, String key) {
  if (value is int) return value;
  if (value is num && value == value.roundToDouble()) return value.toInt();
  throw FormatException('字段 $key 必须是整数');
}

List<String> _stringList(Object? value, String key) {
  if (value is! List) throw FormatException('字段 $key 必须是数组');
  return value.map((item) => item.toString()).toList(growable: false);
}

List<String> _pathListFromJson(Object? value, String key) {
  return _normalizePathList(value, key);
}

List<String> _normalizePathList(Object? value, String key) {
  final values = value is List
      ? value.map((item) => item.toString()).toList()
      : value is Iterable
          ? value.map((item) => item.toString()).toList()
          : throw FormatException('字段 $key 必须是路径数组');
  final result = <String>[];
  final seen = <String>{};
  for (final item in values) {
    final path = normalizeWorkAbsolutePath(item);
    if (seen.add(workPathKey(path))) result.add(path);
  }
  return List<String>.unmodifiable(result);
}

String normalizeWorkAbsolutePath(String raw) {
  final value = raw.trim();
  if (RegExp(r'[\u0000-\u001f\u007f]').hasMatch(value)) {
    throw ArgumentError.value(raw, 'path', '路径包含不允许的字符');
  }
  if (!_isAbsoluteWorkPath(value)) {
    throw ArgumentError.value(raw, 'path', '必须是精确绝对路径');
  }
  final slashValue = value.replaceAll('\\', '/');
  final isDrive = RegExp(r'^[A-Za-z]:/').hasMatch(slashValue);
  final isUnc = slashValue.startsWith('//');
  final prefix = isDrive
      ? '${slashValue.substring(0, 2)}/'
      : isUnc
          ? '//'
          : '/';
  final remainder = isDrive
      ? slashValue.substring(3)
      : isUnc
          ? slashValue.substring(2)
          : slashValue.substring(1);
  final segments = <String>[];
  for (final segment in remainder.split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      if (segments.isEmpty) {
        throw ArgumentError.value(raw, 'path', '路径不能越过绝对路径根目录');
      }
      segments.removeLast();
      continue;
    }
    segments.add(segment);
  }
  return '$prefix${segments.join('/')}';
}

bool _isAbsoluteWorkPath(String value) {
  return value.startsWith('/') ||
      RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value) ||
      value.startsWith(r'\\');
}

String workPathKey(String path) {
  final normalized = normalizeWorkAbsolutePath(path);
  final windows = RegExp(r'^[A-Za-z]:/').hasMatch(normalized) ||
      normalized.startsWith('//');
  return windows ? normalized.toLowerCase() : normalized;
}

bool isWorkPathWithin(String candidate, String directory) {
  final candidateKey = workPathKey(candidate);
  final directoryKey = workPathKey(directory);
  if (candidateKey == directoryKey) return true;
  final prefix = directoryKey.endsWith('/') ? directoryKey : '$directoryKey/';
  return candidateKey.startsWith(prefix);
}

WorkChangeCommand _normalizeCommand(WorkChangeCommand command) {
  return WorkChangeCommand(
    executable: command.executable.trim(),
    arguments: List<String>.unmodifiable(command.arguments),
    workingDirectory: normalizeWorkAbsolutePath(command.workingDirectory),
    knownFiles: _normalizePathList(command.knownFiles, 'command.knownFiles'),
    possibleDirectories: _normalizePathList(
      command.possibleDirectories,
      'command.possibleDirectories',
    ),
    impactUncertain: command.impactUncertain,
  );
}

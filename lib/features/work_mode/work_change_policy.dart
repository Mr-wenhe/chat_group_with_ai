import 'dart:convert';

import 'work_change_plan.dart';

export 'work_change_plan.dart';

/// Whether an approval entry names one file or a directory impact boundary.
enum WorkApprovalScopePathKind {
  file('file'),
  directory('directory');

  final String wireName;
  const WorkApprovalScopePathKind(this.wireName);

  static WorkApprovalScopePathKind fromWire(String value) {
    return values.firstWhere(
      (item) => item.wireName == value,
      orElse: () => throw ArgumentError('未知的审批范围类型：$value'),
    );
  }
}

/// One explicit path entry in a task approval scope.
class WorkApprovalScopeEntry {
  final String path;
  final WorkApprovalScopePathKind kind;
  final Set<WorkChangeActionType> actions;

  const WorkApprovalScopeEntry({
    required this.path,
    required this.kind,
    required this.actions,
  });

  Map<String, dynamic> toJson() => {
        'path': path,
        'kind': kind.wireName,
        'actions': actions.map((item) => item.wireName).toList()..sort(),
      };
}

/// Task-scoped capability. There is no task-wide or wildcard permission.
class WorkApprovalScope {
  final String taskId;
  final List<WorkApprovalScopeEntry> entries;

  WorkApprovalScope({
    required this.taskId,
    required List<WorkApprovalScopeEntry> entries,
  }) : entries = _normalizeScopeEntries(entries) {
    if (taskId.trim().isEmpty) {
      throw ArgumentError.value(taskId, 'taskId', '任务 ID 不能为空');
    }
    if (this.entries.isEmpty) {
      throw ArgumentError('审批范围必须包含明确文件或目录');
    }
  }

  factory WorkApprovalScope.fromPlan(WorkChangePlan plan) {
    final entries = <WorkApprovalScopeEntry>[
      ...plan.exactPaths.map(
        (path) => WorkApprovalScopeEntry(
          path: path,
          kind: WorkApprovalScopePathKind.file,
          actions: {plan.actionType},
        ),
      ),
      if (plan.command != null)
        ...plan.command!.knownFiles.map(
          (path) => WorkApprovalScopeEntry(
            path: path,
            kind: WorkApprovalScopePathKind.file,
            actions: {plan.actionType},
          ),
        ),
      ...plan.knownAffectedDirectories.map(
        (path) => WorkApprovalScopeEntry(
          path: path,
          kind: WorkApprovalScopePathKind.directory,
          actions: {plan.actionType},
        ),
      ),
      if (plan.command != null)
        ...plan.command!.possibleDirectories.map(
          (path) => WorkApprovalScopeEntry(
            path: path,
            kind: WorkApprovalScopePathKind.directory,
            actions: {plan.actionType},
          ),
        ),
    ];
    return WorkApprovalScope(taskId: plan.taskId, entries: entries);
  }

  /// Every impact path must be covered by an explicitly approved entry.
  bool allows(WorkChangePlan plan) {
    if (taskId != plan.taskId) return false;
    final requiredPaths = <({String path, WorkApprovalScopePathKind kind})>[
      ...plan.exactPaths.map(
        (path) => (path: path, kind: WorkApprovalScopePathKind.file),
      ),
      if (plan.command != null)
        ...plan.command!.knownFiles.map(
          (path) => (path: path, kind: WorkApprovalScopePathKind.file),
        ),
      ...plan.knownAffectedDirectories.map(
        (path) => (path: path, kind: WorkApprovalScopePathKind.directory),
      ),
      if (plan.command != null)
        ...plan.command!.possibleDirectories.map(
          (path) => (path: path, kind: WorkApprovalScopePathKind.directory),
        ),
    ];
    return requiredPaths.every(
      (required) => entries.any(
        (entry) =>
            entry.actions.contains(plan.actionType) &&
            _scopeEntryCovers(entry, required.path, required.kind),
      ),
    );
  }

  Map<String, dynamic> toJson() => {
        'taskId': taskId,
        'entries': entries.map((entry) => entry.toJson()).toList(),
      };

  String toJsonString() => jsonEncode(toJson());

  factory WorkApprovalScope.fromJson(Map<String, dynamic> json) {
    final rawEntries = json['entries'];
    if (rawEntries is! List) {
      throw const FormatException('审批范围缺少 entries 数组');
    }
    return WorkApprovalScope(
      taskId: _requiredScopeString(json, 'taskId'),
      entries: rawEntries.map((item) {
        if (item is! Map) throw const FormatException('审批范围条目格式错误');
        final entry = Map<String, dynamic>.from(item);
        final rawActions = entry['actions'];
        if (rawActions is! List) {
          throw const FormatException('审批范围条目缺少 actions 数组');
        }
        return WorkApprovalScopeEntry(
          path: _requiredScopeString(entry, 'path'),
          kind: WorkApprovalScopePathKind.fromWire(
            _requiredScopeString(entry, 'kind'),
          ),
          actions: rawActions
              .map((action) => WorkChangeActionType.fromWire(action.toString()))
              .toSet(),
        );
      }).toList(),
    );
  }

  factory WorkApprovalScope.fromJsonString(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) throw const FormatException('审批范围必须是 JSON 对象');
    return WorkApprovalScope.fromJson(Map<String, dynamic>.from(decoded));
  }
}

/// Technical-design name retained as an alias for callers that use
/// `ApprovalScope` directly.
typedef ApprovalScope = WorkApprovalScope;

/// The prompt state produced by [WorkChangePolicy].
enum WorkChangeApprovalRequirement {
  none,
  initial,
  supplemental,
  alwaysConfirm,
}

/// User-controlled switch for ordinary create/modify style prompts.
class WorkChangePolicySettings {
  final bool confirmOrdinaryWrites;

  const WorkChangePolicySettings({this.confirmOrdinaryWrites = true});
}

/// Explainable policy result; callers decide whether/how to show the prompt.
class WorkChangePolicyResult {
  final WorkChangeApprovalRequirement requirement;
  final String reason;

  const WorkChangePolicyResult({
    required this.requirement,
    required this.reason,
  });

  bool get requiresPrompt => requirement != WorkChangeApprovalRequirement.none;
}

/// Single policy boundary for mutation prompts. It does not execute anything.
class WorkChangePolicy {
  const WorkChangePolicy._();

  static WorkChangePolicyResult evaluate({
    required WorkChangePlan plan,
    required WorkChangePolicySettings settings,
    WorkApprovalScope? scope,
  }) {
    if (plan.actionType == WorkChangeActionType.delete) {
      return const WorkChangePolicyResult(
        requirement: WorkChangeApprovalRequirement.alwaysConfirm,
        reason: '删除会移除文件；Stage 02 暂不支持目录删除，必须明确确认。',
      );
    }

    if (plan.actionType == WorkChangeActionType.command) {
      final reason = plan.impactUncertain
          ? '命令的影响范围不确定，必须确认已知文件和可能目录。'
          : '状态变更命令可能写入工作区或系统状态，必须明确确认。';
      return WorkChangePolicyResult(
        requirement: WorkChangeApprovalRequirement.alwaysConfirm,
        reason: reason,
      );
    }

    if ((plan.actionType == WorkChangeActionType.create ||
            plan.actionType == WorkChangeActionType.modify ||
            plan.actionType == WorkChangeActionType.patch ||
            plan.actionType == WorkChangeActionType.rename) &&
        (!plan.snapshotAvailable || !plan.reversible)) {
      return const WorkChangePolicyResult(
        requirement: WorkChangeApprovalRequirement.alwaysConfirm,
        reason: '该覆盖无法安全创建快照或撤销，必须再次确认。',
      );
    }

    if (scope?.allows(plan) == true) {
      return const WorkChangePolicyResult(
        requirement: WorkChangeApprovalRequirement.none,
        reason: '当前变更完全位于本任务已批准的明确路径范围内。',
      );
    }

    // Once a task has an explicit scope, expanding it is never silently
    // covered by the ordinary-write toggle; the user must approve the delta.
    if (scope?.taskId == plan.taskId) {
      return const WorkChangePolicyResult(
        requirement: WorkChangeApprovalRequirement.supplemental,
        reason: '本次计划包含此前未批准的新增文件或目录，需要补充审批。',
      );
    }

    if (!settings.confirmOrdinaryWrites) {
      return const WorkChangePolicyResult(
        requirement: WorkChangeApprovalRequirement.none,
        reason: '普通写入确认已在设置中关闭，且本次变更不属于强制确认项。',
      );
    }

    return const WorkChangePolicyResult(
      requirement: WorkChangeApprovalRequirement.initial,
      reason: '这是本任务首次进行普通写入，需要先确认具体影响范围。',
    );
  }
}

List<WorkApprovalScopeEntry> _normalizeScopeEntries(
  List<WorkApprovalScopeEntry> source,
) {
  final normalized = <WorkApprovalScopeEntry>[];
  final seen = <String>{};
  for (final entry in source) {
    final path = normalizeWorkAbsolutePath(entry.path);
    if (RegExp(r'[\*\?\[]').hasMatch(path)) {
      throw ArgumentError('审批范围不能使用通配符或任务全写权限');
    }
    if (entry.actions.isEmpty) {
      throw ArgumentError('审批范围条目必须声明允许的动作');
    }
    final actions = entry.actions.toSet();
    final key =
        '$path|${entry.kind.wireName}|${actions.map((e) => e.wireName).join(',')}';
    if (seen.add(key)) {
      normalized.add(
        WorkApprovalScopeEntry(
          path: path,
          kind: entry.kind,
          actions: actions,
        ),
      );
    }
  }
  return List<WorkApprovalScopeEntry>.unmodifiable(normalized);
}

bool _scopeEntryCovers(
  WorkApprovalScopeEntry entry,
  String requiredPath,
  WorkApprovalScopePathKind requiredKind,
) {
  if (entry.kind == WorkApprovalScopePathKind.file &&
      requiredKind == WorkApprovalScopePathKind.file) {
    return workPathKey(entry.path) == workPathKey(requiredPath);
  }
  if (entry.kind == WorkApprovalScopePathKind.directory &&
      requiredKind == WorkApprovalScopePathKind.directory) {
    return isWorkPathWithin(requiredPath, entry.path);
  }
  // An affected directory is metadata for directory-impact operations; it is
  // not silently widened into permission to write every file below it.
  return false;
}

String _requiredScopeString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('缺少字符串字段：$key');
  }
  return value;
}

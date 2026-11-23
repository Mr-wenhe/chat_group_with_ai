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

  /// Whether a command's impact is fully enumerated and already inside the
  /// task's approved scope, so running it again needs no new approval.
  ///
  /// This is the single judgement shared by the policy gate, the command
  /// runner's preflight and the command pipeline's no-undo checkpoint. Three
  /// separate copies used to decide whether a command was "already approved";
  /// any one of them answering "no" makes the user click again even though the
  /// path was accepted minutes ago.
  ///
  /// 判据必须是"命令自身能界住写入面"，不能只看规划器给的 `impactUncertain`：
  /// 那个字段由模型声明，而这里要回答的是"argv 是否完整枚举了这条命令会动
  /// 哪些东西"。`find . -name '*.dart' -delete` 的匹配集不在 argv 里，只要目录
  /// 已被批准，"批准这个目录可写"就会被当成"批准把这个目录删掉"。
  static bool commandCoveredByApprovedScope({
    required WorkChangePlan plan,
    required WorkApprovalScope? scope,
  }) {
    final command = plan.command;
    if (command == null || plan.impactUncertain) return false;
    if (!_commandImpactEnumerable(command)) return false;
    return scope?.allows(plan) == true;
  }

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
      // 用户在第一次批准时确认的是"这条路径可以写"，不是"这一次运行"。
      // 影响范围可完整枚举、且完全落在本任务已批准范围内时，再执行一次命令
      // 不该再要一次点击；否则模型每读一段、每改一处都要用户重新点一遍，
      // 一次普通文件修改会被拆成几十次审批（2026-10-23 现场：97 次审批、
      // 104 条重复提醒、407.98 万 token 仍未改完一个 HTML）。
      //
      // 删除、移动、权限、安装、下载落盘、提权与外部写入仍然每次单独确认：
      // 批准"这个目录可写"不等于批准"把这个目录里的东西搬走或删掉"，而且
      // 这些操作大多不可撤销。影响范围无法枚举的命令同样保持每次确认。
      if (commandCoveredByApprovedScope(plan: plan, scope: scope)) {
        return const WorkChangePolicyResult(
          requirement: WorkChangeApprovalRequirement.none,
          reason: '该命令的影响范围已在本任务已批准的路径范围内。',
        );
      }
      final reason = plan.impactUncertain
          ? '命令的影响范围不确定，必须确认已知文件和可能目录。'
          : plan.command != null && !_commandImpactEnumerable(plan.command!)
              ? '该命令的写入范围无法从参数完整枚举（例如 find -delete、'
                  '解释器脚本、打包解压、打补丁），必须每次单独确认。'
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
      reason: '本次变更不在本任务已批准的路径范围内，需要先确认具体影响范围。',
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

/// Commands whose approval is never inherited from a path scope.
///
/// Approving "this directory may be written" says nothing about removing,
/// moving, reinstalling, downloading over, or escalating through the files in
/// it, and those actions are typically not reversible. They therefore keep the
/// per-run confirmation even when every affected path is already approved.
///
/// Interpreters (`python3`, `sh`, `powershell`) are listed for the same reason:
/// nothing in the argv proves which files the script will touch, so their
/// declared impact cannot be trusted as the whole impact.
const Set<String> _standaloneCommandExecutables = <String>{
  'rm',
  'rmdir',
  'del',
  'erase',
  'unlink',
  'mv',
  'move',
  'rename',
  'ren',
  'dd',
  'tee',
  'chmod',
  'chown',
  'chgrp',
  'ln',
  'truncate',
  'install',
  'sudo',
  'su',
  'doas',
  'curl',
  'wget',
  'ssh',
  'scp',
  'sftp',
  'rsync',
  'git',
  'gh',
  'docker',
  'brew',
  'apt',
  'apt-get',
  'dnf',
  'yum',
  'pacman',
  'choco',
  'winget',
  'npm',
  'pnpm',
  'yarn',
  'bun',
  'pip',
  'pip3',
  'gem',
  'cargo',
  'go',
  'dart',
  'flutter',
  'python',
  'python3',
  'sh',
  'bash',
  'zsh',
  'powershell',
  'cmd',
};

bool _requiresStandaloneCommandApproval(WorkChangeCommand plan) {
  final executable = _commandExecutableName(plan);
  if (_standaloneCommandExecutables.contains(executable)) return true;
  final arguments = plan.arguments.map((item) => item.toLowerCase()).toList();
  return arguments.any(
    (argument) =>
        argument == '--force' ||
        argument == '-f' ||
        argument == '-rf' ||
        argument == '-fr' ||
        argument == '--in-place' ||
        argument.startsWith('--in-place=') ||
        argument == '-i.bak',
  );
}

/// Canonical executable name: lower-cased basename without a trailing `.exe`.
String _commandExecutableName(WorkChangeCommand command) {
  final raw = command.executable.trim().replaceAll('\\', '/');
  final basename = raw.split('/').last.toLowerCase();
  return basename.endsWith('.exe')
      ? basename.substring(0, basename.length - 4)
      : basename;
}

/// 写入面能由 argv 完整界住的命令。**白名单，不是黑名单。**
///
/// 判据的失败史就是它必须是白名单的理由：这里曾经只有可执行名黑名单
/// （rm/mv/dd/chmod/解释器…）加危险标志匹配，而黑名单永远漏项。
/// `find . -name '*.dart' -delete` 的可执行名是 `find`、危险标志一个都没有，
/// 规划器把它归到"本地变更"，于是只要目录已在批准范围内就免审批执行删除——
/// 用户批准的是"这个目录可以改"，不是"这个目录里的东西可以清掉"。
/// 同理 `xargs rm`、`tar -x`、`patch`、`unzip` 的影响都散在参数之外。
///
/// 只放三类：
/// - 只读命令：本身不写盘，argv 是否安全只取决于有没有 shell 元字符；
/// - `sed`：唯一允许直接改文件的可继承命令，且必须 `-i`、脚本不得写别的文件、
///   文件参数不得带通配符；
/// - 单目标写入：`cp` / `touch` / `mkdir`，写入目标就写在 argv 里。
const Set<String> _enumerableReadExecutables = <String>{
  'cat',
  'head',
  'tail',
  'wc',
  'sort',
  'uniq',
  'cut',
  'tr',
  'nl',
  'diff',
  'comm',
  'grep',
  'egrep',
  'fgrep',
  'rg',
  'fd',
  'find',
  'ls',
  'dir',
  'stat',
  'file',
  'pwd',
  'which',
  'where',
  'whoami',
  'uname',
  'basename',
  'dirname',
  'realpath',
  'jq',
};

const Set<String> _enumerableWriteExecutables = <String>{
  'touch',
  'mkdir',
  'cp',
  'copy',
};

/// Whether the command's own arguments bound everything it can write.
bool _commandImpactEnumerable(WorkChangeCommand command) {
  if (_requiresStandaloneCommandApproval(command)) return false;
  // A path-qualified executable (`/tmp/rg`) is not the utility it resembles.
  if (command.executable.contains('/') || command.executable.contains('\\')) {
    return false;
  }
  final executable = _commandExecutableName(command);
  if (executable == 'find' || executable == 'fd') {
    // `-delete` / `-exec` 作用在匹配集上，而匹配集不写在 argv 里。
    if (command.arguments.any(_hasMutationPredicate)) return false;
    return !_hasShellControlTokens(command.arguments);
  }
  if (executable == 'sed') return _isBoundedInPlaceSed(command.arguments);
  if (_enumerableReadExecutables.contains(executable) ||
      _enumerableWriteExecutables.contains(executable)) {
    return !_hasShellControlTokens(command.arguments);
  }
  return false;
}

/// 独立的 shell 控制词元：管道、重定向、串联、命令替换。
///
/// 只认独立的 argv 词元：`grep -nE "<section|</section>" file` 里的 `|` 是正则
/// 文本，把它当管道会让每一次只读检索都要审批（2026-10-23 现场：991 次）。
bool _hasShellControlTokens(List<String> arguments) {
  const control = <String>{
    '|',
    '|&',
    '||',
    '&&',
    ';',
    '&',
    '>',
    '>>',
    '<',
    '<<',
    '<<<',
    '2>',
    '2>>',
    '&>',
  };
  return arguments.any((raw) {
    final token = raw.trim();
    return control.contains(token) ||
        token.contains('`') ||
        token.contains(r'$(');
  });
}

bool _hasMutationPredicate(String raw) {
  const predicates = <String>{
    '-delete',
    '-exec',
    '-execdir',
    '-ok',
    '-okdir',
    '--exec',
    '--exec-batch',
    '-x',
    '-X',
  };
  return predicates.contains(raw.trim().toLowerCase());
}

/// `sed -i` 是唯一可以直接改文件的可继承命令，但只有这几种情形可继承：
/// 带 `-i`、脚本不含 `w`/`W`/`e`（会写 argv 之外的文件）、文件参数不带通配符
/// （一次编辑会扩散到 argv 没点名的文件，而审批范围只覆盖点名的那个）。
bool _isBoundedInPlaceSed(List<String> arguments) {
  var hasInPlace = false;
  var scriptSeen = false;
  final scripts = <String>[];
  final usesExplicitExpression = arguments.any((raw) {
    final lower = raw.toLowerCase();
    return lower == '-e' ||
        lower == '--expression' ||
        lower.startsWith('--expression=');
  });
  for (var index = 0; index < arguments.length; index++) {
    final raw = arguments[index];
    final lower = raw.toLowerCase();
    if (lower == '-i' ||
        lower == '--in-place' ||
        lower.startsWith('--in-place=') ||
        (lower.startsWith('-i') && !lower.startsWith('--'))) {
      hasInPlace = true;
      continue;
    }
    if (lower == '-e' || lower == '--expression') {
      if (index + 1 < arguments.length) {
        scripts.add(arguments[index + 1]);
        index++;
      }
      continue;
    }
    if (lower.startsWith('--expression=')) {
      scripts.add(raw.substring('--expression='.length));
      continue;
    }
    if (lower.startsWith('-')) continue;
    if (!usesExplicitExpression && !scriptSeen) {
      // sed 的第一个非选项参数是脚本，后续才是文件。
      scripts.add(raw);
      scriptSeen = true;
      continue;
    }
    if (RegExp(r'[*?\[]').hasMatch(raw)) return false;
  }
  if (!hasInPlace) return false;
  return !scripts.any(_sedScriptWritesElsewhere);
}

/// `w`/`W`/`e` 会把内容写到 argv 之外的位置；与规划器的判定保持一致。
bool _sedScriptWritesElsewhere(String script) {
  final normalized = script.toLowerCase().replaceAll('\r', '\n');
  return RegExp(r'(?:^|[;{}\n])\s*(?:(?:\d+|\$|/[^/\n]*/)\s*,?\s*)?'
          r'(?:(?:\d+|\$|/[^/\n]*/)\s*)?!?\s*[wWe](?:\s|$)')
      .hasMatch(normalized);
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

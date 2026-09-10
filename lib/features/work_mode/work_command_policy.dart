import 'dart:io';

import 'work_change_plan.dart';

/// Returns whether the user explicitly asked for a validation/build action.
///
/// Work-mode planning may propose a test or build, but it must not run one
/// until the user says so.  Keeping this parser in the command-policy module
/// lets both the command gate and the durable coordinator apply the same
/// wording rules when a paused task is resumed.
bool isExplicitWorkValidationRequest(String request) {
  // A paused task stores the original request together with the user's later
  // authorization as `用户明确要求：...`.  Evaluate that newest line on its
  // own so an earlier phrase such as “默认不要测试” cannot override the
  // explicit follow-up that is now being authorized.
  final explicitFollowUps = RegExp(
    r'用户明确要求\s*[:：]\s*([^\r\n]*)',
    caseSensitive: false,
  ).allMatches(request).toList(growable: false);
  if (explicitFollowUps.isNotEmpty) {
    return _isExplicitValidationPhrase(
      explicitFollowUps.last.group(1) ?? '',
    );
  }
  return _isExplicitValidationPhrase(request);
}

bool _isExplicitValidationPhrase(String request) {
  final validationTerms = RegExp(
    r'(flutter\s+(?:test|build|analyze)|\b(?:test|build|analyze|compile)\b|'
    r'测试|构建|分析|编译|运行(?:测试|构建|编译)|执行(?:测试|构建|编译))',
    caseSensitive: false,
  ).allMatches(request);
  for (final match in validationTerms) {
    final prefix = request.substring(0, match.start);
    final context =
        prefix.length <= 40 ? prefix : prefix.substring(prefix.length - 40);
    final negated = RegExp(
      r'(?:默认\s*)?(不要|无需|不需要|不用|不必|不运行|不执行|不做|不)\s*'
      r'(?:再|去|进行|执行|跑|运行)?\s*(?:flutter\s+)?$',
      caseSensitive: false,
    ).hasMatch(context);
    if (!negated) return true;
  }
  return false;
}

/// The only impact classes a local command may claim.
enum WorkCommandImpact {
  readOnly('readOnly'),
  localMutation('localMutation'),
  externalMutation('externalMutation'),
  impactUncertain('impactUncertain');

  final String wireName;
  const WorkCommandImpact(this.wireName);

  bool get isMutation => this != WorkCommandImpact.readOnly;

  static WorkCommandImpact fromWire(Object? value) {
    for (final item in values) {
      if (item.wireName == value) return item;
    }
    throw ArgumentError.value(value, 'declaredImpact', '命令影响类型无效');
  }
}

/// Structured command input. It is deliberately not a shell string.
class WorkCommand {
  final String executable;
  final List<String> arguments;
  final String workingDirectory;
  final List<String> declaredImpact;

  WorkCommand({
    required String executable,
    List<String> arguments = const [],
    required String workingDirectory,
    required List<String> declaredImpact,
  })  : executable = executable.trim(),
        arguments = List<String>.unmodifiable(arguments),
        workingDirectory = workingDirectory.trim(),
        declaredImpact = List<String>.unmodifiable(
          declaredImpact.map((item) => item.trim()),
        );

  factory WorkCommand.fromJson(Map<String, dynamic> json) {
    final executable = json['executable'];
    final rawArguments = json['arguments'];
    final workingDirectory = json['workingDirectory'];
    final rawImpact = json['declaredImpact'];
    if (executable is! String ||
        workingDirectory is! String ||
        rawArguments is! List ||
        rawImpact is! List ||
        rawArguments.any((item) => item is! String) ||
        rawImpact.any((item) => item is! String)) {
      throw const FormatException(
          '命令必须包含 executable、arguments、workingDirectory 和 declaredImpact');
    }
    return WorkCommand(
      executable: executable,
      arguments: rawArguments.cast<String>(),
      workingDirectory: workingDirectory,
      declaredImpact: rawImpact.cast<String>(),
    );
  }

  Map<String, dynamic> toJson() => {
        'executable': executable,
        'arguments': arguments,
        'workingDirectory': workingDirectory,
        'declaredImpact': declaredImpact,
      };

  String get displayCommand => [executable, ...arguments].map(_quote).join(' ');
}

/// Compatibility names for callers that model the policy input as a spec or
/// its output as a decision. They remain the same small value types.
typedef WorkCommandSpec = WorkCommand;
typedef WorkCommandPolicyDecision = WorkCommandPolicyResult;
typedef WorkCommandMissingToolSuggestion = WorkCommandInstallSuggestion;

/// Explainable policy output. A mutation always carries a [changePlan] so the
/// caller cannot accidentally execute it as if it were a read-only command.
class WorkCommandPolicyResult {
  final WorkCommand command;
  final WorkCommandImpact impact;
  final bool allowed;
  final bool requiresApproval;
  final bool requiresSeparateConfirmation;
  final bool requiresExplicitRequest;
  final String reason;
  final String? rejectionReason;
  final WorkChangePlan? changePlan;

  const WorkCommandPolicyResult({
    required this.command,
    required this.impact,
    required this.allowed,
    required this.requiresApproval,
    required this.requiresSeparateConfirmation,
    required this.requiresExplicitRequest,
    required this.reason,
    this.rejectionReason,
    this.changePlan,
  });

  bool get isReadOnly => impact == WorkCommandImpact.readOnly;
  bool get isRejected => !allowed && rejectionReason != null;
}

/// Public information shown when an executable is unavailable.
class WorkCommandInstallSuggestion {
  final String executable;
  final String purpose;
  final String trustedSource;
  final WorkCommand? installCommand;
  final List<String> impactPaths;

  const WorkCommandInstallSuggestion({
    required this.executable,
    required this.purpose,
    required this.trustedSource,
    required this.installCommand,
    required this.impactPaths,
  });

  bool get canInstall => installCommand != null;

  /// Returns whether a persisted checkpoint can be upgraded to a trusted
  /// installer suggestion after the app learns a new package mapping.
  static bool hasTrustedInstaller(
    String rawExecutable, {
    bool? isWindows,
    bool? isMacOS,
  }) {
    final executable = _normaliseExecutable(rawExecutable);
    final knownTool =
        const {'rg', 'ripgrep', 'git', 'pandoc'}.contains(executable);
    if (!knownTool) return false;
    final windows = isWindows ?? Platform.isWindows;
    final macOS = isMacOS ?? Platform.isMacOS;
    return windows || macOS;
  }

  String get message {
    final command = installCommand?.displayCommand ?? '请在外部终端按官方文档安装';
    final impact = impactPaths.isEmpty ? '未声明' : impactPaths.join('、');
    final suffix = canInstall
        ? '仅在你确认后（通过执行面板明确确认），App 才会执行该安装命令。安装可能写入系统包管理器目录或缓存（可能超出授权文件夹），本次不会加入永久授权。'
        : '无法安全自动安装，请从官方文档手动处理。';
    return '缺少工具：$executable。用途：$purpose。可信来源：$trustedSource。'
        '将执行：$command。影响范围：$impact。$suffix';
  }

  Map<String, dynamic> toJson() => {
        'executable': executable,
        'purpose': purpose,
        'trustedSource': trustedSource,
        'installCommand': installCommand?.toJson(),
        'impactPaths': impactPaths,
        'message': message,
      };

  /// Returns a known package-manager command only for tools whose source and
  /// package id are stable. Unknown tools intentionally have no invented
  /// installer.
  static WorkCommandInstallSuggestion forExecutable(
    String rawExecutable, {
    required bool isWindows,
    bool? isMacOS,
    required String workingDirectory,
    required List<String> declaredImpact,
  }) {
    final executable = _normaliseExecutable(rawExecutable);
    final macOS = isMacOS ?? Platform.isMacOS;
    final impact = List<String>.unmodifiable(declaredImpact);
    WorkCommand? install;
    String purpose;
    String source;
    switch (executable.toLowerCase()) {
      case 'rg':
      case 'ripgrep':
        purpose = 'search text quickly with ripgrep';
        source = 'https://github.com/BurntSushi/ripgrep';
        install = isWindows
            ? WorkCommand(
                executable: 'winget',
                arguments: const [
                  'install',
                  '--id',
                  'BurntSushi.ripgrep.MSVC',
                  '--exact',
                ],
                workingDirectory: workingDirectory,
                declaredImpact: impact,
              )
            : macOS
                ? WorkCommand(
                    executable: 'brew',
                    arguments: const ['install', 'ripgrep'],
                    workingDirectory: workingDirectory,
                    declaredImpact: impact,
                  )
                : null;
      case 'git':
        purpose = '版本控制和读取仓库状态';
        source = 'https://git-scm.com/downloads';
        install = isWindows
            ? WorkCommand(
                executable: 'winget',
                arguments: const ['install', '--id', 'Git.Git', '--exact'],
                workingDirectory: workingDirectory,
                declaredImpact: impact,
              )
            : macOS
                ? WorkCommand(
                    executable: 'brew',
                    arguments: const ['install', 'git'],
                    workingDirectory: workingDirectory,
                    declaredImpact: impact,
                  )
                : null;
      case 'pandoc':
        purpose = 'Markdown、HTML、DOCX 等文档转换和 PDF 报告生成';
        source = 'https://pandoc.org/installing.html';
        install = isWindows
            ? WorkCommand(
                executable: 'winget',
                arguments: const [
                  'install',
                  '--source',
                  'winget',
                  '--exact',
                  '--id',
                  'JohnMacFarlane.Pandoc',
                ],
                workingDirectory: workingDirectory,
                declaredImpact: impact,
              )
            : macOS
                ? WorkCommand(
                    executable: 'brew',
                    arguments: const ['install', 'pandoc'],
                    workingDirectory: workingDirectory,
                    declaredImpact: impact,
                  )
                : null;
      case 'flutter':
      case 'dart':
        purpose = 'Dart/Flutter 静态检查和项目工具';
        source = 'https://docs.flutter.dev/get-started/install';
      case 'node':
      case 'npm':
        purpose = 'JavaScript 项目命令和依赖管理';
        source = 'https://nodejs.org/en/download';
      case 'python':
      case 'python3':
        purpose = 'Python 项目脚本和检查';
        source = 'https://www.python.org/downloads/';
      default:
        purpose = '运行用户声明的本机命令';
        source = '$executable 官方文档（请核对域名和签名）';
    }
    return WorkCommandInstallSuggestion(
      executable: rawExecutable,
      purpose: purpose,
      trustedSource: source,
      installCommand: install,
      impactPaths: impact,
    );
  }
}

String _normaliseExecutable(String rawExecutable) {
  final executable = _basename(rawExecutable).toLowerCase();
  return executable.endsWith('.exe')
      ? executable.substring(0, executable.length - 4)
      : executable;
}

/// Static command classifier and authorization-boundary validator.
class WorkCommandPolicy {
  final List<String> authorizedRoots;
  final bool isWindows;
  final bool isMacOS;

  WorkCommandPolicy({
    required Iterable<String> authorizedRoots,
    bool? isWindows,
    bool? isMacOS,
  })  : isWindows = isWindows ?? Platform.isWindows,
        isMacOS = isMacOS ?? Platform.isMacOS,
        authorizedRoots = List<String>.unmodifiable(
          _normalizeAuthorizedRoots(authorizedRoots),
        );

  WorkCommandPolicyResult classify(
    WorkCommand command, {
    required String taskId,
    bool userExplicitlyRequested = false,
    bool acceptancePlanAuthorized = false,
  }) =>
      evaluate(
        command,
        taskId: taskId,
        userExplicitlyRequested: userExplicitlyRequested,
        acceptancePlanAuthorized: acceptancePlanAuthorized,
      );

  WorkCommandPolicyResult evaluate(
    WorkCommand command, {
    required String taskId,
    bool userExplicitlyRequested = false,
    bool acceptancePlanAuthorized = false,
  }) {
    final validationError = _validate(command);
    if (validationError != null) {
      return WorkCommandPolicyResult(
        command: command,
        impact: WorkCommandImpact.impactUncertain,
        allowed: false,
        requiresApproval: false,
        requiresSeparateConfirmation: false,
        requiresExplicitRequest: false,
        reason: validationError,
        rejectionReason: validationError,
      );
    }

    final impact = _classify(command);
    final isTestOrBuild = _isTestOrBuild(command);
    // Full tests/builds are never silently inferred from a generic request.
    // acceptancePlanAuthorized is reserved for lightweight checks such as
    // analyze, which are classified read-only below.
    if (isTestOrBuild && !userExplicitlyRequested) {
      final reason = acceptancePlanAuthorized
          ? '验收计划只能授权轻量检查；测试或构建仍需用户明确要求。'
          : '默认不运行测试或构建；请由用户明确要求后再执行。';
      final plan = _changePlan(taskId, command, impact, reason);
      return WorkCommandPolicyResult(
        command: command,
        impact: impact,
        allowed: false,
        requiresApproval: false,
        requiresSeparateConfirmation: true,
        requiresExplicitRequest: true,
        reason: reason,
        rejectionReason: reason,
        changePlan: plan,
      );
    }

    if (!impact.isMutation) {
      return WorkCommandPolicyResult(
        command: command,
        impact: impact,
        allowed: true,
        requiresApproval: false,
        requiresSeparateConfirmation: false,
        requiresExplicitRequest: false,
        reason: '已识别为只读命令，可在授权目录中自动执行。',
      );
    }

    final reason = _impactReason(impact);
    final plan = _changePlan(taskId, command, impact, reason);
    return WorkCommandPolicyResult(
      command: command,
      impact: impact,
      allowed: true,
      requiresApproval: true,
      requiresSeparateConfirmation:
          _requiresSeparateConfirmation(command, impact),
      requiresExplicitRequest: false,
      reason: reason,
      changePlan: plan,
    );
  }

  String? _validate(WorkCommand command) {
    if (command.executable.isEmpty) return '命令缺少 executable。';
    if (command.workingDirectory.isEmpty) return '命令缺少 workingDirectory。';
    if (command.declaredImpact.isEmpty) return '命令必须声明 declaredImpact。';
    if (_hasControl(command.executable) ||
        command.arguments.any(_hasControl) ||
        _hasControl(command.workingDirectory)) {
      return '命令包含控制字符。';
    }
    late final String cwd;
    try {
      cwd = normalizeWorkAbsolutePath(command.workingDirectory);
    } on Object {
      return 'workingDirectory 必须是绝对路径。';
    }
    if (!_isInAuthorizedRoot(cwd)) return 'workingDirectory 不在任何授权目录内。';
    for (final argument in command.arguments) {
      final candidate = _argumentPathCandidate(argument);
      if (candidate == null) continue;
      if (_containsParentSegment(candidate)) {
        return '命令参数路径不能包含 ..。';
      }
      if (_looksLikeLocalPath(candidate)) {
        late final String normalized;
        try {
          normalized = normalizeWorkAbsolutePath(candidate);
        } on Object {
          return '命令参数路径无效。';
        }
        if (!_isInAuthorizedRoot(normalized)) {
          return '命令参数路径超出授权目录范围。';
        }
      }
    }
    for (final rawImpact in command.declaredImpact) {
      if (rawImpact.isEmpty || _hasControl(rawImpact)) {
        return 'declaredImpact 含有无效条目。';
      }
      if (_containsParentSegment(rawImpact)) {
        return 'declaredImpact 路径不能包含 ..。';
      }
      late final String normalized;
      try {
        normalized = _normalizeCommandPath(rawImpact, cwd);
      } on Object {
        return 'declaredImpact 路径无效。';
      }
      if (!_isInAuthorizedRoot(normalized)) {
        return 'declaredImpact 超出授权目录范围。';
      }
    }
    return null;
  }

  WorkCommandImpact _classify(WorkCommand command) {
    // ponytail: a small conservative heuristic table keeps V1 dependency-free;
    // add a tested per-tool grammar when broader command coverage is needed.
    final executable = _basename(command.executable).toLowerCase();
    final lower = [executable, ...command.arguments]
        .map((item) => item.toLowerCase())
        .join(' ');
    if (lower.contains('|')) return WorkCommandImpact.impactUncertain;
    if (_isShellInvocation(executable, command.arguments)) {
      return WorkCommandImpact.impactUncertain;
    }
    if (RegExp(r'[<>]').hasMatch(lower)) return WorkCommandImpact.localMutation;
    if (_hasLocalOutputFlag(command) || _isFindMutation(command)) {
      return WorkCommandImpact.localMutation;
    }
    if (_isAnalysisMutation(command)) {
      return WorkCommandImpact.localMutation;
    }
    if (_isInstall(command)) return WorkCommandImpact.localMutation;
    if (_isInPlaceEdit(command)) return WorkCommandImpact.localMutation;
    if (_isDelete(command)) return WorkCommandImpact.localMutation;
    if (_isExternalMutation(command)) {
      return WorkCommandImpact.externalMutation;
    }
    // A path-qualified executable is not trusted merely because its basename
    // resembles a read-only utility.  It may point at a user-controlled file
    // (for example /tmp/rg), so require an explicit approval before launch.
    if (_isPathLikeExecutable(command.executable)) {
      return WorkCommandImpact.impactUncertain;
    }
    if (_isUnsafeNetworkRequest(command)) {
      return WorkCommandImpact.impactUncertain;
    }
    if (_isMove(command) || _isWrite(command)) {
      return WorkCommandImpact.localMutation;
    }
    if (_isTestOrBuild(command)) return WorkCommandImpact.localMutation;
    if (_isReadOnly(command)) return WorkCommandImpact.readOnly;
    return WorkCommandImpact.impactUncertain;
  }

  bool _isReadOnly(WorkCommand command) {
    final executable = _basename(command.executable).toLowerCase();
    final args = command.arguments.map((item) => item.toLowerCase()).toList();
    if (executable == 'pwd' ||
        executable == 'ls' ||
        executable == 'dir' ||
        executable == 'find' ||
        executable == 'fd' ||
        executable == 'rg' ||
        executable == 'grep' ||
        executable == 'egrep' ||
        executable == 'fgrep' ||
        executable == 'cat' ||
        executable == 'head' ||
        executable == 'tail' ||
        executable == 'wc' ||
        executable == 'file' ||
        executable == 'stat' ||
        executable == 'which' ||
        executable == 'where' ||
        executable == 'whoami' ||
        executable == 'uname') {
      return true;
    }
    if (executable == 'git' &&
        _gitSubcommand(args) != null &&
        const {
          'status',
          'diff',
          'log',
          'show',
          'branch',
          'rev-parse',
          'ls-files',
        }.contains(_gitSubcommand(args))) {
      return true;
    }
    if (executable == 'flutter' &&
        args.isNotEmpty &&
        const {'analyze', '--version', '--help'}.contains(args.first)) {
      return true;
    }
    if (executable == 'dart' &&
        args.isNotEmpty &&
        const {'analyze', '--version', '--help'}.contains(args.first)) {
      return true;
    }
    if (executable == 'curl') {
      return !_hasExternalWriteFlag(command.arguments);
    }
    if (executable == 'wget') {
      // Unlike curl, wget writes a downloaded response to the working
      // directory by default. Only an explicit HEAD-style probe is read-only;
      // ordinary downloads must pass the mutation approval path.
      return args.contains('--spider') &&
          !_hasExternalWriteFlag(command.arguments);
    }
    return false;
  }

  bool _isAnalysisMutation(WorkCommand command) {
    final executable = _basename(command.executable).toLowerCase();
    if (executable != 'flutter' && executable != 'dart') return false;
    final args = command.arguments.map((item) => item.toLowerCase()).toList();
    if (args.isEmpty || args.first != 'analyze') return false;
    return args.skip(1).any(
          (argument) =>
              argument == '--fix' ||
              argument.startsWith('--fix=') ||
              argument == '--apply' ||
              argument.startsWith('--apply=') ||
              argument == '--write' ||
              argument.startsWith('--write='),
        );
  }

  bool _isTestOrBuild(WorkCommand command) {
    final executable = _basename(command.executable).toLowerCase();
    final args = command.arguments.map((item) => item.toLowerCase()).toList();
    if (executable == 'flutter' || executable == 'dart') {
      return args.isNotEmpty &&
          const {'test', 'build', 'compile', 'run'}.contains(args.first);
    }
    if (executable == 'xcodebuild' ||
        executable == 'gradle' ||
        executable == 'mvn' ||
        executable == 'make' ||
        executable == 'msbuild') {
      return true;
    }
    if ((executable == 'cargo' ||
            executable == 'go' ||
            executable == 'dotnet') &&
        args.isNotEmpty &&
        const {'test', 'build'}.contains(args.first)) {
      return true;
    }
    if (executable == 'pytest' || executable == 'py.test') return true;
    if ((executable == 'python' || executable == 'python3') &&
        args.length >= 2 &&
        args[0] == '-m' &&
        const {'pytest', 'unittest'}.contains(args[1])) {
      return true;
    }
    if (executable == 'npm' || executable == 'pnpm' || executable == 'yarn') {
      return args.contains('build') || args.contains('test');
    }
    if (executable == 'bun') {
      return args.contains('build') || args.contains('test');
    }
    return false;
  }

  bool _isInstall(WorkCommand command) {
    final executable = _basename(command.executable).toLowerCase();
    final args = command.arguments.map((item) => item.toLowerCase()).toList();
    const installWords = {
      'install',
      'i',
      'add',
      'get',
      'ci',
      'upgrade',
      'update',
      'remove',
      'uninstall',
    };
    if (const {
      'brew',
      'apt',
      'apt-get',
      'dnf',
      'yum',
      'pacman',
      'choco',
      'winget'
    }.contains(executable)) {
      return args.any(installWords.contains);
    }
    if (const {
      'npm',
      'pnpm',
      'yarn',
      'bun',
      'pip',
      'pip3',
      'gem',
      'cargo',
      'go'
    }.contains(executable)) {
      return args.any(installWords.contains);
    }
    if ((executable == 'dart' || executable == 'flutter') &&
        args.length >= 2 &&
        args.first == 'pub') {
      return installWords.contains(args[1]);
    }
    if (executable == 'python' || executable == 'python3') {
      return args.length >= 3 &&
          args[0] == '-m' &&
          args[1] == 'pip' &&
          installWords.contains(args[2]);
    }
    return false;
  }

  bool _isDelete(WorkCommand command) {
    final executable = _basename(command.executable).toLowerCase();
    return const {'rm', 'rmdir', 'del', 'erase', 'unlink'}
            .contains(executable) ||
        (_basename(command.executable).toLowerCase() == 'git' &&
            command.arguments.isNotEmpty &&
            const {'clean', 'reset'}
                .contains(command.arguments.first.toLowerCase()));
  }

  bool _isMove(WorkCommand command) {
    return const {'mv', 'move', 'rename', 'ren'}
        .contains(_basename(command.executable).toLowerCase());
  }

  bool _isWrite(WorkCommand command) {
    final executable = _basename(command.executable).toLowerCase();
    if (const {
      'touch',
      'mkdir',
      'cp',
      'copy',
      'install',
      'tee',
      'chmod',
      'chown',
      'ln',
      'truncate',
      'dd'
    }.contains(executable)) {
      return true;
    }
    if (executable == 'git' && command.arguments.isNotEmpty) {
      return const {
        'commit',
        'push',
        'pull',
        'merge',
        'rebase',
        'checkout',
        'switch',
        'tag',
      }.contains(command.arguments.first.toLowerCase());
    }
    return false;
  }

  bool _isInPlaceEdit(WorkCommand command) {
    final executable = _basename(command.executable).toLowerCase();
    if (executable != 'sed' && executable != 'perl') return false;
    return command.arguments.any(
      (argument) =>
          argument == '-i' ||
          argument.startsWith('-i') ||
          argument == '--in-place' ||
          argument.startsWith('--in-place='),
    );
  }

  bool _hasLocalOutputFlag(WorkCommand command) {
    final executable = _basename(command.executable).toLowerCase();
    final rawArgs = command.arguments;
    final args = rawArgs.map((item) => item.toLowerCase()).toList();
    if (executable == 'curl' || executable == 'wget') {
      return rawArgs.any(
        (raw) {
          final argument = raw.toLowerCase();
          // curl's -D/-c and short-option clusters can carry a local output
          // path without spelling --output. Keep case-sensitive checks
          // separate so curl's -C (resume-at) is not mistaken for -c.
          final shortOutput = executable == 'curl'
              ? raw == '-D' ||
                  (raw.startsWith('-D') && raw.length > 2) ||
                  raw == '-c' ||
                  (raw.startsWith('-c') && raw.length > 2)
              : false;
          final clusteredOutput =
              !raw.startsWith('--') && _containsShortFlag(raw, 'o');
          return shortOutput ||
              clusteredOutput ||
              argument == '-o' ||
              (argument.startsWith('-o') && argument.length > 2) ||
              argument == '--output' ||
              argument.startsWith('--output=') ||
              argument == '--output-dir' ||
              argument.startsWith('--output-dir=') ||
              argument == '--output-document' ||
              argument.startsWith('--output-document=') ||
              argument == '--remote-name' ||
              argument == '--remote-name-all' ||
              argument == '--dump-header' ||
              argument.startsWith('--dump-header=') ||
              argument == '--trace' ||
              argument.startsWith('--trace=') ||
              argument == '--trace-ascii' ||
              argument.startsWith('--trace-ascii=') ||
              argument == '--stderr' ||
              argument.startsWith('--stderr=') ||
              argument == '--cookie-jar' ||
              argument.startsWith('--cookie-jar=') ||
              argument == '--hsts' ||
              argument.startsWith('--hsts=') ||
              argument == '--etag-save' ||
              argument.startsWith('--etag-save=') ||
              argument == '--create-dirs';
        },
      );
    }
    if (executable == 'git' &&
        args.isNotEmpty &&
        const {'diff', 'show'}.contains(args.first)) {
      return args.skip(1).any(
            (argument) =>
                argument == '-o' ||
                argument.startsWith('-o') ||
                argument == '--output' ||
                argument.startsWith('--output='),
          );
    }
    return false;
  }

  bool _isFindMutation(WorkCommand command) {
    final executable = _basename(command.executable).toLowerCase();
    if (executable != 'find') return false;
    return command.arguments.any(
      (argument) => const {
        '-delete',
        '-exec',
        '-execdir',
        '-ok',
        '-okdir',
      }.contains(argument.toLowerCase()),
    );
  }

  bool _isExternalMutation(WorkCommand command) {
    final executable = _basename(command.executable).toLowerCase();
    final args = command.arguments;
    if (executable == 'curl' || executable == 'wget') {
      return _hasExternalWriteFlag(args);
    }
    final lowerArgs = args.map((item) => item.toLowerCase()).toList();
    if (executable == 'git' &&
        lowerArgs.isNotEmpty &&
        lowerArgs.first == 'push') {
      return true;
    }
    return (executable == 'gh' && lowerArgs.contains('create')) ||
        (executable == 'docker' && lowerArgs.contains('push')) ||
        (executable == 'scp' || executable == 'sftp' || executable == 'ssh');
  }

  bool _hasExternalWriteFlag(List<String> args) {
    const flags = {
      '-d',
      '--data',
      '--data-ascii',
      '--data-raw',
      '--data-binary',
      '--data-urlencode',
      '--json',
      '-F',
      '--form',
      '--form-string',
      '-T',
      '--upload-file',
      '--post-data',
      '--post-file',
      '--body-data',
      '--body-file',
    };
    for (var index = 0; index < args.length; index++) {
      final arg = args[index];
      final lower = arg.toLowerCase();
      if (flags.contains(lower) ||
          (!arg.startsWith('--') &&
              (_containsShortFlag(arg, 'd') ||
                  _containsShortFlag(arg, 'F') ||
                  _containsShortFlag(arg, 'T'))) ||
          (lower.startsWith('--data=') && lower.length > '--data='.length) ||
          (lower.startsWith('--data-ascii=') &&
              lower.length > '--data-ascii='.length) ||
          (lower.startsWith('--data-raw=') &&
              lower.length > '--data-raw='.length) ||
          (lower.startsWith('--data-binary=') &&
              lower.length > '--data-binary='.length) ||
          (lower.startsWith('--data-urlencode=') &&
              lower.length > '--data-urlencode='.length) ||
          (lower.startsWith('--json=') && lower.length > '--json='.length) ||
          (lower.startsWith('--form=') && lower.length > '--form='.length) ||
          (lower.startsWith('--form-string=') &&
              lower.length > '--form-string='.length) ||
          (lower.startsWith('--upload-file=') &&
              lower.length > '--upload-file='.length) ||
          (lower.startsWith('--post-data=') &&
              lower.length > '--post-data='.length) ||
          (lower.startsWith('--post-file=') &&
              lower.length > '--post-file='.length) ||
          (lower.startsWith('--body-data=') &&
              lower.length > '--body-data='.length) ||
          (lower.startsWith('--body-file=') &&
              lower.length > '--body-file='.length)) {
        return true;
      }
      // curl's method switch is capital `-X`; lower-case `-x` is a proxy
      // option and must never be interpreted as a write method.
      final inlineMethod =
          arg.startsWith('-X') && arg.length > 2 ? arg.substring(2) : null;
      if (arg == '-X' || inlineMethod != null) {
        final method =
            inlineMethod ?? (index + 1 < args.length ? args[index + 1] : '');
        if (const {'post', 'put', 'patch', 'delete'}
            .contains(method.toLowerCase())) {
          return true;
        }
      }
      if ((lower == '--request' || lower == '--method') &&
          index + 1 < args.length) {
        final method = args[index + 1].toLowerCase();
        if (const {'post', 'put', 'patch', 'delete'}.contains(method)) {
          return true;
        }
      }
      if ((lower.startsWith('--request=') || lower.startsWith('--method=')) &&
          const {'post', 'put', 'patch', 'delete'}
              .contains(lower.substring(lower.indexOf('=') + 1))) {
        return true;
      }
    }
    return false;
  }

  /// Returns whether a short-option cluster contains [flag].  This is used
  /// only for options whose spelling is case-sensitive (for example `-X` is
  /// a request method while `-x` is a proxy).  A cluster is treated
  /// conservatively: if it contains the write flag, the command needs
  /// approval even when the attached value is not separately tokenized.
  bool _containsShortFlag(String argument, String flag) {
    if (flag.length != 1 ||
        !argument.startsWith('-') ||
        argument.startsWith('--')) {
      return false;
    }
    return argument.substring(1).contains(flag);
  }

  bool _isShellInvocation(String executable, List<String> arguments) {
    if (const {
      'sh',
      'sh.exe',
      'bash',
      'bash.exe',
      'zsh',
      'fish',
      'cmd',
      'cmd.exe',
      'command.com',
      'powershell',
      'powershell.exe',
      'pwsh',
      'pwsh.exe',
    }.contains(executable)) {
      return true;
    }
    // `-c` is a shell flag only when the executable itself is a shell.  Tools
    // such as `rg -c` (count) and `git -c key=value` remain ordinary commands.
    return false;
  }

  bool _isPathLikeExecutable(String executable) {
    final value = executable.trim();
    return value.contains('/') ||
        value.contains('\\') ||
        RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value);
  }

  bool _isUnsafeNetworkRequest(WorkCommand command) {
    final executable = _basename(command.executable).toLowerCase();
    if (executable != 'curl' && executable != 'wget') return false;
    final args = command.arguments.map((item) => item.trim()).toList();
    if (_hasExternalWriteFlag(args)) {
      return false;
    }
    // Config files, proxy/tunnel switches and arbitrary request methods can
    // hide uploads or local reads behind a nominally read-only command.
    if (args.any((arg) {
      final lower = arg.toLowerCase();
      return lower == '--config' ||
          lower.startsWith('--config=') ||
          arg == '-k' ||
          (arg.startsWith('-k') && arg.length > 2) ||
          arg == '-K' ||
          (arg.startsWith('-K') && arg.length > 2) ||
          lower == '--proxy' ||
          lower.startsWith('--proxy=') ||
          lower == '--preproxy' ||
          lower.startsWith('--preproxy=') ||
          lower == '--proxy1.0' ||
          lower.startsWith('--proxy1.0=') ||
          arg == '-x' ||
          (arg.startsWith('-x') && arg.length > 2) ||
          lower == '--socks5' ||
          lower.startsWith('--socks5=') ||
          lower == '--socks5-hostname' ||
          lower.startsWith('--socks5-hostname=') ||
          lower == '--socks4' ||
          lower.startsWith('--socks4=') ||
          lower == '--socks4a' ||
          lower.startsWith('--socks4a=') ||
          lower == '--resolve' ||
          lower.startsWith('--resolve=') ||
          lower == '--connect-to' ||
          lower.startsWith('--connect-to=') ||
          lower == '--interface' ||
          lower.startsWith('--interface=') ||
          lower == '--unix-socket' ||
          lower.startsWith('--unix-socket=') ||
          lower == '--local-port' ||
          lower.startsWith('--local-port=') ||
          lower == '--location' ||
          lower == '--location-trusted' ||
          arg == '-L' ||
          lower == '--proto' ||
          lower.startsWith('--proto=') ||
          lower == '--proto-redir' ||
          lower.startsWith('--proto-redir=') ||
          lower == '--load-cookies' ||
          lower.startsWith('--load-cookies=') ||
          lower == '--save-cookies' ||
          lower.startsWith('--save-cookies=') ||
          lower == '--bind-address' ||
          lower.startsWith('--bind-address=') ||
          lower == '--execute' ||
          lower.startsWith('--execute=') ||
          lower == '--use-askpass' ||
          lower == '--user' ||
          lower.startsWith('--user=') ||
          lower == '--proxy-user' ||
          lower.startsWith('--proxy-user=') ||
          lower == '--oauth2-bearer' ||
          lower.startsWith('--oauth2-bearer=') ||
          lower == '--cookie' ||
          lower.startsWith('--cookie=') ||
          lower == '--header' ||
          lower.startsWith('--header=') ||
          lower == '--netrc' ||
          lower == '--netrc-file' ||
          lower.startsWith('--netrc-file=') ||
          lower == '--input-file' ||
          lower.startsWith('--input-file=') ||
          lower == '--doh-url' ||
          lower.startsWith('--doh-url=') ||
          lower == '--dns-interface' ||
          lower.startsWith('--dns-interface=') ||
          lower == '--dns-ipv4-addr' ||
          lower.startsWith('--dns-ipv4-addr=') ||
          lower == '--dns-ipv6-addr' ||
          lower.startsWith('--dns-ipv6-addr=') ||
          lower == '--abstract-unix-socket' ||
          lower.startsWith('--abstract-unix-socket=') ||
          lower == '--url-query' ||
          lower.startsWith('--url-query=');
    })) {
      return true;
    }
    for (var index = 0; index < args.length; index++) {
      final raw = args[index];
      final lower = raw.toLowerCase();
      final inlineMethod = raw.startsWith('-X') && raw.length > 2
          ? raw.substring(2).toLowerCase()
          : null;
      if (raw == '-X' ||
          inlineMethod != null ||
          lower == '--request' ||
          lower == '--method') {
        final method = inlineMethod ??
            (index + 1 < args.length ? args[index + 1].toLowerCase() : '');
        if (method.isEmpty || !const {'get', 'head'}.contains(method)) {
          return true;
        }
        // Do not inspect the method token as a short-option cluster. For
        // example, the safe inline spelling `-XHEAD` contains an `H`, but it
        // is not a header option.
        if (raw == '-X' || inlineMethod != null) continue;
      }
      if (lower.startsWith('--request=') || lower.startsWith('--method=')) {
        final method = lower.substring(lower.indexOf('=') + 1);
        if (!const {'get', 'head'}.contains(method)) return true;
      }
      // Preserve case for short options. `-X GET` is a safe method override;
      // `-x proxy`, `-k`, and `-K config` are not safe automatic reads.
      if (_containsShortFlag(raw, 'L') ||
          _containsShortFlag(raw, 'k') ||
          _containsShortFlag(raw, 'K') ||
          _containsShortFlag(raw, 'x') ||
          _containsShortFlag(raw, 'b') ||
          _containsShortFlag(raw, 'u') ||
          _containsShortFlag(raw, 'H')) {
        return true;
      }
    }
    final urls = <String>[];
    const valueOptions = <String>{
      '-x',
      '-X',
      '-h',
      '-u',
      '-a',
      '--request',
      '--method',
      '--proxy',
      '--preproxy',
      '--proxy1.0',
      '--socks5',
      '--socks5-hostname',
      '--socks4',
      '--socks4a',
      '--header',
      '--user-agent',
      '--resolve',
      '--connect-to',
      '--interface',
      '--unix-socket',
      '--local-port',
      '--proto',
      '--proto-redir',
      '--config',
      '--load-cookies',
      '--save-cookies',
      '--bind-address',
      '--execute',
      '--doh-url',
      '--dns-interface',
      '--dns-ipv4-addr',
      '--dns-ipv6-addr',
      '--abstract-unix-socket',
      '--url-query',
    };
    for (var index = 0; index < args.length; index++) {
      final raw = args[index];
      final lower = raw.toLowerCase();
      if (lower == '--url') {
        if (index + 1 < args.length) urls.add(args[++index]);
        continue;
      }
      if (lower.startsWith('--url=')) {
        urls.add(raw.substring(raw.indexOf('=') + 1));
        continue;
      }
      if (valueOptions.contains(lower)) {
        index++;
        continue;
      }
      if (!raw.startsWith('-')) urls.add(raw);
    }
    // curl/wget with no explicit URL can consume stdin or config-provided
    // targets, so it is not eligible for automatic execution.
    if (urls.isEmpty) return true;
    return urls.any(_isNonPublicOrInvalidUrl);
  }

  bool _isNonPublicOrInvalidUrl(String raw) {
    final value = raw.trim();
    Uri? uri;
    try {
      uri = Uri.parse(value);
    } on FormatException {
      return true;
    }
    final scheme = uri.scheme.toLowerCase();
    final host = uri.host.toLowerCase();
    if (!const {'http', 'https'}.contains(scheme) || host.isEmpty) return true;
    final normalizedHost = host.replaceFirst(RegExp(r'\.+$'), '');
    if (uri.userInfo.isNotEmpty ||
        normalizedHost == 'localhost' ||
        normalizedHost.endsWith('.localhost') ||
        normalizedHost.endsWith('.local') ||
        normalizedHost == 'metadata.google.internal') {
      return true;
    }
    // Decimal/hex/octal host spellings can be interpreted as IPv4 by command
    // line clients even when Dart does not parse them as an InternetAddress.
    // Treat a numeric-only or 0x-prefixed host as uncertain rather than
    // granting it the public-host fast path.
    if (RegExp(r'^(?:0x[0-9a-f]+|[0-9]+)$', caseSensitive: false)
        .hasMatch(normalizedHost)) {
      return true;
    }
    final address = InternetAddress.tryParse(normalizedHost);
    if (address == null) {
      // A colon-bearing host is an IPv6 literal (possibly with a zone id),
      // while a digits-and-dots host is an IPv4 literal. If Dart rejected
      // either spelling, do not treat it as a DNS name and auto-allow it.
      return normalizedHost.contains(':') ||
          RegExp(r'^[0-9.]+$').hasMatch(normalizedHost);
    }
    return _isNonPublicAddress(address.rawAddress);
  }

  bool _isNonPublicAddress(List<int> raw) {
    if (raw.length == 4) return _isNonPublicIpv4(raw);
    if (raw.length != 16) return true;

    final isMappedIpv4 = raw.take(10).every((byte) => byte == 0) &&
        raw[10] == 0xff &&
        raw[11] == 0xff;
    if (isMappedIpv4) return _isNonPublicIpv4(raw.sublist(12));

    final allZero = raw.every((byte) => byte == 0);
    final first = raw[0];
    final second = raw[1];
    // ::, ::1, fc00::/7 (unique local), fe80::/10 (link local), and ff00::/8
    // (multicast) are not public destinations.  Also reject documentation
    // space so fixtures cannot accidentally become an automatic network read.
    final loopback =
        allZero || raw.take(15).every((byte) => byte == 0) && raw[15] == 1;
    final uniqueLocal = (first & 0xfe) == 0xfc;
    final linkLocal = first == 0xfe && (second & 0xc0) == 0x80;
    final multicast = first == 0xff;
    final documentation =
        first == 0x20 && second == 0x01 && raw[2] == 0x0d && raw[3] == 0xb8;
    return loopback || uniqueLocal || linkLocal || multicast || documentation;
  }

  bool _isNonPublicIpv4(List<int> raw) {
    if (raw.length != 4) return true;
    final first = raw[0];
    final second = raw[1];
    final third = raw[2];
    return first == 0 ||
        first == 10 ||
        first == 127 ||
        (first == 100 && second >= 64 && second <= 127) ||
        (first == 169 && second == 254) ||
        (first == 172 && second >= 16 && second <= 31) ||
        (first == 192 && second == 0) ||
        (first == 192 && second == 168) ||
        (first == 192 && second == 0 && third == 2) ||
        (first == 198 && second == 18) ||
        (first == 198 && second == 19) ||
        (first == 198 && second == 51 && third == 100) ||
        (first == 203 && second == 0 && third == 113) ||
        first >= 224;
  }

  String? _gitSubcommand(List<String> args) {
    for (var index = 0; index < args.length; index++) {
      final arg = args[index];
      if (arg == '-c' || arg == '--config-env') {
        index++;
        continue;
      }
      if ((arg.startsWith('-c') && arg.length > 2) ||
          arg.startsWith('--config-env=')) {
        continue;
      }
      if (arg.startsWith('-')) continue;
      return arg;
    }
    return null;
  }

  bool _requiresSeparateConfirmation(
    WorkCommand command,
    WorkCommandImpact impact,
  ) {
    if (impact == WorkCommandImpact.impactUncertain ||
        _isDelete(command) ||
        _isInstall(command) ||
        _isInPlaceEdit(command) ||
        _isFindMutation(command) ||
        _hasLocalOutputFlag(command)) {
      return true;
    }
    final lower =
        [command.executable, ...command.arguments].join(' ').toLowerCase();
    return RegExp(r'[<>]').hasMatch(lower) ||
        lower.contains('--force') ||
        RegExp(r'(^|\s)-f(?:\s|$)').hasMatch(lower) ||
        lower.contains('--in-place') ||
        (_basename(command.executable).toLowerCase() == 'git' &&
            command.arguments.isNotEmpty &&
            const {'commit', 'push', 'reset', 'clean'}
                .contains(command.arguments.first.toLowerCase()));
  }

  WorkChangePlan _changePlan(
    String taskId,
    WorkCommand command,
    WorkCommandImpact impact,
    String reason,
  ) {
    final cwd = normalizeWorkAbsolutePath(command.workingDirectory);
    final paths = command.declaredImpact
        .map((path) => _normalizeCommandPath(path, cwd))
        .toList(growable: false);
    final directories = paths.isEmpty ? [cwd] : paths;
    final structured = WorkChangeCommand(
      executable: command.executable,
      arguments: command.arguments,
      workingDirectory: cwd,
      knownFiles: const [],
      possibleDirectories: directories,
      impactUncertain: impact == WorkCommandImpact.impactUncertain,
    );
    return WorkChangePlan(
      taskId: taskId,
      actionType: WorkChangeActionType.command,
      exactPaths: const [],
      knownAffectedDirectories: directories,
      estimatedBytes: 0,
      snapshotAvailable: false,
      reversible: false,
      command: structured,
      commandReason: reason,
      riskReason: reason,
    );
  }

  String _impactReason(WorkCommandImpact impact) => switch (impact) {
        WorkCommandImpact.localMutation => '命令可能修改本地文件或工作区状态，必须先确认影响范围。',
        WorkCommandImpact.externalMutation => '命令可能改变外部系统状态，必须单独确认。',
        WorkCommandImpact.impactUncertain =>
          '命令含有管道、shell 或无法可靠枚举的影响范围，必须单独确认。',
        WorkCommandImpact.readOnly => '只读命令。',
      };

  bool _isInAuthorizedRoot(String path) => authorizedRoots.any(
        (root) => isWorkPathWithin(path, root),
      );
}

/// macOS exposes `/tmp` through `/private/tmp`; retain both spellings so a
/// tool payload and a security-scoped grant share the same boundary.
List<String> _normalizeAuthorizedRoots(Iterable<String> roots) {
  final normalized = <String>[];
  final seen = <String>{};
  for (final raw in roots) {
    final root = normalizeWorkAbsolutePath(raw);
    if (seen.add(root)) normalized.add(root);
    try {
      final resolved = normalizeWorkAbsolutePath(
        Directory(root).resolveSymbolicLinksSync(),
      );
      if (seen.add(resolved)) normalized.add(resolved);
    } on Object {
      // Non-existent roots are still validated by the regular path policy.
    }
  }
  return normalized;
}

bool _hasControl(String value) =>
    RegExp(r'[\u0000-\u001f\u007f]').hasMatch(value);

bool _looksLikeLocalPath(String value) =>
    value.startsWith('/') ||
    RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value) ||
    value.startsWith(r'\\');

String _normalizeCommandPath(String raw, String workingDirectory) {
  final value = raw.trim();
  if (_looksLikeLocalPath(value)) return normalizeWorkAbsolutePath(value);
  if (value.isEmpty || value.contains('://')) {
    throw ArgumentError.value(raw, 'path', '命令路径必须是本地路径');
  }
  final separator = workingDirectory.endsWith('/') ? '' : '/';
  return normalizeWorkAbsolutePath(
    '$workingDirectory$separator${value.replaceAll('\\', '/')}',
  );
}

String? _argumentPathCandidate(String argument) {
  final value = argument.trim();
  if (value.isEmpty) return null;
  if (value.startsWith('-')) {
    final equals = value.indexOf('=');
    if (equals > 0 && equals < value.length - 1) {
      final rightHandSide = _embeddedArgumentPath(value.substring(equals + 1));
      if (rightHandSide != null) return rightHandSide;
    }
    final attached = _attachedArgumentPath(value);
    if (attached != null) return attached;
    return null;
  }
  // curl uses `@path` for file-backed bodies and form fields. Treat the
  // marker as metadata and validate the referenced path itself; otherwise an
  // outside `@../secret` token would be mistaken for an opaque argument.
  return _embeddedArgumentPath(value);
}

String? _attachedArgumentPath(String value) {
  if (value.length <= 2 || !value.startsWith('-') || value.startsWith('--')) {
    return null;
  }
  // Cover common attached short forms such as `-o../outside` and
  // `-d@../outside`; an option token must not hide a path from the policy.
  if (!const {'o', 'O', 'D', 'c', 'C', 'K', 'T', 'd', 'F', 'E', 'b', 'P', 'i'}
      .contains(value[1])) {
    return null;
  }
  return _embeddedArgumentPath(value.substring(2));
}

String? _embeddedArgumentPath(String raw) {
  var value = raw.trim();
  if (value.startsWith('@')) value = value.substring(1);
  final fileMarker = value.indexOf('=@');
  if (fileMarker >= 0) value = value.substring(fileMarker + 2);
  return _looksLikeLocalPath(value) || _looksLikeRelativePath(value)
      ? value
      : null;
}

bool _looksLikeRelativePath(String value) =>
    value.startsWith('./') ||
    value.startsWith('../') ||
    value.startsWith(r'.\\') ||
    value.startsWith(r'..\\') ||
    value.contains('/') ||
    value.contains('\\');

bool _containsParentSegment(String value) =>
    value.replaceAll('\\', '/').split('/').contains('..');

String _basename(String value) {
  final normalized = value.replaceAll('\\', '/');
  final index = normalized.lastIndexOf('/');
  return index < 0 ? normalized : normalized.substring(index + 1);
}

String _quote(String value) {
  if (RegExp(r'^[A-Za-z0-9_./:@%+=,-]+$').hasMatch(value)) return value;
  return "'${value.replaceAll("'", "'\\''")}'";
}

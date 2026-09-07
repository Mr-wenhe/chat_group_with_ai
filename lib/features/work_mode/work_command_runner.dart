import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chat_group/features/web_search/security/search_secret_scanner.dart';

import 'work_change_plan.dart';
import 'work_command_policy.dart';
import 'work_task_error_sanitizer.dart';
import 'workspace_path_policy.dart';

export 'work_command_policy.dart';

part 'work_command_runner_safety.dart';
part 'work_command_runner_process.dart';
part 'work_command_runner_output.dart';

/// Process outcomes are deliberately distinct so UI can offer the right
/// recovery action without parsing an error string.
enum WorkCommandRunStatus {
  completed,
  failed,
  timedOut,
  cancelled,
  pausedForUser,
  outputLimitExceeded,
  toolMissing,
  waitingForApproval,
  blockedByDefault,
  pathRejected,
}

class WorkCommandResult {
  final WorkCommand command;
  final WorkCommandRunStatus status;
  final String message;
  final String stdout;
  final String stderr;
  final int? exitCode;
  final Duration elapsed;
  final bool outputTruncated;
  final WorkCommandPolicyResult policy;
  final WorkCommandInstallSuggestion? installSuggestion;

  const WorkCommandResult({
    required this.command,
    required this.status,
    required this.message,
    required this.stdout,
    required this.stderr,
    required this.exitCode,
    required this.elapsed,
    required this.outputTruncated,
    required this.policy,
    this.installSuggestion,
  });

  bool get succeeded => status == WorkCommandRunStatus.completed;
  WorkChangePlan? get changePlan => policy.changePlan;
  bool get paused =>
      status == WorkCommandRunStatus.pausedForUser ||
      status == WorkCommandRunStatus.waitingForApproval ||
      status == WorkCommandRunStatus.blockedByDefault;
}

typedef WorkCommandDnsResolver = Future<List<InternetAddress>> Function(
  String host,
);

/// Controlled, non-shell command execution for the standalone Stage 03 loop.
/// The production adapter invokes this only after the structured command
/// policy and task approval gates have passed.
class WorkCommandRunner {
  static const Duration defaultTimeout = Duration(seconds: 60);
  static const Duration defaultTerminationGrace = Duration(milliseconds: 350);
  static const int defaultMaxOutputBytes = 512 * 1024;

  // Keep the child process hermetic. In particular, do not forward arbitrary
  // user/application variables: dynamic-loader, language-runtime and socket
  // variables can change what an otherwise trusted executable runs or where
  // it sends data. The explicit utility installers below use their own even
  // smaller environment.
  static const Set<String> _safeEnvironmentKeys = <String>{
    'PATH',
    'USER',
    'LOGNAME',
    'SystemRoot',
    'WINDIR',
    'PATHEXT',
    'COMSPEC',
    'TMP',
    'TEMP',
    'TMPDIR',
    'PWD',
    'LANG',
    'LC_ALL',
    'LC_CTYPE',
    'TERM',
  };

  static final RegExp _credentialPrompt = RegExp(
    r'(?:sudo\s+)?(?:password|passphrase)|(?:enter\s+)?(?:login|username)|'
    r'验证码|密码|登录|登入|\[[yYnN](?:/[yYnN])?\]|'
    r'\([yYnN](?:/[yYnN])?\)|'
    r'\b(?:do you want to |would you like to |please )?'
    r'(?:continue|proceed|confirm)\b[^\r\n]{0,48}(?:\?|\[[yYnN]|\([yYnN])|'
    r'\b(?:select|choose|choice|option)\b[^\r\n]{0,80}(?:[:?]|\[[0-9A-Za-z])|'
    r'请选择[^\r\n]{0,80}(?:[:：?？]|\[[0-9A-Za-z])|'
    r'\bpress\s+(?:enter|return)\b',
    caseSensitive: false,
  );

  final WorkCommandPolicy policy;
  final WorkspacePathPolicy? pathPolicy;
  final WorkCommandProcessStarter processStarter;
  final Map<String, String> parentEnvironment;
  final WorkCommandOutputSink? onOutput;
  final DateTime Function() clock;
  final Duration timeout;
  final Duration terminationGrace;
  final int maxOutputBytes;
  final SearchSecretScanner secretScanner;
  final WorkCommandDnsResolver dnsResolver;
  final bool _usesDefaultProcessStarter;

  WorkCommandRunner({
    required this.policy,
    this.pathPolicy,
    WorkCommandProcessStarter? processStarter,
    Map<String, String>? parentEnvironment,
    this.onOutput,
    DateTime Function()? clock,
    this.timeout = defaultTimeout,
    this.terminationGrace = defaultTerminationGrace,
    this.maxOutputBytes = defaultMaxOutputBytes,
    this.secretScanner = const SearchSecretScanner(),
    WorkCommandDnsResolver? dnsResolver,
  })  : processStarter = processStarter ?? _startProcess,
        _usesDefaultProcessStarter = processStarter == null,
        parentEnvironment = Map<String, String>.unmodifiable(
          Map<String, String>.from(parentEnvironment ?? Platform.environment),
        ),
        clock = clock ?? DateTime.now,
        dnsResolver = dnsResolver ?? InternetAddress.lookup {
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout', '必须大于零');
    }
    if (terminationGrace <= Duration.zero) {
      throw ArgumentError.value(
        terminationGrace,
        'terminationGrace',
        '必须大于零',
      );
    }
    if (maxOutputBytes <= 0) {
      throw ArgumentError.value(maxOutputBytes, 'maxOutputBytes', '必须大于零');
    }
  }

  /// Runs a command only after policy and (for mutations) task approval pass.
  /// [approved] is an alias kept for callers whose UI uses that wording.
  Future<WorkCommandResult> run(
    WorkCommand command, {
    required String taskId,
    bool approvalGranted = false,
    bool? approved,
    bool userExplicitlyRequested = false,
    bool acceptancePlanAuthorized = false,
    Future<void>? cancellation,
    bool Function()? isCancelled,
  }) async {
    final policyResult = policy.evaluate(
      command,
      taskId: taskId,
      userExplicitlyRequested: userExplicitlyRequested,
      acceptancePlanAuthorized: acceptancePlanAuthorized,
    );
    final gateResult = _preflightResult(
      command,
      policyResult,
      approvalGranted: approvalGranted,
      approved: approved,
      isCancelled: isCancelled,
    );
    if (gateResult != null) return gateResult;
    final pathError = await _validateWorkingDirectory(command);
    if (pathError != null) {
      return _result(
        command,
        policyResult,
        status: WorkCommandRunStatus.pathRejected,
        message: pathError,
      );
    }
    final boundaryError = await _validateCommandBoundary(command);
    if (boundaryError != null) {
      return _result(
        command,
        policyResult,
        status: boundaryError.isNetwork
            ? WorkCommandRunStatus.blockedByDefault
            : WorkCommandRunStatus.pathRejected,
        message: boundaryError.message,
      );
    }
    final start = await _spawn(
      command,
      policyResult,
      userExplicitlyRequested: userExplicitlyRequested,
    );
    final startResult = start.result;
    if (startResult != null) return startResult;
    return _executeProcess(
      command,
      policyResult,
      start.process!,
      cancellation: cancellation,
    );
  }

  WorkCommandResult? _preflightResult(
    WorkCommand command,
    WorkCommandPolicyResult policyResult, {
    required bool approvalGranted,
    required bool? approved,
    required bool Function()? isCancelled,
  }) {
    if (!policyResult.allowed) {
      final isPathRejected =
          policyResult.rejectionReason?.contains('workingDirectory') == true ||
              policyResult.rejectionReason?.contains('授权目录') == true ||
              policyResult.rejectionReason?.contains('路径') == true;
      return _result(
        command,
        policyResult,
        status: isPathRejected
            ? WorkCommandRunStatus.pathRejected
            : WorkCommandRunStatus.blockedByDefault,
        message: policyResult.rejectionReason ?? policyResult.reason,
      );
    }
    // The default OS process starter is a real capability boundary. Without
    // the path resolver it cannot verify symlink targets and declared impact
    // before spawning, so fail closed instead of silently running an
    // unreviewed command. Test/injected starters remain usable in isolation.
    if (_usesDefaultProcessStarter && pathPolicy == null) {
      return _result(
        command,
        policyResult,
        status: WorkCommandRunStatus.blockedByDefault,
        message: '命令缺少授权路径解析器，已阻止执行。',
      );
    }
    if (policyResult.requiresApproval && !(approved ?? approvalGranted)) {
      return _result(
        command,
        policyResult,
        status: WorkCommandRunStatus.waitingForApproval,
        message: policyResult.reason,
      );
    }
    if (_isCancelled(isCancelled)) {
      return _result(
        command,
        policyResult,
        status: WorkCommandRunStatus.cancelled,
        message: '命令执行已取消。',
      );
    }
    return null;
  }

  Future<_ProcessStartOutcome> _spawn(
    WorkCommand command,
    WorkCommandPolicyResult policyResult, {
    required bool userExplicitlyRequested,
  }) async {
    late final WorkCommand commandForSpawn;
    try {
      commandForSpawn = await _prepareCommand(
        command,
        policyResult,
        userExplicitlyRequested: userExplicitlyRequested,
      );
    } on _CommandSecurityException catch (error) {
      return _ProcessStartOutcome(
        result: _result(
          command,
          policyResult,
          status: WorkCommandRunStatus.blockedByDefault,
          message: error.message,
        ),
      );
    } on ProcessException catch (error) {
      if (_isMissingExecutable(error)) {
        return _ProcessStartOutcome(
          result: _missingExecutableResult(command, policyResult),
        );
      }
      return _ProcessStartOutcome(
        result: _result(
          command,
          policyResult,
          status: WorkCommandRunStatus.failed,
          message: _safeError(error),
        ),
      );
    }
    final startFuture = Future<WorkCommandProcess>.sync(
      () => processStarter(
        commandForSpawn,
        env: _safeEnvironment(commandForSpawn),
        shell: false,
      ),
    );
    try {
      final process = await startFuture.timeout(timeout);
      return _ProcessStartOutcome(process: process);
    } on TimeoutException {
      _terminateLateProcess(startFuture);
      return _ProcessStartOutcome(
        result: _result(
          command,
          policyResult,
          status: WorkCommandRunStatus.timedOut,
          message: '命令启动超时；若进程稍后启动将立即终止。',
        ),
      );
    } on ProcessException catch (error) {
      if (_isMissingExecutable(error)) {
        return _ProcessStartOutcome(
          result: _missingExecutableResult(command, policyResult),
        );
      }
      return _ProcessStartOutcome(
        result: _result(
          command,
          policyResult,
          status: WorkCommandRunStatus.failed,
          message: _safeError(error),
        ),
      );
    } on Object catch (error) {
      return _ProcessStartOutcome(
        result: _result(
          command,
          policyResult,
          status: WorkCommandRunStatus.failed,
          message: _safeError(error),
        ),
      );
    }
  }
}

Future<WorkCommandProcess> _startProcess(
  WorkCommand command, {
  required Map<String, String> env,
  required bool shell,
}) async {
  final process = await Process.start(
    command.executable,
    command.arguments,
    workingDirectory: command.workingDirectory,
    environment: env,
    includeParentEnvironment: false,
    runInShell: false,
  );
  try {
    await process.stdin.close();
  } on Object {
    // Closing stdin is best effort when a short-lived command already exited.
  }
  return WorkCommandProcess(
    pid: process.pid,
    stdout: process.stdout,
    stderr: process.stderr,
    exitCode: process.exitCode,
    terminateTree: ({bool force = false}) =>
        _terminateDartProcessTree(process, force: force),
  );
}

Future<void> _terminateDartProcessTree(
  Process process, {
  required bool force,
}) async {
  final signal = force ? ProcessSignal.sigkill : ProcessSignal.sigterm;
  if (Platform.isWindows) {
    try {
      final args = <String>['/PID', '${process.pid}', '/T'];
      if (force) args.add('/F');
      await Process.run(
        'taskkill',
        args,
        runInShell: false,
        environment: _processUtilityEnvironment(),
        includeParentEnvironment: false,
      );
    } on Object {
      // The direct Process.kill below remains the fallback.
    }
    try {
      process.kill(signal);
    } on Object {
      // The process may have exited already.
    }
    return;
  }
  // Collect descendants before killing the parent. Once the parent exits,
  // macOS reparents children and a later `pkill -P` can no longer find them.
  // ponytail: bounded pgrep traversal (256 PIDs/32 levels); use a native
  // process-group handle if V1 later needs stronger guarantees for hostile
  // descendants.
  final descendants = await _collectDescendantPids(process.pid);
  for (final pid in descendants) {
    try {
      Process.killPid(pid, signal);
    } on Object {
      // A short-lived child may have exited during collection.
    }
  }
  await _runPkillForChildren(process.pid, signal);
  try {
    process.kill(signal);
  } on Object {
    // The process may have exited already.
  }
  // One best-effort post-parent pass catches a child created in the small
  // collection window. It is harmless when the parent is already gone.
  await _runPkillForChildren(process.pid, signal);
}

Future<List<int>> _collectDescendantPids(
  int parentPid, {
  Set<int>? seen,
  int depth = 0,
}) async {
  final visited = seen ?? <int>{parentPid};
  if (depth >= 32 || visited.length >= 256) return const [];
  final children = await _queryChildPids(parentPid);
  final result = <int>[];
  for (final childPid in children) {
    if (childPid <= 0 || !visited.add(childPid)) continue;
    result.addAll(
      await _collectDescendantPids(
        childPid,
        seen: visited,
        depth: depth + 1,
      ),
    );
    result.add(childPid);
  }
  return result;
}

Future<List<int>> _queryChildPids(int parentPid) async {
  try {
    final result = await Process.run(
      'pgrep',
      ['-P', '$parentPid'],
      runInShell: false,
      environment: _processUtilityEnvironment(),
      includeParentEnvironment: false,
    ).timeout(const Duration(milliseconds: 200));
    return result.stdout
        .toString()
        .split(RegExp(r'\s+'))
        .map(int.tryParse)
        .whereType<int>()
        .toList(growable: false);
  } on Object {
    return const [];
  }
}

Future<void> _runPkillForChildren(int parentPid, ProcessSignal signal) async {
  try {
    await Process.run(
      'pkill',
      [signal == ProcessSignal.sigkill ? '-KILL' : '-TERM', '-P', '$parentPid'],
      runInShell: false,
      environment: _processUtilityEnvironment(),
      includeParentEnvironment: false,
    ).timeout(const Duration(milliseconds: 200));
  } on Object {
    // pgrep/pkill are best-effort; the direct parent/descendant signals above
    // remain the primary cleanup path.
  }
}

Map<String, String> _processUtilityEnvironment() {
  if (!Platform.isWindows) {
    return const {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin'};
  }
  final systemRoot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
  return {
    'SystemRoot': systemRoot,
    'PATH': '$systemRoot\\System32',
  };
}

bool _isSensitiveEnvironmentName(String name) {
  final normalized = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  return normalized.contains('apikey') ||
      normalized.contains('token') ||
      normalized.contains('secret') ||
      normalized.contains('password') ||
      normalized.contains('authorization') ||
      normalized.contains('credential') ||
      normalized.contains('cookie') ||
      normalized == 'key' ||
      normalized.endsWith('key');
}

bool _hasControl(String value) =>
    RegExp(r'[\u0000-\u001f\u007f]').hasMatch(value);

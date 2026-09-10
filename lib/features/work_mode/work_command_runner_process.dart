part of 'work_command_runner.dart';

/// Small process boundary used by the runner and by deterministic tests.
/// The process never receives user input: stdin is closed by the production
/// starter immediately after spawn.
class WorkCommandProcess {
  final int pid;
  final Stream<List<int>> stdout;
  final Stream<List<int>> stderr;
  final Future<int> exitCode;
  final FutureOr<void> Function({bool force}) terminateTree;

  const WorkCommandProcess({
    required this.pid,
    required this.stdout,
    required this.stderr,
    required this.exitCode,
    required this.terminateTree,
  });
}

typedef WorkCommandProcessStarter = Future<WorkCommandProcess> Function(
  WorkCommand command, {
  required Map<String, String> env,
  required bool shell,
});

enum _StopReason { timeout, cancellation, prompt, outputLimit }

class _StopSignal {
  final Completer<_StopReason> _completer = Completer<_StopReason>();

  Future<_StopReason> get future => _completer.future;

  void request(_StopReason reason) {
    if (!_completer.isCompleted) _completer.complete(reason);
  }
}

class _ExitSignal {
  final int code;

  const _ExitSignal(this.code);
}

class _ProcessStartOutcome {
  final WorkCommandProcess? process;
  final WorkCommandResult? result;

  const _ProcessStartOutcome({this.process, this.result});
}

class _ProcessWaitOutcome {
  final _StopReason? stopReason;
  final int? exitCode;
  final Object? error;

  const _ProcessWaitOutcome({this.stopReason, this.exitCode, this.error});
}

class _CommandSecurityException implements Exception {
  final String message;

  const _CommandSecurityException(this.message);
}

class _CommandBoundaryError {
  final String message;
  final bool isNetwork;

  const _CommandBoundaryError(this.message, {this.isNetwork = false});
}

/// Prompt text can be split across OS stream chunks. Keep only a small tail so
/// a credential prompt is detected without retaining unbounded child output.
class _PromptDetector {
  final RegExp pattern;
  String _tail = '';

  _PromptDetector(this.pattern);

  bool add(List<int> bytes) {
    final text = utf8.decode(bytes, allowMalformed: true);
    _tail = '$_tail$text';
    final matched = pattern.hasMatch(_tail);
    if (_tail.length > 256) _tail = _tail.substring(_tail.length - 256);
    return matched;
  }
}

extension _WorkCommandRunnerProcess on WorkCommandRunner {
  void _terminateLateProcess(Future<WorkCommandProcess> startFuture) {
    unawaited(
      startFuture
          .then<void>((process) => process.terminateTree(force: true))
          .catchError((Object _) {}),
    );
  }

  Future<WorkCommandResult> _executeProcess(
    WorkCommand command,
    WorkCommandPolicyResult policyResult,
    WorkCommandProcess process, {
    required Future<void>? cancellation,
  }) async {
    final startedAt = clock();
    final stop = _StopSignal();
    final output = _OutputCollector(
      limit: maxOutputBytes,
      scanner: secretScanner,
      sink: onOutput,
      requestStop: stop.request,
    );
    final promptDetector = _PromptDetector(WorkCommandRunner._credentialPrompt);
    final stdoutDone = Completer<void>();
    final stderrDone = Completer<void>();
    final subscriptions = _listenToOutput(
      process,
      stop: stop,
      detector: promptDetector,
      output: output,
      stdoutDone: stdoutDone,
      stderrDone: stderrDone,
    );
    final exit = _watchExit(process);
    final timer = Timer(timeout, () => stop.request(_StopReason.timeout));
    _watchCancellation(cancellation, stop);
    final outcome = await _waitForCompletion(
      process,
      exit,
      stop,
      stdoutDone.future,
      stderrDone.future,
    );
    timer.cancel();
    await _cancelSubscriptions(subscriptions);
    return _resultForOutcome(
      command,
      policyResult,
      outcome,
      output,
      elapsed: clock().difference(startedAt),
    );
  }

  List<StreamSubscription<List<int>>> _listenToOutput(
    WorkCommandProcess process, {
    required _StopSignal stop,
    required _PromptDetector detector,
    required _OutputCollector output,
    required Completer<void> stdoutDone,
    required Completer<void> stderrDone,
  }) {
    return [
      process.stdout.listen(
        (bytes) {
          _observeOutputForPrompt(bytes, stop, detector);
          output.add(WorkCommandOutputStream.stdout, bytes);
        },
        onError: (Object _, StackTrace __) {},
        onDone: () {
          output.flush(WorkCommandOutputStream.stdout);
          if (!stdoutDone.isCompleted) stdoutDone.complete();
        },
      ),
      process.stderr.listen(
        (bytes) {
          _observeOutputForPrompt(bytes, stop, detector);
          output.add(WorkCommandOutputStream.stderr, bytes);
        },
        onError: (Object _, StackTrace __) {},
        onDone: () {
          output.flush(WorkCommandOutputStream.stderr);
          if (!stderrDone.isCompleted) stderrDone.complete();
        },
      ),
    ];
  }

  Completer<int> _watchExit(WorkCommandProcess process) {
    final exit = Completer<int>();
    unawaited(
      process.exitCode.then<void>(
        (code) {
          if (!exit.isCompleted) exit.complete(code);
        },
        onError: (Object error, StackTrace stack) {
          if (!exit.isCompleted) exit.completeError(error, stack);
        },
      ),
    );
    return exit;
  }

  void _watchCancellation(Future<void>? cancellation, _StopSignal stop) {
    if (cancellation == null) return;
    unawaited(
      cancellation.then<void>(
        (_) => stop.request(_StopReason.cancellation),
        onError: (Object _, StackTrace __) =>
            stop.request(_StopReason.cancellation),
      ),
    );
  }

  Future<_ProcessWaitOutcome> _waitForCompletion(
    WorkCommandProcess process,
    Completer<int> exit,
    _StopSignal stop,
    Future<void> stdoutDone,
    Future<void> stderrDone,
  ) async {
    try {
      final winner = await Future.any<Object>([
        exit.future.then<Object>(_ExitSignal.new),
        stop.future,
      ]);
      if (winner is _ExitSignal) {
        await _awaitNaturalStreamCompletion(stdoutDone, stderrDone);
        return _ProcessWaitOutcome(exitCode: winner.code);
      }
      final stopReason = winner as _StopReason;
      await _terminate(process, exit);
      return _ProcessWaitOutcome(stopReason: stopReason);
    } on Object catch (error) {
      await _terminate(process, exit);
      return _ProcessWaitOutcome(error: error);
    }
  }

  WorkCommandResult _resultForOutcome(
    WorkCommand command,
    WorkCommandPolicyResult policyResult,
    _ProcessWaitOutcome outcome,
    _OutputCollector output, {
    required Duration elapsed,
  }) {
    final error = outcome.error;
    if (error != null) {
      return _result(
        command,
        policyResult,
        status: WorkCommandRunStatus.failed,
        message: _safeError(error),
        stdout: output.stdout,
        stderr: output.stderr,
        elapsed: elapsed,
        outputTruncated: output.truncated,
      );
    }
    final stopReason = outcome.stopReason;
    if (stopReason != null) {
      final status = switch (stopReason) {
        _StopReason.timeout => WorkCommandRunStatus.timedOut,
        _StopReason.cancellation => WorkCommandRunStatus.cancelled,
        _StopReason.prompt => WorkCommandRunStatus.pausedForUser,
        _StopReason.outputLimit => WorkCommandRunStatus.outputLimitExceeded,
      };
      final message = switch (stopReason) {
        _StopReason.timeout => '命令执行超时，已终止进程树。',
        _StopReason.cancellation => '命令执行已取消，已终止进程树。',
        _StopReason.prompt => '检测到密码、登录、验证码或交互提示，已暂停。请在外部终端处理；App 不会代填凭据。',
        _StopReason.outputLimit => '命令输出超过上限，已终止进程树。',
      };
      return _result(
        command,
        policyResult,
        status: status,
        message: message,
        exitCode: outcome.exitCode,
        stdout: output.stdout,
        stderr: output.stderr,
        elapsed: elapsed,
        outputTruncated:
            output.truncated || stopReason == _StopReason.outputLimit,
      );
    }
    final status = outcome.exitCode == 0
        ? WorkCommandRunStatus.completed
        : WorkCommandRunStatus.failed;
    return _result(
      command,
      policyResult,
      status: status,
      message: status == WorkCommandRunStatus.completed
          ? '命令执行完成。'
          : '命令退出码为 ${outcome.exitCode ?? '未知'}。',
      exitCode: outcome.exitCode,
      stdout: output.stdout,
      stderr: output.stderr,
      elapsed: elapsed,
      outputTruncated: output.truncated,
    );
  }

  Future<void> _terminate(
    WorkCommandProcess process,
    Completer<int> exit,
  ) async {
    try {
      await process.terminateTree(force: false);
    } on Object {
      // A process may have exited between the signal and this call.
    }
    if (!exit.isCompleted) {
      await _waitForExit(exit, terminationGrace);
    }
    // Always issue a force pass after a bounded grace period. This is cheap
    // for an already-dead process and prevents orphaned descendants.
    try {
      await process.terminateTree(force: true);
    } on Object {
      // Best effort; the bounded caller still returns a visible failure.
    }
    if (!exit.isCompleted) {
      await _waitForExit(exit, const Duration(seconds: 1));
    }
  }

  Future<void> _waitForExit(
    Completer<int> exit,
    Duration wait,
  ) async {
    try {
      await exit.future.timeout(wait);
    } on Object {
      // A failed or slow exit notification must not block cleanup.
    }
  }

  Future<void> _awaitNaturalStreamCompletion(
    Future<void> stdoutDone,
    Future<void> stderrDone,
  ) async {
    try {
      await Future.wait<void>([stdoutDone, stderrDone]).timeout(
        terminationGrace,
      );
    } on Object {
      // A custom process may keep a pipe open after exit. The final cleanup
      // still cancels both subscriptions below within a bounded timeout.
    }
  }

  Future<void> _cancelSubscriptions(
    List<StreamSubscription<List<int>>> subscriptions,
  ) async {
    for (final subscription in subscriptions) {
      try {
        await subscription.cancel().timeout(const Duration(milliseconds: 250));
      } on Object {
        // Stream cleanup is bounded so a broken child stream cannot hang the
        // task coordinator after cancellation.
      }
    }
  }

  void _observeOutputForPrompt(
    List<int> bytes,
    _StopSignal stop,
    _PromptDetector detector,
  ) {
    if (detector.add(bytes)) stop.request(_StopReason.prompt);
  }

  Map<String, String> _safeEnvironment({
    WorkCommand? command,
    bool includeUserHome = false,
  }) {
    final result = <String, String>{};
    final executable = command == null
        ? ''
        : _commandBasename(command.executable).toLowerCase();
    final canIncludeUserHome =
        includeUserHome && (executable == 'brew' || executable == 'winget');
    for (final entry in parentEnvironment.entries) {
      final key = entry.key;
      final normalisedKey = key.toUpperCase();
      final allowed = normalisedKey == 'HOME'
          ? canIncludeUserHome
          : WorkCommandRunner._safeEnvironmentKeys.any(
              (candidate) => candidate.toUpperCase() == normalisedKey,
            );
      if (!allowed) continue;
      if (_isSensitiveEnvironmentName(entry.key)) continue;
      if (_hasControl(entry.key) || _hasControl(entry.value)) continue;
      if (secretScanner.containsSensitiveData(
        entry.value,
        includeOpaqueTokens: true,
      )) {
        continue;
      }
      result[entry.key] = entry.value;
    }
    if (command != null && _isPathLikeExecutable(command.executable)) {
      result['PATH'] = _trustedChildPath(command.executable);
    }
    if (executable == 'git') {
      // Do not inherit machine-wide or user-global git configuration. Local
      // repository config remains visible for normal project semantics.
      result['GIT_CONFIG_NOSYSTEM'] = '1';
      result['GIT_CONFIG_GLOBAL'] = Platform.isWindows ? 'NUL' : '/dev/null';
      result['GIT_OPTIONAL_LOCKS'] = '0';
    }
    return Map<String, String>.unmodifiable(result);
  }

  String _trustedChildPath(String executable) {
    final normalized = executable.replaceAll('\\', '/');
    final slash = normalized.lastIndexOf('/');
    final executableDirectory = slash > 0 ? normalized.substring(0, slash) : '';
    if (Platform.isWindows) {
      final systemRoot = (parentEnvironment['SystemRoot'] ?? r'C:\Windows')
          .replaceAll('\\', '/');
      return [
        if (executableDirectory.isNotEmpty) executableDirectory,
        '$systemRoot/System32',
        systemRoot,
      ].join(';');
    }
    return [
      if (executableDirectory.isNotEmpty) executableDirectory,
      '/usr/bin',
      '/bin',
      '/usr/sbin',
      '/sbin',
      '/opt/homebrew/bin',
      '/usr/local/bin',
    ].join(':');
  }

  WorkCommandResult _result(
    WorkCommand command,
    WorkCommandPolicyResult policyResult, {
    required WorkCommandRunStatus status,
    required String message,
    int? exitCode,
    String stdout = '',
    String stderr = '',
    Duration elapsed = Duration.zero,
    bool outputTruncated = false,
    WorkCommandInstallSuggestion? installSuggestion,
  }) {
    return WorkCommandResult(
      command: command,
      status: status,
      message: message,
      stdout: stdout,
      stderr: stderr,
      exitCode: exitCode,
      elapsed: elapsed,
      outputTruncated: outputTruncated,
      policy: policyResult,
      installSuggestion: installSuggestion,
    );
  }

  WorkCommandResult _missingExecutableResult(
    WorkCommand command,
    WorkCommandPolicyResult policyResult,
  ) {
    final suggestion = WorkCommandInstallSuggestion.forExecutable(
      command.executable,
      isWindows: policy.isWindows,
      isMacOS: policy.isMacOS,
      workingDirectory: command.workingDirectory,
      declaredImpact: command.declaredImpact,
    );
    return _result(
      command,
      policyResult,
      status: WorkCommandRunStatus.toolMissing,
      message: suggestion.message,
      installSuggestion: suggestion,
    );
  }

  bool _isCancelled(bool Function()? isCancelled) =>
      isCancelled?.call() == true;

  bool _isMissingExecutable(ProcessException error) =>
      error.errorCode == 2 ||
      RegExp(r'no such file|not found|cannot find', caseSensitive: false)
          .hasMatch(error.message);

  String _safeError(Object error) {
    final text = sanitizeWorkTaskError(error);
    return text == '任务执行失败' ? '命令执行失败。' : text;
  }
}

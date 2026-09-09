import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chat_group/features/work_mode/work_command_runner.dart';
import 'package:chat_group/features/work_mode/workspace_path_policy.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeProcess {
  final stdoutController = StreamController<List<int>>();
  final stderrController = StreamController<List<int>>();
  final exitCompleter = Completer<int>();
  bool terminated = false;
  bool forceKilled = false;

  WorkCommandProcess asProcess() => WorkCommandProcess(
        pid: 4242,
        stdout: stdoutController.stream,
        stderr: stderrController.stream,
        exitCode: exitCompleter.future,
        terminateTree: ({bool force = false}) async {
          terminated = true;
          forceKilled = forceKilled || force;
          if (!exitCompleter.isCompleted) {
            exitCompleter.complete(force ? -9 : -15);
          }
        },
      );

  Future<void> close() async {
    await stdoutController.close();
    await stderrController.close();
  }
}

WorkCommand _command({
  String executable = 'pwd',
  List<String> arguments = const [],
  String workingDirectory = '/workspace',
  List<String> declaredImpact = const ['/workspace'],
}) {
  return WorkCommand(
    executable: executable,
    arguments: arguments,
    workingDirectory: workingDirectory,
    declaredImpact: declaredImpact,
  );
}

WorkCommandPolicy _policy() => WorkCommandPolicy(
      authorizedRoots: const ['/workspace'],
      isWindows: false,
    );

void main() {
  test('streams stdout and stderr, runs without a shell, and scrubs env keys',
      () async {
    final process = _FakeProcess();
    bool? runInShell;
    Map<String, String>? environment;
    final chunks = <WorkCommandOutputChunk>[];
    final runner = WorkCommandRunner(
      policy: _policy(),
      parentEnvironment: const {
        'PATH': '/bin',
        'APP_API_KEY': 'should-not-pass',
        'LANG': 'en_US.UTF-8',
        'NODE_OPTIONS': '--require=malicious.js',
        'SAFE_VALUE': 'not-forwarded',
        'UNSAFE_VALUE': 'token=embedded-secret-value',
      },
      processStarter: (command, {required env, required shell}) async {
        environment = env;
        runInShell = shell;
        return process.asProcess();
      },
      onOutput: (chunk) => chunks.add(chunk),
    );

    final future = runner.run(_command(), taskId: 'task-stream');
    process.stdoutController.add(utf8.encode('out-1\n'));
    process.stderrController.add(utf8.encode('err-1\n'));
    await process.stdoutController.close();
    await process.stderrController.close();
    process.exitCompleter.complete(0);

    final result = await future;

    expect(result.status, WorkCommandRunStatus.completed);
    expect(result.exitCode, 0);
    expect(result.stdout, contains('out-1'));
    expect(result.stderr, contains('err-1'));
    expect(
        chunks.map((chunk) => chunk.stream),
        containsAllInOrder(
            [WorkCommandOutputStream.stdout, WorkCommandOutputStream.stderr]));
    expect(runInShell, isFalse);
    expect(environment, containsPair('LANG', 'en_US.UTF-8'));
    expect(environment!.containsKey('SAFE_VALUE'), isFalse);
    expect(environment!.containsKey('NODE_OPTIONS'), isFalse);
    expect(environment!.keys.any((key) => key.contains('API_KEY')), isFalse);
    expect(environment!.containsKey('UNSAFE_VALUE'), isFalse);
  });

  test('does not execute a mutation before approval and returns its plan',
      () async {
    var starts = 0;
    final runner = WorkCommandRunner(
      policy: _policy(),
      processStarter: (_, {required env, required shell}) async {
        starts++;
        return _FakeProcess().asProcess();
      },
    );

    final result = await runner.run(
      _command(executable: 'mv', arguments: ['a.txt', 'b.txt']),
      taskId: 'task-approval',
    );

    expect(result.status, WorkCommandRunStatus.waitingForApproval);
    expect(result.changePlan, isNotNull);
    expect(starts, 0);
  });

  test('output over the combined limit terminates the process', () async {
    final process = _FakeProcess();
    final runner = WorkCommandRunner(
      policy: _policy(),
      maxOutputBytes: 8,
      processStarter: (_, {required env, required shell}) async =>
          process.asProcess(),
    );

    final future = runner.run(_command(), taskId: 'task-output-limit');
    process.stdoutController.add(utf8.encode('123456789'));
    final result = await future;
    await process.close();

    expect(result.status, WorkCommandRunStatus.outputLimitExceeded);
    expect(process.terminated, isTrue);
    expect(process.forceKilled, isTrue);
    expect(result.outputTruncated, isTrue);
  });

  test('timeout terminates the process tree', () async {
    final process = _FakeProcess();
    final runner = WorkCommandRunner(
      policy: _policy(),
      timeout: const Duration(milliseconds: 10),
      processStarter: (_, {required env, required shell}) async =>
          process.asProcess(),
    );

    final result = await runner.run(_command(), taskId: 'task-timeout');

    expect(result.status, WorkCommandRunStatus.timedOut);
    expect(process.terminated, isTrue);
    expect(process.forceKilled, isTrue);
  });

  test('a hung process launch times out and cleans up a late process',
      () async {
    final launch = Completer<WorkCommandProcess>();
    final lateProcess = _FakeProcess();
    final runner = WorkCommandRunner(
      policy: _policy(),
      timeout: const Duration(milliseconds: 10),
      processStarter: (_, {required env, required shell}) => launch.future,
    );

    final result = await runner.run(_command(), taskId: 'task-launch-timeout');
    expect(result.status, WorkCommandRunStatus.timedOut);

    launch.complete(lateProcess.asProcess());
    await Future<void>.delayed(Duration.zero);
    expect(lateProcess.forceKilled, isTrue);
  });

  test('cancellation terminates the process tree and leaves no running task',
      () async {
    final process = _FakeProcess();
    final cancelled = Completer<void>();
    final runner = WorkCommandRunner(
      policy: _policy(),
      processStarter: (_, {required env, required shell}) async =>
          process.asProcess(),
    );

    final future = runner.run(
      _command(),
      taskId: 'task-cancel',
      cancellation: cancelled.future,
    );
    cancelled.complete();
    final result = await future;

    expect(result.status, WorkCommandRunStatus.cancelled);
    expect(process.terminated, isTrue);
    expect(process.forceKilled, isTrue);
  });

  test('password prompts pause and direct the user to an external terminal',
      () async {
    final process = _FakeProcess();
    final runner = WorkCommandRunner(
      policy: _policy(),
      processStarter: (_, {required env, required shell}) async =>
          process.asProcess(),
    );

    final future = runner.run(_command(), taskId: 'task-password');
    process.stderrController.add(utf8.encode('Password: '));
    final result = await future;

    expect(result.status, WorkCommandRunStatus.pausedForUser);
    expect(result.message, contains('外部终端'));
    expect(result.message, contains('不会代填'));
    expect(process.terminated, isTrue);
  });

  test('password prompts split across chunks still pause without input',
      () async {
    final process = _FakeProcess();
    final runner = WorkCommandRunner(
      policy: _policy(),
      processStarter: (_, {required env, required shell}) async =>
          process.asProcess(),
    );

    final future = runner.run(_command(), taskId: 'task-password-split');
    process.stderrController.add(utf8.encode('Pass'));
    process.stderrController.add(utf8.encode('word: '));
    final result = await future;

    expect(result.status, WorkCommandRunStatus.pausedForUser);
    expect(process.terminated, isTrue);
  });

  test('interactive confirmation menus pause without simulated input',
      () async {
    final process = _FakeProcess();
    final runner = WorkCommandRunner(
      policy: _policy(),
      processStarter: (_, {required env, required shell}) async =>
          process.asProcess(),
    );

    final future = runner.run(_command(), taskId: 'task-menu-prompt');
    process.stdoutController.add(utf8.encode('Do you want to continue? [Y/n]'));
    final result = await future;

    expect(result.status, WorkCommandRunStatus.pausedForUser);
    expect(result.message, contains('交互提示'));
    expect(process.terminated, isTrue);
  });

  test('selection menus pause without simulated input', () async {
    final process = _FakeProcess();
    final runner = WorkCommandRunner(
      policy: _policy(),
      processStarter: (_, {required env, required shell}) async =>
          process.asProcess(),
    );

    final future = runner.run(_command(), taskId: 'task-selection-prompt');
    process.stdoutController.add(utf8.encode('Select an option: [1/2]'));
    final result = await future;

    expect(result.status, WorkCommandRunStatus.pausedForUser);
    expect(process.terminated, isTrue);
  });

  test('ordinary output mentioning continue is not treated as a prompt',
      () async {
    final process = _FakeProcess();
    final runner = WorkCommandRunner(
      policy: _policy(),
      processStarter: (_, {required env, required shell}) async =>
          process.asProcess(),
    );

    final future = runner.run(_command(), taskId: 'task-non-prompt-output');
    process.stdoutController
        .add(utf8.encode('Build can continue without user input.\n'));
    await process.stdoutController.close();
    await process.stderrController.close();
    process.exitCompleter.complete(0);
    final result = await future;

    expect(result.status, WorkCommandRunStatus.completed);
    expect(process.terminated, isFalse);
  });

  test('missing executable returns an install suggestion without installing',
      () async {
    var starts = 0;
    final runner = WorkCommandRunner(
      policy: _policy(),
      processStarter: (_, {required env, required shell}) async {
        starts++;
        throw const ProcessException(
          'rg',
          [],
          'No such file or directory',
          2,
        );
      },
    );

    final result = await runner.run(
      _command(executable: 'rg', arguments: ['TODO']),
      taskId: 'task-missing-tool',
    );

    expect(result.status, WorkCommandRunStatus.toolMissing);
    expect(result.installSuggestion, isNotNull);
    expect(result.installSuggestion!.message, contains('仅在你确认后'));
    expect(starts, 1);
  });

  test(
      'default process starter maps missing executable preflight to toolMissing',
      () async {
    final root = await Directory.systemTemp.createTemp('work-command-missing-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final runner = WorkCommandRunner(
      policy: WorkCommandPolicy(
        authorizedRoots: [root.path],
        isWindows: false,
      ),
      pathPolicy: WorkspacePathPolicy(authorizedRoots: [root.path]),
      parentEnvironment: const {'PATH': ''},
    );

    final result = await runner.run(
      _command(
        executable: 'definitely-missing-work-tool',
        workingDirectory: root.path,
        declaredImpact: [root.path],
      ),
      taskId: 'task-missing-tool-default-starter',
      approvalGranted: true,
    );

    expect(result.status, WorkCommandRunStatus.toolMissing);
    expect(result.installSuggestion, isNotNull);
    expect(result.message, contains('缺少工具'));
  });

  test('redacts authorization and token output before exposing it', () async {
    final process = _FakeProcess();
    final runner = WorkCommandRunner(
      policy: _policy(),
      processStarter: (_, {required env, required shell}) async =>
          process.asProcess(),
    );

    final future = runner.run(_command(), taskId: 'task-redact');
    process.stdoutController.add(
      utf8.encode('Authorization: Bearer abcdefghijklmnop\ntoken=secret-value'),
    );
    await process.stdoutController.close();
    await process.stderrController.close();
    process.exitCompleter.complete(0);
    final result = await future;

    expect(result.stdout, isNot(contains('abcdefghijklmnop')));
    expect(result.stdout, isNot(contains('secret-value')));
    expect(result.stdout, contains('[REDACTED]'));
  });

  test('redacts a credential split across output chunks', () async {
    final process = _FakeProcess();
    final runner = WorkCommandRunner(
      policy: _policy(),
      processStarter: (_, {required env, required shell}) async =>
          process.asProcess(),
    );

    final future = runner.run(_command(), taskId: 'task-redact-split');
    process.stdoutController.add(utf8.encode('Authorization: Bearer abc'));
    process.stdoutController.add(utf8.encode('defghijklmnop\n'));
    await process.stdoutController.close();
    await process.stderrController.close();
    process.exitCompleter.complete(0);
    final result = await future;

    expect(result.stdout, isNot(contains('abcdefghijklmnop')));
    expect(result.stdout, contains('[REDACTED]'));
  });

  test('rejects a command argument whose symlink escapes the granted folder',
      () async {
    if (Platform.isWindows) return;
    final root = await Directory.systemTemp.createTemp('command-path-root-');
    final outside = await Directory.systemTemp.createTemp('command-path-out-');
    try {
      final secret = File('${outside.path}/secret.txt');
      await secret.writeAsString('not for the task');
      await Link('${root.path}/secret.txt').create(secret.path);
      var starts = 0;
      final runner = WorkCommandRunner(
        policy: WorkCommandPolicy(
          authorizedRoots: [root.path],
          isWindows: false,
        ),
        pathPolicy: WorkspacePathPolicy(authorizedRoots: [root.path]),
        processStarter: (_, {required env, required shell}) async {
          starts++;
          return _FakeProcess().asProcess();
        },
      );

      final result = await runner.run(
        _command(
          executable: 'cat',
          arguments: const ['secret.txt'],
          workingDirectory: root.path,
          declaredImpact: [root.path],
        ),
        taskId: 'task-symlink-escape',
      );

      expect(result.status, WorkCommandRunStatus.pathRejected);
      expect(result.message, contains('符号链接'));
      expect(starts, 0);
    } finally {
      await root.delete(recursive: true);
      await outside.delete(recursive: true);
    }
  });

  test('rejects a relative declared impact whose symlink escapes the grant',
      () async {
    if (Platform.isWindows) return;
    final root = await Directory.systemTemp.createTemp('impact-path-root-');
    final outside = await Directory.systemTemp.createTemp('impact-path-out-');
    try {
      await Link('${root.path}/out').create(outside.path);
      var starts = 0;
      final runner = WorkCommandRunner(
        policy: WorkCommandPolicy(
          authorizedRoots: [root.path],
          isWindows: false,
        ),
        pathPolicy: WorkspacePathPolicy(authorizedRoots: [root.path]),
        processStarter: (_, {required env, required shell}) async {
          starts++;
          return _FakeProcess().asProcess();
        },
      );

      final result = await runner.run(
        _command(
          workingDirectory: root.path,
          declaredImpact: const ['out'],
        ),
        taskId: 'task-relative-impact-symlink',
      );

      expect(result.status, WorkCommandRunStatus.pathRejected);
      expect(result.message, contains('符号链接'));
      expect(starts, 0);
    } finally {
      await root.delete(recursive: true);
      await outside.delete(recursive: true);
    }
  });

  test('performs DNS SSRF validation before a hostname network command starts',
      () async {
    var starts = 0;
    final runner = WorkCommandRunner(
      policy: _policy(),
      dnsResolver: (_) async => [InternetAddress.loopbackIPv4],
      processStarter: (_, {required env, required shell}) async {
        starts++;
        return _FakeProcess().asProcess();
      },
    );

    final result = await runner.run(
      _command(
        executable: 'curl',
        arguments: const ['https://public.example/data'],
      ),
      taskId: 'task-dns-ssrf',
    );

    expect(result.status, WorkCommandRunStatus.blockedByDefault);
    expect(result.message, contains('公网'));
    expect(starts, 0);
  });

  test('disables implicit curl and wget configuration and redirects', () async {
    final captured = <WorkCommand>[];
    final processes = <_FakeProcess>[];
    final runner = WorkCommandRunner(
      policy: _policy(),
      dnsResolver: (_) async => [InternetAddress('93.184.216.34')],
      processStarter: (command, {required env, required shell}) async {
        captured.add(command);
        final process = _FakeProcess();
        processes.add(process);
        scheduleMicrotask(() {
          if (!process.exitCompleter.isCompleted) {
            process.exitCompleter.complete(0);
          }
          unawaited(process.stdoutController.close());
          unawaited(process.stderrController.close());
        });
        return process.asProcess();
      },
    );

    final curl = await runner.run(
      _command(
        executable: 'curl',
        arguments: const ['https://public.example/data'],
      ),
      taskId: 'task-curl-config-safety',
    );
    final wget = await runner.run(
      _command(
        executable: 'wget',
        arguments: const ['--spider', 'https://public.example/data'],
      ),
      taskId: 'task-wget-config-safety',
    );

    expect(curl.status, WorkCommandRunStatus.completed);
    expect(wget.status, WorkCommandRunStatus.completed);
    expect(captured, hasLength(2));
    expect(captured[0].arguments, contains('-q'));
    expect(captured[1].arguments, contains('--no-config'));
    expect(captured[1].arguments, contains('--max-redirect=0'));
    expect(processes, hasLength(2));
  });

  test('moves a trailing curl -q guard to the first option position', () async {
    WorkCommand? captured;
    final runner = WorkCommandRunner(
      policy: _policy(),
      dnsResolver: (_) async => [InternetAddress('93.184.216.34')],
      processStarter: (command, {required env, required shell}) async {
        captured = command;
        final process = _FakeProcess();
        scheduleMicrotask(() {
          if (!process.exitCompleter.isCompleted) {
            process.exitCompleter.complete(0);
          }
          unawaited(process.stdoutController.close());
          unawaited(process.stderrController.close());
        });
        return process.asProcess();
      },
    );

    final result = await runner.run(
      _command(
        executable: 'curl',
        arguments: const ['https://public.example/data', '-q'],
      ),
      taskId: 'task-curl-q-position',
    );

    expect(result.status, WorkCommandRunStatus.completed);
    expect(captured?.arguments.first, '-q');
  });

  test('rejects repeated wget redirect options when any value is non-zero',
      () async {
    var starts = 0;
    final runner = WorkCommandRunner(
      policy: _policy(),
      dnsResolver: (_) async => [InternetAddress('93.184.216.34')],
      processStarter: (_, {required env, required shell}) async {
        starts++;
        return _FakeProcess().asProcess();
      },
    );

    final result = await runner.run(
      _command(
        executable: 'wget',
        arguments: const [
          '--spider',
          '--max-redirect=0',
          '--max-redirect=3',
          'https://public.example/data',
        ],
      ),
      taskId: 'task-wget-duplicate-redirect',
    );

    expect(result.status, WorkCommandRunStatus.blockedByDefault);
    expect(starts, 0);
  });

  test('rejects negative wget redirect limits', () async {
    var starts = 0;
    final runner = WorkCommandRunner(
      policy: _policy(),
      dnsResolver: (_) async => [InternetAddress('93.184.216.34')],
      processStarter: (_, {required env, required shell}) async {
        starts++;
        return _FakeProcess().asProcess();
      },
    );

    final result = await runner.run(
      _command(
        executable: 'wget',
        arguments: const [
          '--spider',
          '--max-redirect=-1',
          'https://public.example/data'
        ],
      ),
      taskId: 'task-wget-negative-redirect',
    );

    expect(result.status, WorkCommandRunStatus.blockedByDefault);
    expect(starts, 0);
  });

  test('rejects curl @file references outside the workspace', () async {
    var starts = 0;
    final runner = WorkCommandRunner(
      policy: _policy(),
      processStarter: (_, {required env, required shell}) async {
        starts++;
        return _FakeProcess().asProcess();
      },
    );

    final result = await runner.run(
      _command(
        executable: 'curl',
        arguments: const [
          '--data',
          '@../outside.txt',
          'https://public.example/hook'
        ],
      ),
      taskId: 'task-curl-at-file',
      approvalGranted: true,
    );

    expect(result.status, WorkCommandRunStatus.pathRejected);
    expect(starts, 0);
  });

  test('resolves a bare executable and rejects a PATH shadow for auto reads',
      () async {
    if (Platform.isWindows) return;
    final directory = await Directory.systemTemp.createTemp('command-resolve-');
    final shadowDirectory =
        await Directory.systemTemp.createTemp('command-shadow-');
    try {
      await File('${shadowDirectory.path}/pwd').writeAsString('not executable');
      final policy = WorkCommandPolicy(
        authorizedRoots: [directory.path],
        isWindows: false,
      );
      final pathPolicy = WorkspacePathPolicy(authorizedRoots: [directory.path]);
      final runner = WorkCommandRunner(
        policy: policy,
        pathPolicy: pathPolicy,
        parentEnvironment: {
          'PATH': '${shadowDirectory.path}:/usr/bin:/bin',
          'LANG': 'C',
        },
      );
      final result = await runner.run(
        _command(
          workingDirectory: directory.path,
          declaredImpact: [directory.path],
        ),
        taskId: 'task-executable-shadow',
      );

      expect(result.status, WorkCommandRunStatus.blockedByDefault);
      expect(result.message, contains('不受信任'));
    } finally {
      await directory.delete(recursive: true);
      await shadowDirectory.delete(recursive: true);
    }
  });

  test('resolves a relative executable from the command working directory',
      () async {
    if (Platform.isWindows) return;
    final directory =
        await Directory.systemTemp.createTemp('command-relative-');
    try {
      final executable = File('${directory.path}/local-tool.sh');
      await executable.writeAsString('#!/bin/sh\nprintf relative-ok\n');
      final chmod = await Process.run(
        'chmod',
        ['u+x', executable.path],
        runInShell: false,
      );
      expect(chmod.exitCode, 0);
      final runner = WorkCommandRunner(
        policy: WorkCommandPolicy(
          authorizedRoots: [directory.path],
          isWindows: false,
        ),
        pathPolicy: WorkspacePathPolicy(authorizedRoots: [directory.path]),
      );

      final result = await runner.run(
        _command(
          executable: './local-tool.sh',
          workingDirectory: directory.path,
          declaredImpact: [directory.path],
        ),
        taskId: 'task-relative-executable',
        approvalGranted: true,
      );

      expect(result.status, WorkCommandRunStatus.completed);
      expect(result.stdout, contains('relative-ok'));
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('explicit validation can use a user-installed bare executable',
      () async {
    if (Platform.isWindows) return;
    final directory =
        await Directory.systemTemp.createTemp('command-explicit-tool-');
    try {
      final executable = File('${directory.path}/flutter');
      await executable.writeAsString('#!/bin/sh\nprintf explicit-ok\n');
      final chmod = await Process.run(
        'chmod',
        ['u+x', executable.path],
        runInShell: false,
      );
      expect(chmod.exitCode, 0);
      final runner = WorkCommandRunner(
        policy: WorkCommandPolicy(
          authorizedRoots: [directory.path],
          isWindows: false,
        ),
        pathPolicy: WorkspacePathPolicy(authorizedRoots: [directory.path]),
        parentEnvironment: {
          'PATH': '${directory.path}:/usr/bin:/bin',
        },
      );

      final result = await runner.run(
        _command(
          executable: 'flutter',
          arguments: const ['analyze'],
          workingDirectory: directory.path,
          declaredImpact: [directory.path],
        ),
        taskId: 'task-explicit-user-tool',
        userExplicitlyRequested: true,
      );

      expect(result.status, WorkCommandRunStatus.completed);
      expect(result.stdout, contains('explicit-ok'));
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('default process starter fails closed without a path resolver',
      () async {
    final current = Directory.current.path;
    final runner = WorkCommandRunner(
      policy: WorkCommandPolicy(
        authorizedRoots: [current],
        isWindows: Platform.isWindows,
      ),
    );

    final result = await runner.run(
      _command(
        workingDirectory: current,
        declaredImpact: [current],
      ),
      taskId: 'task-missing-path-resolver',
    );

    expect(result.status, WorkCommandRunStatus.blockedByDefault);
    expect(result.message, contains('路径解析器'));
  });

  test('rejects attached output paths whose symlink escapes the grant',
      () async {
    if (Platform.isWindows) return;
    final root =
        await Directory.systemTemp.createTemp('command-attached-root-');
    final outside =
        await Directory.systemTemp.createTemp('command-attached-out-');
    try {
      await Link('${root.path}/alias').create(outside.path);
      var starts = 0;
      final runner = WorkCommandRunner(
        policy: WorkCommandPolicy(
          authorizedRoots: [root.path],
          isWindows: false,
        ),
        pathPolicy: WorkspacePathPolicy(authorizedRoots: [root.path]),
        dnsResolver: (_) async => [InternetAddress('93.184.216.34')],
        processStarter: (_, {required env, required shell}) async {
          starts++;
          return _FakeProcess().asProcess();
        },
      );

      final result = await runner.run(
        _command(
          executable: 'curl',
          arguments: const ['-o./alias', 'https://public.example/data'],
          workingDirectory: root.path,
          declaredImpact: [root.path],
        ),
        taskId: 'task-attached-symlink',
        approvalGranted: true,
      );

      expect(result.status, WorkCommandRunStatus.pathRejected);
      expect(result.message, contains('符号链接'));
      expect(starts, 0);
    } finally {
      await root.delete(recursive: true);
      await outside.delete(recursive: true);
    }
  });

  test('rejects wget redirect limits above zero even when the host is public',
      () async {
    var starts = 0;
    final runner = WorkCommandRunner(
      policy: _policy(),
      dnsResolver: (_) async => [InternetAddress('93.184.216.34')],
      processStarter: (_, {required env, required shell}) async {
        starts++;
        return _FakeProcess().asProcess();
      },
    );

    final result = await runner.run(
      _command(
        executable: 'wget',
        arguments: const [
          '--spider',
          '--max-redirect=3',
          'https://public.example/data',
        ],
      ),
      taskId: 'task-wget-redirect',
    );

    expect(result.status, WorkCommandRunStatus.blockedByDefault);
    expect(result.message, contains('重定向'));
    expect(starts, 0);
  });

  test('rejects curl redirect flags even when the host is public', () async {
    var starts = 0;
    final runner = WorkCommandRunner(
      policy: _policy(),
      dnsResolver: (_) async => [InternetAddress('93.184.216.34')],
      processStarter: (_, {required env, required shell}) async {
        starts++;
        return _FakeProcess().asProcess();
      },
    );

    final result = await runner.run(
      _command(
        executable: 'curl',
        arguments: const ['-sSL', 'https://public.example/data'],
      ),
      taskId: 'task-curl-redirect',
      approvalGranted: true,
    );

    expect(result.status, WorkCommandRunStatus.blockedByDefault);
    expect(result.message, contains('重定向'));
    expect(starts, 0);
  });

  test('rejects curl routing overrides before a public URL can reach localhost',
      () async {
    var starts = 0;
    final runner = WorkCommandRunner(
      policy: _policy(),
      dnsResolver: (_) async => [InternetAddress('93.184.216.34')],
      processStarter: (_, {required env, required shell}) async {
        starts++;
        return _FakeProcess().asProcess();
      },
    );

    final result = await runner.run(
      _command(
        executable: 'curl',
        arguments: const [
          '--resolve',
          'public.example:443:127.0.0.1',
          'https://public.example/data',
        ],
      ),
      taskId: 'task-curl-resolve-runtime',
      approvalGranted: true,
    );

    expect(result.status, WorkCommandRunStatus.blockedByDefault);
    expect(result.message, contains('公网目标'));
    expect(starts, 0);
  });

  test('rejects curl proxies and hidden config even with explicit approval',
      () async {
    for (final arguments in [
      const ['--proxy', 'http://127.0.0.1:8080', 'https://public.example/data'],
      const [
        '--preproxy',
        'http://proxy.example:8080',
        'https://public.example/data'
      ],
      const [
        '--proxy1.0',
        'http://proxy.example:8080',
        'https://public.example/data'
      ],
      const [
        '--doh-url',
        'https://resolver.example/dns',
        'https://public.example/data'
      ],
      const ['--abstract-unix-socket', 'socket', 'https://public.example/data'],
      const ['--url-query', '@query.txt', 'https://public.example/data'],
      const ['-K/workspace/curl.conf', 'https://public.example/data'],
    ]) {
      var starts = 0;
      final runner = WorkCommandRunner(
        policy: _policy(),
        dnsResolver: (_) async => [InternetAddress('93.184.216.34')],
        processStarter: (_, {required env, required shell}) async {
          starts++;
          return _FakeProcess().asProcess();
        },
      );

      final result = await runner.run(
        _command(executable: 'curl', arguments: arguments),
        taskId: 'task-curl-routing-${arguments.first}',
        approvalGranted: true,
      );

      expect(result.status, WorkCommandRunStatus.blockedByDefault);
      expect(result.message, contains('公网目标'));
      expect(starts, 0);
    }
  });

  test('rejects network URL userinfo before DNS or process launch', () async {
    var starts = 0;
    var dnsCalls = 0;
    final runner = WorkCommandRunner(
      policy: _policy(),
      dnsResolver: (_) async {
        dnsCalls++;
        return [InternetAddress('93.184.216.34')];
      },
      processStarter: (_, {required env, required shell}) async {
        starts++;
        return _FakeProcess().asProcess();
      },
    );

    final result = await runner.run(
      _command(
        executable: 'curl',
        arguments: const ['https://user:password@public.example/data'],
      ),
      taskId: 'task-url-userinfo',
      approvalGranted: true,
    );

    expect(result.status, WorkCommandRunStatus.blockedByDefault);
    expect(result.message, contains('用户名或密码'));
    expect(dnsCalls, 0);
    expect(starts, 0);
  });

  test('rejects non-HTTP(S) network targets before the process starts',
      () async {
    var starts = 0;
    final runner = WorkCommandRunner(
      policy: _policy(),
      dnsResolver: (_) async => [InternetAddress('93.184.216.34')],
      processStarter: (_, {required env, required shell}) async {
        starts++;
        return _FakeProcess().asProcess();
      },
    );

    final result = await runner.run(
      _command(
        executable: 'curl',
        arguments: const ['ftp://public.example/data'],
      ),
      taskId: 'task-non-http-network',
      approvalGranted: true,
    );

    expect(result.status, WorkCommandRunStatus.blockedByDefault);
    expect(result.message, contains('HTTP(S)'));
    expect(starts, 0);
  });

  test('macOS timeout leaves no parent or child process', () async {
    if (Platform.isWindows) return;
    final directory = await Directory.systemTemp.createTemp('command-timeout-');
    try {
      final pidFile = File('${directory.path}/pids');
      final command = _sleepingShellCommand(directory.path, pidFile.path);
      final runner = WorkCommandRunner(
        policy: WorkCommandPolicy(
          authorizedRoots: [directory.path],
          isWindows: false,
        ),
        pathPolicy: WorkspacePathPolicy(authorizedRoots: [directory.path]),
        timeout: const Duration(milliseconds: 250),
        terminationGrace: const Duration(milliseconds: 50),
      );

      final result = await runner.run(
        command,
        taskId: 'task-real-timeout',
        approvalGranted: true,
      );

      expect(result.status, WorkCommandRunStatus.timedOut);
      await _waitForFile(pidFile);
      await _expectPidsGone(await pidFile.readAsLines());
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('macOS cancellation leaves no parent or child process', () async {
    if (Platform.isWindows) return;
    final directory = await Directory.systemTemp.createTemp('command-cancel-');
    try {
      final pidFile = File('${directory.path}/pids');
      final command = _sleepingShellCommand(directory.path, pidFile.path);
      final cancellation = Completer<void>();
      final runner = WorkCommandRunner(
        policy: WorkCommandPolicy(
          authorizedRoots: [directory.path],
          isWindows: false,
        ),
        pathPolicy: WorkspacePathPolicy(authorizedRoots: [directory.path]),
        timeout: const Duration(seconds: 2),
        terminationGrace: const Duration(milliseconds: 50),
      );

      final future = runner.run(
        command,
        taskId: 'task-real-cancel',
        approvalGranted: true,
        cancellation: cancellation.future,
      );
      await _waitForFile(pidFile);
      cancellation.complete();
      final result = await future;

      expect(result.status, WorkCommandRunStatus.cancelled);
      await _expectPidsGone(await pidFile.readAsLines());
    } finally {
      await directory.delete(recursive: true);
    }
  });
}

WorkCommand _sleepingShellCommand(String workingDirectory, String pidPath) {
  final script = 'printf "%s\\n" "\$\$" > "$pidPath"; '
      'sleep 30 & child=\$!; printf "%s\\n" "\$child" >> "$pidPath"; '
      'wait "\$child"';
  return WorkCommand(
    executable: '/bin/sh',
    arguments: ['-c', script],
    workingDirectory: workingDirectory,
    declaredImpact: [workingDirectory],
  );
}

Future<void> _waitForFile(File file) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (await file.exists() && (await file.readAsLines()).length >= 2) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('父子进程未在期限内写入完整 PID 文件：${file.path}');
}

Future<void> _expectPidsGone(List<String> lines) async {
  final pids =
      lines.map((line) => int.tryParse(line.trim())).whereType<int>().toList();
  expect(pids, hasLength(2));
  for (final pid in pids) {
    var stillRunning = '';
    for (var attempt = 0; attempt < 20; attempt++) {
      final probe = await Process.run(
        'ps',
        ['-p', '$pid', '-o', 'pid=,ppid=,stat=,command='],
        runInShell: false,
      );
      stillRunning = probe.stdout.toString().trim();
      if (stillRunning.isEmpty) break;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    expect(stillRunning, isEmpty, reason: 'PID $pid 仍存在');
  }
}

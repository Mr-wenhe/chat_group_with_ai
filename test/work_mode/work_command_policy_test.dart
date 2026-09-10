import 'package:chat_group/features/work_mode/work_change_plan.dart';
import 'package:chat_group/features/work_mode/work_command_policy.dart';
import 'package:flutter_test/flutter_test.dart';

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

void main() {
  final policy = WorkCommandPolicy(
    authorizedRoots: const ['/workspace'],
    isWindows: false,
  );

  test('pwd, git status and rg are read-only and automatic', () {
    for (final command in [
      _command(),
      _command(executable: 'git', arguments: ['status', '--short']),
      _command(executable: 'rg', arguments: ['TODO', 'lib']),
    ]) {
      final result = policy.evaluate(command, taskId: 'task-read');

      expect(result.allowed, isTrue);
      expect(result.impact, WorkCommandImpact.readOnly);
      expect(result.requiresApproval, isFalse);
      expect(result.changePlan, isNull);
    }
  });

  test('global git options and rg count are not mistaken for shell flags', () {
    final rg = policy.evaluate(
      _command(executable: 'rg', arguments: ['-c', 'TODO']),
      taskId: 'task-rg-count',
    );
    final git = policy.evaluate(
      _command(
        executable: 'git',
        arguments: ['-c', 'color.ui=false', 'status', '--short'],
      ),
      taskId: 'task-git-config-status',
    );

    expect(rg.impact, WorkCommandImpact.readOnly);
    expect(rg.requiresApproval, isFalse);
    expect(git.impact, WorkCommandImpact.readOnly);
    expect(git.requiresApproval, isFalse);
  });

  test('path-qualified read-only executables require explicit approval', () {
    final result = policy.evaluate(
      _command(executable: '/tmp/rg', arguments: ['TODO']),
      taskId: 'task-untrusted-executable',
    );

    expect(result.allowed, isTrue);
    expect(result.impact, WorkCommandImpact.impactUncertain);
    expect(result.requiresApproval, isTrue);
    expect(result.changePlan, isNotNull);
  });

  test('curl and wget only auto-run public HTTP(S) reads', () {
    final publicRead = policy.evaluate(
      _command(
        executable: 'curl',
        arguments: ['--request', 'GET', 'https://example.test/data'],
      ),
      taskId: 'task-public-http',
    );
    final shortGet = policy.evaluate(
      _command(
        executable: 'curl',
        arguments: ['-X', 'GET', 'https://example.test/data'],
      ),
      taskId: 'task-short-get',
    );
    final inlineHead = policy.evaluate(
      _command(
        executable: 'curl',
        arguments: ['-XHEAD', 'https://example.test/data'],
      ),
      taskId: 'task-inline-head',
    );
    final inlinePost = policy.evaluate(
      _command(
        executable: 'curl',
        arguments: ['-XPOST', 'https://example.test/hook'],
      ),
      taskId: 'task-inline-post',
    );
    final upload = policy.evaluate(
      _command(
        executable: 'curl',
        arguments: [
          '-T',
          '/workspace/input.txt',
          'https://example.test/upload'
        ],
      ),
      taskId: 'task-curl-upload',
    );
    final formString = policy.evaluate(
      _command(
        executable: 'curl',
        arguments: ['--form-string', 'name=value', 'https://example.test/form'],
      ),
      taskId: 'task-curl-form-string',
    );
    final configFile = policy.evaluate(
      _command(
        executable: 'curl',
        arguments: ['-K', '/workspace/curl.conf', 'https://example.test/data'],
      ),
      taskId: 'task-curl-config',
    );
    final redirectCluster = policy.evaluate(
      _command(
        executable: 'curl',
        arguments: ['-sSL', 'https://example.test/data'],
      ),
      taskId: 'task-curl-redirect-cluster',
    );
    final loopback = policy.evaluate(
      _command(executable: 'curl', arguments: ['http://127.0.0.1:8080/admin']),
      taskId: 'task-loopback-http',
    );
    final mappedLoopback = policy.evaluate(
      _command(
        executable: 'curl',
        arguments: ['http://[::ffff:127.0.0.1]/admin'],
      ),
      taskId: 'task-mapped-loopback-http',
    );
    final localFile = policy.evaluate(
      _command(executable: 'wget', arguments: ['file:///tmp/secrets.txt']),
      taskId: 'task-file-url',
    );
    final wgetDownload = policy.evaluate(
      _command(executable: 'wget', arguments: ['https://example.test/data']),
      taskId: 'task-wget-download',
    );
    final wgetHead = policy.evaluate(
      _command(
        executable: 'wget',
        arguments: ['--spider', 'https://example.test/data'],
      ),
      taskId: 'task-wget-head',
    );
    final downloadedFile = policy.evaluate(
      _command(
          executable: 'curl', arguments: ['-O', 'https://example.test/data']),
      taskId: 'task-curl-download',
    );
    final resolvedLocalHost = policy.evaluate(
      _command(
        executable: 'curl',
        arguments: [
          '--resolve',
          'example.test:443:127.0.0.1',
          'https://example.test/data'
        ],
      ),
      taskId: 'task-curl-resolve',
    );
    final redirectedRead = policy.evaluate(
      _command(
          executable: 'curl', arguments: ['-L', 'https://example.test/data']),
      taskId: 'task-curl-redirect',
    );

    expect(publicRead.impact, WorkCommandImpact.readOnly);
    expect(publicRead.requiresApproval, isFalse);
    expect(shortGet.impact, WorkCommandImpact.readOnly);
    expect(shortGet.requiresApproval, isFalse);
    expect(inlineHead.impact, WorkCommandImpact.readOnly);
    expect(inlineHead.requiresApproval, isFalse);
    expect(inlinePost.impact, WorkCommandImpact.externalMutation);
    expect(inlinePost.requiresApproval, isTrue);
    expect(upload.impact, WorkCommandImpact.externalMutation);
    expect(upload.requiresApproval, isTrue);
    expect(formString.impact, WorkCommandImpact.externalMutation);
    expect(formString.requiresApproval, isTrue);
    expect(configFile.impact, WorkCommandImpact.impactUncertain);
    expect(configFile.requiresApproval, isTrue);
    expect(redirectCluster.impact, WorkCommandImpact.impactUncertain);
    expect(redirectCluster.requiresApproval, isTrue);
    expect(loopback.impact, WorkCommandImpact.impactUncertain);
    expect(loopback.requiresApproval, isTrue);
    expect(mappedLoopback.impact, WorkCommandImpact.impactUncertain);
    expect(mappedLoopback.requiresApproval, isTrue);
    expect(localFile.impact, WorkCommandImpact.impactUncertain);
    expect(localFile.requiresApproval, isTrue);
    expect(wgetDownload.impact, WorkCommandImpact.impactUncertain);
    expect(wgetDownload.requiresApproval, isTrue);
    expect(wgetHead.impact, WorkCommandImpact.readOnly);
    expect(wgetHead.requiresApproval, isFalse);
    expect(downloadedFile.impact, WorkCommandImpact.localMutation);
    expect(downloadedFile.requiresApproval, isTrue);
    expect(resolvedLocalHost.impact, WorkCommandImpact.impactUncertain);
    expect(resolvedLocalHost.requiresApproval, isTrue);
    expect(redirectedRead.impact, WorkCommandImpact.impactUncertain);
    expect(redirectedRead.requiresApproval, isTrue);
  });

  test('explicit validation requests are shared with the task coordinator', () {
    expect(isExplicitWorkValidationRequest('请测试当前修改'), isTrue);
    expect(isExplicitWorkValidationRequest('请运行 flutter build macos'), isTrue);
    expect(isExplicitWorkValidationRequest('请运行测试，但不要构建'), isTrue);
    expect(isExplicitWorkValidationRequest('不要测试，但请运行 flutter build'), isTrue);
    expect(isExplicitWorkValidationRequest('不要运行测试'), isFalse);
    expect(isExplicitWorkValidationRequest('默认不要测试'), isFalse);
    expect(isExplicitWorkValidationRequest('默认不跑 flutter test'), isFalse);
    expect(
      isExplicitWorkValidationRequest('默认不要测试\n用户明确要求：请运行 flutter test'),
      isTrue,
    );
    expect(
      isExplicitWorkValidationRequest('用户明确要求：不要运行 flutter test'),
      isFalse,
    );
  });

  test('curl routing and DNS overrides never qualify for automatic reads', () {
    for (final arguments in [
      const ['--preproxy', 'http://proxy.example', 'https://example.test/data'],
      const ['--proxy1.0', 'http://proxy.example', 'https://example.test/data'],
      const [
        '--doh-url',
        'https://resolver.example/dns',
        'https://example.test/data'
      ],
      const ['--dns-interface', 'en0', 'https://example.test/data'],
      const ['--abstract-unix-socket', 'sock', 'https://example.test/data'],
      const ['--url-query', '@secrets.txt', 'https://example.test/data'],
    ]) {
      final result = policy.evaluate(
        _command(executable: 'curl', arguments: arguments),
        taskId: 'task-curl-routing-override',
      );

      expect(result.allowed, isTrue);
      expect(result.impact, WorkCommandImpact.impactUncertain);
      expect(result.requiresApproval, isTrue);
    }
  });

  test('redirects, sed -i, move, delete, install and build are mutations', () {
    final cases = <WorkCommand>[
      _command(executable: 'echo', arguments: ['hello', '>', 'out.txt']),
      _command(executable: 'sed', arguments: ['-i', 's/a/b/', 'file.txt']),
      _command(executable: 'mv', arguments: ['a.txt', 'b.txt']),
      _command(executable: 'rm', arguments: ['a.txt']),
      _command(executable: 'brew', arguments: ['install', 'rg']),
      _command(executable: 'flutter', arguments: ['build', 'macos']),
    ];

    for (final command in cases) {
      final result = policy.evaluate(
        command,
        taskId: 'task-mutation',
        userExplicitlyRequested: command.arguments.contains('build'),
      );

      expect(result.allowed, isTrue);
      expect(result.impact.isMutation, isTrue, reason: command.displayCommand);
      expect(result.requiresApproval, isTrue, reason: command.displayCommand);
      expect(result.changePlan, isNotNull, reason: command.displayCommand);
      expect(result.changePlan!.actionType, WorkChangeActionType.command);
    }
  });

  test('in-place edits and redirects get a separate confirmation', () {
    final redirect = policy.evaluate(
      _command(executable: 'echo', arguments: ['hello', '>', 'out.txt']),
      taskId: 'task-redirect-confirmation',
    );
    final sed = policy.evaluate(
      _command(executable: 'sed', arguments: ['-i', 's/a/b/', 'file.txt']),
      taskId: 'task-sed-confirmation',
    );

    expect(redirect.requiresSeparateConfirmation, isTrue);
    expect(sed.impact, WorkCommandImpact.localMutation);
    expect(sed.requiresSeparateConfirmation, isTrue);
  });

  test('external writes are distinguished from local mutations', () {
    final gitPush = policy.evaluate(
      _command(executable: 'git', arguments: ['push', 'origin', 'main']),
      taskId: 'task-git-push',
    );
    final curlPost = policy.evaluate(
      _command(
        executable: 'curl',
        arguments: ['-X', 'POST', 'https://example.test/hook'],
      ),
      taskId: 'task-curl-post',
    );

    expect(gitPush.impact, WorkCommandImpact.externalMutation);
    expect(gitPush.changePlan, isNotNull);
    expect(curlPost.impact, WorkCommandImpact.externalMutation);
    expect(curlPost.requiresApproval, isTrue);
  });

  test('output files and find execution flags cannot hide local writes', () {
    final gitDiffOutput = policy.evaluate(
      _command(
        executable: 'git',
        arguments: ['diff', '--output=/workspace/diff.txt'],
      ),
      taskId: 'task-git-output',
    );
    final curlOutput = policy.evaluate(
      _command(
        executable: 'curl',
        arguments: ['-o', '/workspace/page.html', 'https://example.test'],
      ),
      taskId: 'task-curl-output',
    );
    final findDelete = policy.evaluate(
      _command(executable: 'find', arguments: ['.', '-delete']),
      taskId: 'task-find-delete',
    );

    expect(gitDiffOutput.impact, WorkCommandImpact.localMutation);
    expect(curlOutput.impact, WorkCommandImpact.localMutation);
    expect(findDelete.impact, WorkCommandImpact.localMutation);
    expect(gitDiffOutput.changePlan, isNotNull);
    expect(curlOutput.changePlan, isNotNull);
    expect(findDelete.changePlan, isNotNull);
  });

  test('absolute command arguments cannot escape authorized roots', () {
    final outside = policy.evaluate(
      _command(
        executable: 'git',
        arguments: ['-C', '/outside', 'status'],
      ),
      taskId: 'task-argument-boundary',
    );
    final traversal = policy.evaluate(
      _command(executable: 'rg', arguments: ['../outside']),
      taskId: 'task-argument-traversal',
    );

    expect(outside.allowed, isFalse);
    expect(outside.rejectionReason, contains('授权目录'));
    expect(traversal.allowed, isFalse);
    expect(traversal.rejectionReason, contains('路径'));
  });

  test('attached command options cannot hide an outside path', () {
    final output = policy.evaluate(
      _command(
        executable: 'curl',
        arguments: const ['-o../outside.html', 'https://example.test/data'],
      ),
      taskId: 'task-attached-output-boundary',
    );
    final upload = policy.evaluate(
      _command(
        executable: 'curl',
        arguments: const [
          '--data=@../outside.txt',
          'https://example.test/hook'
        ],
      ),
      taskId: 'task-attached-upload-boundary',
    );

    expect(output.allowed, isFalse);
    expect(output.rejectionReason, contains('路径'));
    expect(upload.allowed, isFalse);
    expect(upload.rejectionReason, contains('路径'));
  });

  test('curl @file bodies are validated as local paths', () {
    final result = policy.evaluate(
      _command(
        executable: 'curl',
        arguments: const [
          '--data',
          '@../outside.txt',
          'https://example.test/hook'
        ],
      ),
      taskId: 'task-at-file-boundary',
      userExplicitlyRequested: true,
    );

    expect(result.allowed, isFalse);
    expect(result.rejectionReason, contains('不能包含 ..'));
  });

  test('declared impact paths cannot traverse outside authorized roots', () {
    final result = policy.evaluate(
      _command(declaredImpact: const ['../outside']),
      taskId: 'task-impact-traversal',
    );

    expect(result.allowed, isFalse);
    expect(result.rejectionReason, contains('路径'));
  });

  test('relative declared impact paths are included in the approval plan', () {
    final result = policy.evaluate(
      _command(
        executable: 'touch',
        arguments: const ['src/generated/link'],
        declaredImpact: const ['src/generated/link'],
      ),
      taskId: 'task-relative-impact',
    );

    expect(result.allowed, isTrue);
    expect(result.changePlan, isNotNull);
    expect(
      result.changePlan!.knownAffectedDirectories,
      contains('/workspace/src/generated/link'),
    );
  });

  test('a pipe is always impact-uncertain and requires approval', () {
    final result = policy.evaluate(
      _command(executable: 'rg', arguments: ['TODO', '|', 'wc', '-l']),
      taskId: 'task-pipe',
    );

    expect(result.impact, WorkCommandImpact.impactUncertain);
    expect(result.requiresApproval, isTrue);
    expect(result.changePlan, isNotNull);
    expect(result.changePlan!.impactUncertain, isTrue);
  });

  test('rejects a working directory outside authorized roots', () {
    final result = policy.evaluate(
      _command(workingDirectory: '/outside'),
      taskId: 'task-boundary',
    );

    expect(result.allowed, isFalse);
    expect(result.rejectionReason, contains('授权目录'));
    expect(result.changePlan, isNull);
  });

  test('build and test stay blocked until explicitly requested', () {
    final command = _command(executable: 'flutter', arguments: ['test']);

    final defaultResult = policy.evaluate(command, taskId: 'task-default');
    expect(defaultResult.allowed, isFalse);
    expect(defaultResult.requiresExplicitRequest, isTrue);
    expect(defaultResult.changePlan, isNotNull);
    expect(defaultResult.changePlan!.actionType, WorkChangeActionType.command);

    final explicitResult = policy.evaluate(
      command,
      taskId: 'task-explicit',
      userExplicitlyRequested: true,
    );
    expect(explicitResult.allowed, isTrue);
    expect(explicitResult.requiresApproval, isTrue);
    expect(explicitResult.changePlan, isNotNull);
  });

  test('common ecosystem test and build commands require an explicit request',
      () {
    final commands = <WorkCommand>[
      _command(executable: 'cargo', arguments: ['test']),
      _command(executable: 'go', arguments: ['test', './...']),
      _command(executable: 'pytest', arguments: ['-q']),
      _command(executable: 'python3', arguments: ['-m', 'pytest']),
      _command(executable: 'dotnet', arguments: ['test']),
      _command(executable: 'bun', arguments: ['test']),
    ];

    for (final command in commands) {
      final result = policy.evaluate(command, taskId: 'task-gate');
      expect(result.allowed, isFalse, reason: command.displayCommand);
      expect(result.requiresExplicitRequest, isTrue,
          reason: command.displayCommand);
      expect(result.changePlan, isNotNull, reason: command.displayCommand);
    }
  });

  test('analyze fix flags are treated as local mutations', () {
    final result = policy.evaluate(
      _command(executable: 'flutter', arguments: ['analyze', '--fix']),
      taskId: 'task-analyze-fix',
    );

    expect(result.impact, WorkCommandImpact.localMutation);
    expect(result.requiresApproval, isTrue);
    expect(result.changePlan, isNotNull);
  });

  test('delete and install require separate confirmation', () {
    final delete = policy.evaluate(
      _command(executable: 'rm', arguments: ['file.txt']),
      taskId: 'task-delete',
    );
    final install = policy.evaluate(
      _command(executable: 'brew', arguments: ['install', 'ripgrep']),
      taskId: 'task-install',
    );

    expect(delete.requiresSeparateConfirmation, isTrue);
    expect(install.requiresSeparateConfirmation, isTrue);
  });

  test('dependency fetches and git commits remain separately confirmed', () {
    final dependencies = policy.evaluate(
      _command(executable: 'dart', arguments: ['pub', 'get']),
      taskId: 'task-pub-get',
    );
    final commit = policy.evaluate(
      _command(executable: 'git', arguments: ['COMMIT', '-am', 'checkpoint']),
      taskId: 'task-git-commit',
    );

    expect(dependencies.impact, WorkCommandImpact.localMutation);
    expect(dependencies.requiresSeparateConfirmation, isTrue);
    expect(commit.requiresSeparateConfirmation, isTrue);
    expect(commit.changePlan, isNotNull);
  });

  test('missing ripgrep suggestion names purpose, source, command and impact',
      () {
    final suggestion = WorkCommandInstallSuggestion.forExecutable(
      'rg',
      isWindows: false,
      isMacOS: true,
      workingDirectory: '/workspace',
      declaredImpact: const ['/workspace'],
    );

    expect(suggestion.purpose.toLowerCase(), contains('search'));
    expect(suggestion.trustedSource, contains('github.com'));
    expect(suggestion.installCommand?.executable, 'brew');
    expect(suggestion.installCommand?.arguments,
        containsAll(<String>['install', 'ripgrep']));
    expect(suggestion.message, contains('/workspace'));
    expect(suggestion.message, contains('仅在你确认后'));
    expect(suggestion.message, contains('系统包管理器目录'));
    expect(suggestion.message, contains('不会加入永久授权'));
  });

  test('missing pandoc suggestion offers a verified package-manager command',
      () {
    final macSuggestion = WorkCommandInstallSuggestion.forExecutable(
      'pandoc',
      isWindows: false,
      isMacOS: true,
      workingDirectory: '/workspace',
      declaredImpact: const ['/workspace/report.pdf'],
    );
    final windowsSuggestion = WorkCommandInstallSuggestion.forExecutable(
      'pandoc',
      isWindows: true,
      workingDirectory: r'C:\workspace',
      declaredImpact: const [r'C:\workspace\report.pdf'],
    );

    expect(macSuggestion.purpose, contains('PDF'));
    expect(macSuggestion.trustedSource, 'https://pandoc.org/installing.html');
    expect(macSuggestion.installCommand?.executable, 'brew');
    expect(
        macSuggestion.installCommand?.arguments, <String>['install', 'pandoc']);
    expect(windowsSuggestion.installCommand?.executable, 'winget');
    expect(windowsSuggestion.installCommand?.arguments, <String>[
      'install',
      '--source',
      'winget',
      '--exact',
      '--id',
      'JohnMacFarlane.Pandoc',
    ]);
    expect(macSuggestion.message, contains('仅在你确认后'));
  });

  test('normalizes Windows executable names and avoids a fake Linux installer',
      () {
    final windowsSuggestion = WorkCommandInstallSuggestion.forExecutable(
      r'pandoc.exe',
      isWindows: true,
      isMacOS: false,
      workingDirectory: r'C:\workspace',
      declaredImpact: const [r'C:\workspace\report.pdf'],
    );
    final linuxSuggestion = WorkCommandInstallSuggestion.forExecutable(
      'pandoc',
      isWindows: false,
      isMacOS: false,
      workingDirectory: '/workspace',
      declaredImpact: const ['/workspace/report.pdf'],
    );

    expect(windowsSuggestion.installCommand?.executable, 'winget');
    expect(linuxSuggestion.installCommand, isNull);
    expect(
      WorkCommandInstallSuggestion.hasTrustedInstaller(
        r'pandoc.exe',
        isWindows: true,
        isMacOS: false,
      ),
      isTrue,
    );
    expect(
      WorkCommandInstallSuggestion.hasTrustedInstaller(
        'pandoc',
        isWindows: false,
        isMacOS: false,
      ),
      isFalse,
    );
  });

  test('unknown missing tools produce guidance without an invented installer',
      () {
    final suggestion = WorkCommandInstallSuggestion.forExecutable(
      'made-up-tool',
      isWindows: false,
      workingDirectory: '/workspace',
      declaredImpact: const ['/workspace'],
    );

    expect(suggestion.installCommand, isNull);
    expect(suggestion.message, contains('官方文档'));
    expect(suggestion.message, contains('无法安全自动安装'));
  });
}

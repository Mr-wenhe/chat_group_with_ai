part of 'work_command_runner.dart';

extension _WorkCommandRunnerSafety on WorkCommandRunner {
  Future<WorkCommand> _prepareCommand(
    WorkCommand command,
    WorkCommandPolicyResult policyResult, {
    required bool userExplicitlyRequested,
  }) async {
    var executable = command.executable;
    if (_usesDefaultProcessStarter) {
      executable = await _resolveExecutable(
        executable,
        policyResult,
        workingDirectory: command.workingDirectory,
        userExplicitlyRequested: userExplicitlyRequested,
      );
    }
    final arguments = List<String>.from(command.arguments);
    final name = _commandBasename(executable).toLowerCase();
    if (name == 'curl' && (arguments.isEmpty || arguments.first != '-q')) {
      // curl only disables ~/.curlrc when -q is the first option. A trailing
      // -q is accepted by curl but is too late to prevent config loading, so
      // always move the guard to the first position (a duplicate is harmless).
      arguments.insert(0, '-q');
    }
    if (name == 'wget') {
      if (!_hasArgument(arguments, '--no-config')) {
        arguments.insert(0, '--no-config');
      }
      if (!_hasArgumentPrefix(arguments, '--max-redirect')) {
        arguments.insert(1, '--max-redirect=0');
      }
    }
    return WorkCommand(
      executable: executable,
      arguments: arguments,
      workingDirectory: command.workingDirectory,
      declaredImpact: command.declaredImpact,
    );
  }

  Future<String> _resolveExecutable(
    String rawExecutable,
    WorkCommandPolicyResult policyResult, {
    required String workingDirectory,
    required bool userExplicitlyRequested,
  }) async {
    final value = rawExecutable.trim();
    if (value.isEmpty) {
      throw const _CommandSecurityException('命令缺少可执行文件。');
    }
    if (_isPathLikeExecutable(value)) {
      final candidate = _isAbsolutePath(value)
          ? value
          : _joinCommandPath(workingDirectory, value);
      final canonical = await _canonicalExecutable(candidate);
      if (canonical == null) {
        throw ProcessException(value, const [], '可执行文件不存在。', 2);
      }
      return canonical;
    }
    final pathValue = parentEnvironment['PATH'] ?? '';
    final separator = Platform.isWindows ? ';' : ':';
    final candidates = pathValue
        .split(separator)
        .where((entry) => entry.trim().isNotEmpty)
        .map(
          (entry) => _joinCommandPath(
            entry.trim(),
            value,
            baseDirectory: workingDirectory,
          ),
        );
    String? canonical;
    for (final candidate in candidates) {
      canonical = await _canonicalExecutable(candidate);
      if (canonical != null) break;
    }
    if (canonical == null) {
      throw ProcessException(value, const [], '可执行文件不存在。', 2);
    }
    // Automatic read-only execution is limited to known system/tool folders.
    // A bare name found in an arbitrary PATH entry could otherwise be a file
    // shadow placed by the workspace or another writable directory. Explicit
    // mutation/uncertain approvals may still run a user-selected executable.
    if (policyResult.impact == WorkCommandImpact.readOnly &&
        !userExplicitlyRequested &&
        !_isTrustedExecutablePath(canonical)) {
      throw const _CommandSecurityException(
        '可执行文件位于不受信任的 PATH 目录，已阻止自动执行；请在面板中明确批准该命令。',
      );
    }
    return canonical;
  }

  Future<String?> _canonicalExecutable(String candidate) async {
    try {
      final rawType =
          await FileSystemEntity.type(candidate, followLinks: false);
      if (rawType != FileSystemEntityType.file &&
          rawType != FileSystemEntityType.link) {
        return null;
      }
      final resolved = await File(candidate).resolveSymbolicLinks();
      final type = await FileSystemEntity.type(resolved);
      return type == FileSystemEntityType.file
          ? normalizeWorkAbsolutePath(resolved)
          : null;
    } on Object {
      return null;
    }
  }

  bool _isTrustedExecutablePath(String path) {
    final normalized = path.replaceAll('\\', '/');
    if (Platform.isWindows) {
      final systemRoot = (parentEnvironment['SystemRoot'] ?? r'C:\Windows')
          .replaceAll('\\', '/')
          .toLowerCase();
      final lower = normalized.toLowerCase();
      return lower.startsWith('$systemRoot/system32/') ||
          lower.startsWith('$systemRoot/');
    }
    const roots = <String>[
      '/bin/',
      '/usr/bin/',
      '/usr/sbin/',
      '/sbin/',
      '/opt/homebrew/bin/',
      '/usr/local/bin/',
    ];
    return roots.any(normalized.startsWith) ||
        normalized == Platform.resolvedExecutable.replaceAll('\\', '/');
  }

  bool _isPathLikeExecutable(String value) =>
      value.contains('/') ||
      value.contains('\\') ||
      RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value);

  String _joinCommandPath(
    String directory,
    String child, {
    String? baseDirectory,
  }) {
    final root = _isAbsolutePath(directory)
        ? directory
        : _joinCommandPath(baseDirectory ?? Directory.current.path, directory);
    final separator =
        root.endsWith('/') || root.endsWith('\\') ? '' : Platform.pathSeparator;
    return '$root$separator$child';
  }

  String _commandBasename(String value) {
    final normalized = value.replaceAll('\\', '/');
    final slash = normalized.lastIndexOf('/');
    return slash < 0 ? normalized : normalized.substring(slash + 1);
  }

  bool _hasArgument(List<String> arguments, String expected) =>
      arguments.any((argument) => argument.toLowerCase() == expected);

  bool _hasArgumentPrefix(List<String> arguments, String prefix) =>
      arguments.any((argument) =>
          argument.toLowerCase() == prefix ||
          argument.toLowerCase().startsWith('$prefix='));

  Future<String?> _validateWorkingDirectory(WorkCommand command) async {
    final resolver = pathPolicy;
    if (resolver == null) return null;
    try {
      final resolved = await resolver.resolveExisting(command.workingDirectory);
      if (!resolved.isDirectory) return '工作目录不是目录。';
      return null;
    } on Object catch (error) {
      return _safeError(error);
    }
  }

  Future<_CommandBoundaryError?> _validateCommandBoundary(
    WorkCommand command,
  ) async {
    final resolver = pathPolicy;
    if (resolver != null) {
      final cwd = normalizeWorkAbsolutePath(command.workingDirectory);
      for (final rawPath in _commandPathCandidates(command)) {
        final candidate = _absoluteCommandPath(rawPath, cwd);
        try {
          // Missing files are valid command inputs (for example `cat
          // generated.txt` before generation), but every existing parent and
          // symlink must still resolve inside the granted root.
          await resolver.resolve(candidate, allowMissing: true);
        } on Object catch (error) {
          return _CommandBoundaryError(_safeError(error));
        }
      }
      for (final rawImpact in command.declaredImpact) {
        final candidate = _absoluteCommandPath(rawImpact, cwd);
        try {
          await resolver.resolve(candidate, allowMissing: true);
        } on Object catch (error) {
          return _CommandBoundaryError(_safeError(error));
        }
      }
    }
    return _validateNetworkTargets(command);
  }

  Iterable<String> _commandPathCandidates(WorkCommand command) sync* {
    const pathValueOptions = <String>{
      '-C',
      '--directory',
      '--output',
      '--output-dir',
      '--output-document',
      '--dump-header',
      '--stderr',
      '--trace',
      '--trace-ascii',
      '--cookie-jar',
      '--config',
      '--url-query',
      '-o',
      '-D',
      '-c',
    };
    for (var index = 0; index < command.arguments.length; index++) {
      final raw = command.arguments[index].trim();
      if (raw.isEmpty) continue;
      final lower = raw.toLowerCase();
      if (_isNetworkUrl(raw)) continue;
      if (raw.startsWith('--') && raw.contains('=')) {
        final option = raw.substring(0, raw.indexOf('=')).toLowerCase();
        final value = raw.substring(raw.indexOf('=') + 1);
        final embeddedPath = _embeddedLocalCommandPath(value);
        if (const {
          '--directory',
          '--output',
          '--output-dir',
          '--output-document',
          '--dump-header',
          '--stderr',
          '--trace',
          '--trace-ascii',
          '--cookie-jar',
          '--config',
          '--url-query',
        }.contains(option)) {
          yield embeddedPath ?? value;
        } else if (embeddedPath != null) {
          yield embeddedPath;
        }
        continue;
      }
      if (pathValueOptions.contains(raw) || pathValueOptions.contains(lower)) {
        if (index + 1 < command.arguments.length) {
          yield command.arguments[++index];
        }
        continue;
      }
      final attachedPath = _attachedLocalCommandPath(
        _commandBasename(command.executable).toLowerCase(),
        raw,
      );
      if (attachedPath != null) {
        yield attachedPath;
        continue;
      }
      if (raw.startsWith('-')) continue;
      if (_isCommandPunctuation(raw)) continue;
      // curl accepts file references as separate values (`--data @file` and
      // `--form field=@file`). Strip the marker before resolving the path so
      // an outside `@../secret` cannot hide behind a non-option token.
      yield _embeddedLocalCommandPath(raw) ?? raw;
    }
  }

  String? _attachedLocalCommandPath(String executable, String raw) {
    if (raw.length <= 2 || !raw.startsWith('-') || raw.startsWith('--')) {
      return null;
    }
    // These short forms may attach a local file to the option token, e.g.
    // `curl -o../outside` or `curl -d@../outside`. Treating them as ordinary
    // flags would let the runtime skip the symlink/path boundary check.
    final option = raw[1];
    final options = switch (executable) {
      'curl' => const {'o', 'D', 'c', 'K', 'T', 'd', 'F', 'E', 'b'},
      'wget' => const {'O', 'o', 'P', 'i', 'c'},
      'git' => const {'C'},
      _ => const {
          'o',
          'O',
          'D',
          'c',
          'C',
          'K',
          'T',
          'd',
          'F',
          'E',
          'b',
          'P',
          'i'
        },
    };
    if (!options.contains(option)) return null;
    return _embeddedLocalCommandPath(raw.substring(2));
  }

  String? _embeddedLocalCommandPath(String raw) {
    var value = raw.trim();
    if (value.startsWith('@')) value = value.substring(1);
    final fileMarker = value.indexOf('=@');
    if (fileMarker >= 0) value = value.substring(fileMarker + 2);
    return _isLikelyLocalCommandPath(value) ? value : null;
  }

  String _absoluteCommandPath(String raw, String cwd) {
    final value = raw.trim();
    if (_isAbsolutePath(value)) return normalizeWorkAbsolutePath(value);
    final separator = cwd.endsWith('/') ? '' : '/';
    return normalizeWorkAbsolutePath(
      '$cwd$separator${value.replaceAll('\\', '/')}',
    );
  }

  bool _isLikelyLocalCommandPath(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || _isNetworkUrl(trimmed)) return false;
    return _isAbsolutePath(trimmed) ||
        trimmed.startsWith('./') ||
        trimmed.startsWith('../') ||
        trimmed.contains('/') ||
        trimmed.contains('\\');
  }

  bool _isAbsolutePath(String value) =>
      value.startsWith('/') ||
      value.startsWith(r'\\') ||
      RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value);

  bool _isNetworkUrl(String value) {
    final uri = Uri.tryParse(value);
    final scheme = uri?.scheme.toLowerCase();
    return scheme == 'http' || scheme == 'https';
  }

  bool _isCommandPunctuation(String value) =>
      value == '.' || value == '..' || value == '|' || value == '>';

  Future<_CommandBoundaryError?> _validateNetworkTargets(
    WorkCommand command,
  ) async {
    final executable = _commandBasename(command.executable).toLowerCase();
    if (executable != 'curl' && executable != 'wget') return null;
    final unsafeOption = _unsafeNetworkRoutingOption(
      executable,
      command.arguments,
    );
    if (unsafeOption != null) {
      return _CommandBoundaryError(
        '网络命令参数 $unsafeOption 可能绕过公网目标校验，已阻止执行。',
        isNetwork: true,
      );
    }
    if (executable == 'curl' && _curlRedirectsEnabled(command.arguments)) {
      return const _CommandBoundaryError(
        'curl 必须禁用 HTTP 重定向后才能访问网络，已阻止执行。',
        isNetwork: true,
      );
    }
    if (executable == 'wget') {
      final redirectLimit = _wgetRedirectLimit(command.arguments);
      if (redirectLimit == null || redirectLimit != 0) {
        return const _CommandBoundaryError(
          'wget 必须禁用 HTTP 重定向后才能访问网络，已阻止执行。',
          isNetwork: true,
        );
      }
    }
    final urls = _networkUrls(command.arguments);
    if (urls.isEmpty) {
      return const _CommandBoundaryError(
        '网络命令未提供明确的 HTTP(S) URL，已阻止执行。',
        isNetwork: true,
      );
    }
    for (final rawUrl in urls) {
      final uri = Uri.tryParse(rawUrl.trim());
      final host = uri?.host.trim();
      final scheme = uri?.scheme.toLowerCase();
      if (uri == null ||
          !const {'http', 'https'}.contains(scheme) ||
          host == null ||
          host.isEmpty) {
        return const _CommandBoundaryError(
          '网络目标 URL 无效或不是 HTTP(S)，已阻止执行。',
          isNetwork: true,
        );
      }
      if (uri.userInfo.isNotEmpty) {
        return const _CommandBoundaryError(
          '网络目标 URL 不得包含用户名或密码，已阻止执行。',
          isNetwork: true,
        );
      }
      final literal = InternetAddress.tryParse(host);
      if (literal != null) {
        if (_isNonPublicAddress(literal.rawAddress)) {
          return _privateNetworkError(host);
        }
        continue;
      }
      try {
        final addresses = await dnsResolver(host).timeout(timeout);
        if (addresses.isEmpty ||
            addresses
                .any((address) => _isNonPublicAddress(address.rawAddress))) {
          return _privateNetworkError(host);
        }
      } on Object {
        return const _CommandBoundaryError(
          '无法确认网络目标的 DNS 地址是否为公网地址，已阻止执行。',
          isNetwork: true,
        );
      }
    }
    return null;
  }

  String? _unsafeNetworkRoutingOption(
    String executable,
    List<String> arguments,
  ) {
    for (final argument in arguments) {
      final trimmed = argument.trim();
      final lower = trimmed.toLowerCase();
      if (executable == 'curl') {
        if (_curlUnsafeRoutingOption(lower, trimmed)) return trimmed;
      } else if (_wgetUnsafeRoutingOption(lower)) {
        return trimmed;
      }
    }
    return null;
  }

  bool _curlUnsafeRoutingOption(String lower, String raw) {
    const longOptions = <String>{
      '--resolve',
      '--connect-to',
      '--proxy',
      '--preproxy',
      '--proxy1.0',
      '--socks5',
      '--socks5-hostname',
      '--socks4',
      '--socks4a',
      '--config',
      '--interface',
      '--unix-socket',
      '--input-file',
      '--doh-url',
      '--dns-interface',
      '--dns-ipv4-addr',
      '--dns-ipv6-addr',
      '--abstract-unix-socket',
      '--url-query',
    };
    if (longOptions.any(
      (option) => lower == option || lower.startsWith('$option='),
    )) {
      return true;
    }
    // These short options can carry their value in the same token (for
    // example `-xhttp://proxy` or `-Kcurl.conf`). Reject both spellings so a
    // hidden route/configuration cannot bypass the URL and DNS checks.
    if (!raw.startsWith('--') && raw.startsWith('-')) {
      final shortOptions = raw.substring(1);
      return shortOptions.isNotEmpty &&
          (shortOptions.contains('x') || shortOptions.contains('K'));
    }
    return false;
  }

  bool _wgetUnsafeRoutingOption(String lower) {
    const options = <String>{
      '--proxy',
      '--config',
      '--input-file',
      '--bind-address',
      '--execute',
    };
    return lower == '-e' ||
        options.any(
          (option) => lower == option || lower.startsWith('$option='),
        );
  }

  bool _curlRedirectsEnabled(List<String> arguments) {
    for (final argument in arguments) {
      final lower = argument.trim().toLowerCase();
      if (lower == '--location' || lower == '--location-trusted') return true;
      // curl's short redirect flag is uppercase `-L`; preserve case so `-l`
      // (FTP directory listing) is not rejected as a redirect request.
      if (argument.startsWith('-') &&
          !argument.startsWith('--') &&
          argument.substring(1).contains('L')) {
        return true;
      }
    }
    return false;
  }

  int? _wgetRedirectLimit(List<String> arguments) {
    var found = false;
    var resolvedLimit = 0;
    for (var index = 0; index < arguments.length; index++) {
      final lower = arguments[index].trim().toLowerCase();
      String? rawValue;
      if (lower.startsWith('--max-redirect=')) {
        rawValue = lower.substring('--max-redirect='.length);
      } else if (lower == '--max-redirect') {
        if (index + 1 >= arguments.length) return null;
        rawValue = arguments[++index].trim();
      }
      if (rawValue == null) continue;
      final value = int.tryParse(rawValue);
      // Wget applies repeated options in order; inspect every occurrence so a
      // later non-zero value cannot override an earlier safe-looking zero.
      if (value == null) return null;
      found = true;
      if (value != 0) {
        // Keep a non-zero sentinel even when a later token restores zero. The
        // command is rejected unless every explicit limit is exactly zero;
        // this avoids relying on a particular wget option precedence rule.
        resolvedLimit = value;
      }
    }
    // A missing option is safe only after _prepareCommand adds an explicit
    // zero before spawn; the network preflight runs before that transformation.
    return found ? resolvedLimit : 0;
  }

  List<String> _networkUrls(List<String> arguments) {
    const valueOptions = <String>{
      '-x',
      '-X',
      '-h',
      '-u',
      '-a',
      '--request',
      '--method',
      '--proxy',
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
      '--input-file',
    };
    final urls = <String>[];
    for (var index = 0; index < arguments.length; index++) {
      final raw = arguments[index].trim();
      final lower = raw.toLowerCase();
      if (lower == '--url' && index + 1 < arguments.length) {
        urls.add(arguments[++index]);
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
    return urls;
  }

  _CommandBoundaryError _privateNetworkError(String host) =>
      _CommandBoundaryError(
        '网络目标 $host 解析到非公网地址，已阻止执行以避免 SSRF。',
        isNetwork: true,
      );

  bool _isNonPublicAddress(List<int> raw) {
    if (raw.length == 4) return _isNonPublicIpv4(raw);
    if (raw.length != 16) return true;
    final mapped = raw.take(10).every((byte) => byte == 0) &&
        raw[10] == 0xff &&
        raw[11] == 0xff;
    if (mapped) return _isNonPublicIpv4(raw.sublist(12));
    final allZero = raw.every((byte) => byte == 0);
    final loopback =
        allZero || raw.take(15).every((byte) => byte == 0) && raw[15] == 1;
    final first = raw[0];
    final second = raw[1];
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
        (first == 198 && second >= 18 && second <= 19) ||
        (first == 198 && second == 51 && third == 100) ||
        (first == 203 && second == 0 && third == 113) ||
        first >= 224;
  }
}

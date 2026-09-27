part of 'work_task_coordinator.dart';

extension _WorkTaskCoordinatorCheckpointPolicy on WorkTaskCoordinator {
  bool _pendingCommandNeedsWritable(Map<String, dynamic> args) {
    final executable = (args['executable'] ?? '').toString().toLowerCase();
    final base = executable.replaceAll('\\', '/').split('/').last;
    final rawArguments = args['arguments'] ?? args['args'];
    final rawArgumentList = rawArguments is List
        ? rawArguments.map((item) => item.toString()).toList()
        : const <String>[];
    final arguments = rawArgumentList
        .map((item) => item.toLowerCase())
        .toList(growable: false);
    final rawImpact = args['declaredImpact'];
    final impactPaths =
        rawImpact is List ? rawImpact.whereType<String>() : const <String>[];
    if (impactPaths.any(_isAbsoluteWorkPath)) return true;
    // Shell redirection is rejected by the structured command policy as a
    // local mutation. Keep the folder preflight aligned with that policy so a
    // resumed `ls > report.txt` cannot start on a read-only workspace and only
    // discover the missing write capability after the process boundary.
    if (arguments.any(_isLocalRedirectArgument)) return true;
    if (const {
      'pwd',
      'ls',
      'dir',
      'rg',
      'ripgrep',
      'grep',
      'egrep',
      'fgrep',
      'cat',
      'head',
      'tail',
      'wc',
      'file',
      'stat',
      'which',
      'where',
      'whoami',
      'uname',
    }.contains(base)) {
      return false;
    }
    if (base == 'find' || base == 'fd') {
      return arguments.any(
        (argument) => {'-delete', '-exec', '-execdir', '-ok', '-okdir'}
            .contains(argument),
      );
    }
    if (base == 'git' && arguments.isNotEmpty) {
      return !const {
        'status',
        'diff',
        'log',
        'show',
        'branch',
        'rev-parse',
        'ls-files',
        'push',
      }.contains(arguments.first);
    }
    if (base == 'flutter' || base == 'dart') {
      final first = arguments.isEmpty ? '' : arguments.first;
      return first != 'analyze' && first != '--version' && first != '--help';
    }
    if (base == 'curl' || base == 'wget') {
      // A network write does not require a writable local folder unless the
      // impact list explicitly includes an absolute local path. Local output
      // flags do require the capability; upload/data flags only read local
      // inputs and therefore remain valid with a read-only grant.
      return rawArgumentList.any(
        (raw) {
          final argument = raw.toLowerCase();
          final curlShortOutput = base == 'curl' &&
              (raw == '-D' ||
                  raw.startsWith('-D') && raw.length > 2 ||
                  raw == '-c' ||
                  raw.startsWith('-c') && raw.length > 2);
          return curlShortOutput ||
              argument == '-o' ||
              argument == '--output' ||
              argument.startsWith('--output=') ||
              argument == '--output-dir' ||
              argument.startsWith('--output-dir=') ||
              argument == '--output-document' ||
              argument.startsWith('--output-document=') ||
              argument == '--dump-header' ||
              argument.startsWith('--dump-header=') ||
              argument == '--cookie-jar' ||
              argument.startsWith('--cookie-jar=') ||
              argument == '--trace' ||
              argument.startsWith('--trace=') ||
              argument == '--trace-ascii' ||
              argument.startsWith('--trace-ascii=') ||
              argument == '--stderr' ||
              argument.startsWith('--stderr=') ||
              argument == '--hsts' ||
              argument.startsWith('--hsts=') ||
              argument == '--etag-save' ||
              argument.startsWith('--etag-save=') ||
              argument.startsWith('-o') && argument.length > 2;
        },
      );
    }
    return true;
  }

  bool _isAbsoluteWorkPath(String value) {
    final path = value.trim();
    return path.startsWith('/') ||
        path.startsWith('\\') ||
        RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);
  }

  bool _isLocalRedirectArgument(String argument) {
    return argument == '>' ||
        argument == '>>' ||
        argument == '<' ||
        argument == '2>' ||
        argument.startsWith('>') ||
        argument.startsWith('<') ||
        argument.startsWith('2>');
  }

  bool _requestLikelyMutates(String request) {
    final lower = request.toLowerCase();
    // A task starts before the first structured tool call, so a read-only
    // command such as “运行 pwd” must not be blocked merely because the
    // request contains the generic verb “运行/执行”.  Keep this check
    // intentionally narrow: only well-known inspection commands qualify, and
    // any explicit write/test/build/install intent keeps the conservative
    // writable-folder requirement.
    if (_requestClearlyReadOnly(lower)) return false;
    return RegExp(
      r'(写|写入|修改|改写|创建|生成|删除|移除|重命名|替换|保存|覆盖|安装|提交|推送|'
      r'运行|执行|编译|构建|测试|开发|修复|实现|'
      r'\b(?:write|create|generate|modify|edit|delete|remove|rename|replace|save|overwrite|'
      r'install|commit|push|run|compile|build|test|develop|fix|implement)\b)',
      caseSensitive: false,
    ).hasMatch(lower);
  }

  bool _requestClearlyReadOnly(String lower) {
    // Merely mentioning an inspection command is not enough to classify the
    // whole request as read-only.  Shell separators, redirects and common
    // mutating subcommands make the intent compound/uncertain; request a
    // writable capability up front and let the structured command policy make
    // the final decision.
    if (RegExp(r'[|;]|&&|(?:>>?|<|2>)').hasMatch(lower) ||
        RegExp(
          r'(?<![a-z0-9_-])(?:rm|rmdir|del|erase|unlink|mv|move|copy|cp|touch|'
          r'mkdir|install|tee|chmod|chown|truncate|dd|sed|perl)(?![a-z0-9_-])',
          caseSensitive: false,
        ).hasMatch(lower) ||
        RegExp(
          r'(?<![a-z0-9_-])(?:find|fd)\b[^\n]*\s(?:-delete|-exec(?:dir)?|-ok(?:dir)?)\b',
          caseSensitive: false,
        ).hasMatch(lower) ||
        RegExp(
          r'(?<![a-z0-9_-])git\s+(?:commit|push|pull|merge|rebase|checkout|switch|tag|clean|reset)\b',
          caseSensitive: false,
        ).hasMatch(lower) ||
        RegExp(
          r'(?<![a-z0-9_-])(?:curl|wget)\b[^\n]*(?:--?data|--?upload-file|--?output|--?post|--?request[= ](?:post|put|patch|delete)|--?method[= ](?:post|put|patch|delete))',
          caseSensitive: false,
        ).hasMatch(lower)) {
      return false;
    }
    final hasInspectionCommand = RegExp(
      r'(?<![a-z0-9_-])(?:pwd|ls|dir|find|fd|rg|ripgrep|grep|egrep|fgrep|'
      r'cat|head|tail|wc|file|stat|which|where|whoami|uname)(?![a-z0-9_-])',
      caseSensitive: false,
    ).hasMatch(lower);
    if (!hasInspectionCommand) {
      final hasReadOnlyGit = RegExp(
        r'(?<![a-z0-9_-])git\s+(?:status|diff|log|show|branch|rev-parse|ls-files)'
        r'(?![a-z0-9_-])',
        caseSensitive: false,
      ).hasMatch(lower);
      final hasReadOnlySdk = RegExp(
        r'(?<![a-z0-9_-])(?:flutter|dart)\s+(?:analyze|--version|--help)'
        r'(?![a-z0-9_-])',
        caseSensitive: false,
      ).hasMatch(lower);
      if (!hasReadOnlyGit && !hasReadOnlySdk) return false;
    }
    return !RegExp(
      r'(写|写入|修改|改写|创建|生成|删除|移除|重命名|替换|保存|覆盖|安装|提交|推送|'
      r'编译|构建|测试|开发|修复|实现|发布|部署|'
      r'\b(?:write|create|generate|modify|edit|delete|remove|rename|replace|save|overwrite|'
      r'install|commit|push|compile|build|test|develop|fix|implement|deploy|publish)\b)',
      caseSensitive: false,
    ).hasMatch(lower);
  }

  String _withoutFolderRequest(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final copy = Map<String, dynamic>.from(decoded)
          ..remove('folderRequestPath')
          ..remove('folderGrantPending');
        return copy.isEmpty ? '' : jsonEncode(copy);
      }
    } on Object {
      return '';
    }
    return raw;
  }

  String _withFolderGrantPending(
    String raw,
    String? requestedPath, {
    required bool requiresWritable,
  }) {
    final metadata = _decodeExecutionMap(raw)..['folderGrantPending'] = true;
    if (requiresWritable) {
      metadata['folderRequiresWritable'] = true;
    } else {
      metadata.remove('folderRequiresWritable');
    }
    final path = requestedPath?.trim();
    if (path == null || path.isEmpty) {
      metadata.remove('folderRequestPath');
    } else {
      metadata['folderRequestPath'] = path;
    }
    return jsonEncode(metadata);
  }

  String _withWritableRequirementMarker(String raw) {
    final metadata = _decodeExecutionMap(raw)
      ..['folderRequiresWritable'] = true;
    return jsonEncode(metadata);
  }

  String _withResourceLockPlan(
    String raw,
    List<WorkResourceLockRequest> locks,
  ) {
    final resourceLocks = locks
        .map((lock) => <String, String>{
              'path': lock.path,
              'mode': lock.mode.name,
            })
        .toList(growable: false);
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return jsonEncode({...decoded, 'resourceLocks': resourceLocks});
      }
    } on Object {
      // Replace malformed/non-object metadata with the durable lock plan.
    }
    return jsonEncode(<String, dynamic>{'resourceLocks': resourceLocks});
  }

  List<WorkResourceLockRequest>? _persistedResourceLocks(String raw) {
    if (raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final rawLocks = decoded['resourceLocks'];
      if (rawLocks is List) {
        final parsed = <WorkResourceLockRequest>[];
        for (final item in rawLocks) {
          if (item is! Map || item['path'] is! String) {
            throw const FormatException('资源锁计划格式无效');
          }
          final mode = switch (item['mode']) {
            'read' => WorkResourceLockMode.read,
            'write' => WorkResourceLockMode.write,
            'treeWrite' => WorkResourceLockMode.treeWrite,
            _ => throw const FormatException('资源锁模式无效'),
          };
          parsed.add(
            WorkResourceLockRequest(path: item['path'] as String, mode: mode),
          );
        }
        return _resourceLockManager.normalizeLockSet(parsed);
      }
      final legacyPaths = decoded['resourceLockPaths'];
      if (legacyPaths is List) {
        return _resourceLockManager.normalizeLockSet(
          legacyPaths.whereType<String>().map(WorkResourceLockRequest.write),
        );
      }
    } on Object {
      rethrow;
    }
    return null;
  }

  void _ensureOpen() {
    if (_disposed) throw StateError('工作任务调度器已关闭。');
    if (_dataClearInProgress) {
      throw StateError('正在清除 App 数据，请稍后重试。');
    }
  }
}

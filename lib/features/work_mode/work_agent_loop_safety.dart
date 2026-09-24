part of 'work_agent_loop.dart';

/// Short digest used to keep generated archive entry names unique after the
/// name budget truncates two different long names to the same prefix.
String workArtifactNameDigest(String value) =>
    sha256.convert(utf8.encode(value)).toString();

const Set<String> _sensitiveOperationKeys = {
  'content',
  'body',
  'command',
  'script',
  'stdout',
  'stderr',
  'token',
  'secret',
  'apikey',
  'authorization',
  'password',
};

// A 5 MB image becomes less than 7 MB after base64 encoding. This bound is
// ephemeral (model context only); persisted/checkpoint views still redact it.
const int _maxModelImageDataUriChars = 7 * 1024 * 1024;
const int _commandFailureHistoryLimit = 128;
final RegExp _userActionDiagnostic = RegExp(
  r'权限|permission|access\s+denied|operation\s+not\s+permitted|'
  r'not\s+authorized|unauthorized|administrator|sudo|登录|登入|密码|'
  r'验证码|付费墙|付款|授权|需要确认|需要判断|captcha|login|paywall|'
  r'payment|authorization|password|passphrase',
  caseSensitive: false,
);

extension _WorkAgentLoopSafety on WorkAgentLoop {
  Set<String> _loadCommittedActionKeys(AgentTask task) {
    final decoded = _safeExistingMap(task.executionStateJson);
    final summary = _safeExistingMap(task.contextSummary);
    final raw = decoded['committedActionKeys'] ?? summary['committedWrites'];
    return raw is List ? raw.whereType<String>().toSet() : <String>{};
  }

  List<String> _loadPublicUpdates(AgentTask task) {
    final execution = _safeExistingMap(task.executionStateJson);
    final summary = _safeExistingMap(task.contextSummary);
    final value = execution['publicUpdates'] ?? summary['publicUpdates'];
    return value is List
        ? value.whereType<String>().map(_publicText).toList(growable: false)
        : const <String>[];
  }

  List<Map<String, dynamic>> _loadRecentResults(AgentTask task) {
    final summary = _safeExistingMap(task.contextSummary);
    final value = summary['recentToolResults'];
    if (value is! List) return const <Map<String, dynamic>>[];
    return value
        .whereType<Map>()
        .map((item) => _safePersistedValue(item, depth: 0))
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList(growable: false);
  }

  Map<String, dynamic>? _loadHandoff(AgentTask task) {
    final persisted = WorkHandoffState.fromTask(task);
    if (persisted != null) return persisted.toJson();
    final summary = _safeExistingMap(task.contextSummary);
    final value = summary['roleHandoff'] ?? summary['handoff'];
    if (value is! Map) return null;
    return Map<String, dynamic>.from(value);
  }

  List<String> _loadCommandFailureKeys(AgentTask task) {
    final value =
        _safeExistingMap(task.executionStateJson)['commandFailureKeys'];
    if (value is! List) return const <String>[];
    final filtered = value
        .whereType<String>()
        .where(
          (key) =>
              RegExp(r'^[a-f0-9]{64}$', caseSensitive: false).hasMatch(key),
        )
        .toList(growable: false);
    return filtered
        .skip(
          filtered.length > _commandFailureHistoryLimit
              ? filtered.length - _commandFailureHistoryLimit
              : 0,
        )
        .toList(growable: false);
  }

  int _loadUnchangedMutationCount(AgentTask task) {
    final value =
        _safeExistingMap(task.executionStateJson)['unchangedMutationCount'];
    return value is num ? value.clamp(0, 2).toInt() : 0;
  }

  void _persistUnchangedMutationCount(AgentTask task, int count) {
    final execution = _decodeMap(task.executionStateJson);
    final bounded = count.clamp(0, 2).toInt();
    if (bounded == 0) {
      execution.remove('unchangedMutationCount');
    } else {
      execution['unchangedMutationCount'] = bounded;
    }
    task.executionStateJson = jsonEncode(execution);
  }

  /// Returns true only when this exact command/tool and diagnostic state was
  /// already seen in the current progress segment. A successful mutation clears
  /// the segment, so a compiler can legitimately report the same error again
  /// after the model has changed the input.
  bool _isCommandFailureLoop(
    _LoopState state,
    AgentToolCall call,
    WorkToolResult result,
  ) {
    final fingerprint = _commandFailureFingerprint(call, result);
    if (state.commandFailureKeys.contains(fingerprint)) return true;
    state.commandFailureKeys.add(fingerprint);
    if (state.commandFailureKeys.length > _commandFailureHistoryLimit) {
      state.commandFailureKeys.removeRange(
        0,
        state.commandFailureKeys.length - _commandFailureHistoryLimit,
      );
    }
    return false;
  }

  /// Whether the real failure signature changed even though the model edited its
  /// command. The persisted `commandFailureKeys` fingerprint covers the whole
  /// command, so a repaired script or a re-quoted argument always looks "new"
  /// and the loop detector never fires — which is how one task burned a dozen
  /// actions re-running a command whose process error never changed.
  ///
  /// A single failure that merely points at the file being repaired is not
  /// enough to stop: the next run is expected to succeed. Requiring the same
  /// outcome twice gives the repair one honest attempt while still ending the
  /// repeat-on-identical-error variant of the same dead end.
  bool _isRepeatedCommandOutcome(
    _LoopState state,
    AgentToolCall call,
    WorkToolResult result,
  ) {
    final signature = _commandOutcomeSignature(call, result);
    final previous = state.commandOutcomeSignatures[signature];
    state.commandOutcomeSignatures[signature] = (previous ?? 0) + 1;
    while (
        state.commandOutcomeSignatures.length > _commandFailureHistoryLimit) {
      state.commandOutcomeSignatures.remove(
        state.commandOutcomeSignatures.keys.first,
      );
    }
    return (state.commandOutcomeSignatures[signature] ?? 0) > 1;
  }

  /// Identifies a process failure independently of the command spelling.
  ///
  /// The exit status and the *diagnostic* stderr line are used on purpose: a
  /// Python traceback repeats its first frames no matter which line was just
  /// fixed, while its final line names the real defect. Two runs whose exit
  /// status and diagnostic line match are the same dead end even if the script
  /// text differs.
  String _commandOutcomeSignature(
    AgentToolCall call,
    WorkToolResult result,
  ) {
    final payload = <String, dynamic>{
      'tool': call.name.wireName,
      'runStatus': result.data['runStatus']?.toString() ?? result.status.name,
      'exitCode': result.data['exitCode']?.toString() ?? '',
      'message': _diagnosticText(result.message),
      // The artifact a repair run is trying to fix. Two unrelated scripts that
      // fail with the same generic banner are not the same dead end.
      'target': result.data['failureTargetPath']?.toString() ?? '',
      'stderrTail': _diagnosticTail(result.data['stderr']),
    };
    return sha256
        .convert(utf8.encode(jsonEncode(_canonical(payload))))
        .toString();
  }

  /// The last stderr line that actually names a defect.
  ///
  /// Toolchains often end with a line that is identical for every failure
  /// (`Node.js v20`, clang's `1 error generated.`, `make: *** [x] Error 1`), so
  /// using the literal last line would make two unrelated bugs share one
  /// signature and pause a task that was still progressing.
  String _diagnosticTail(Object? value) {
    final text = _diagnosticText(value);
    if (text.isEmpty) return '';
    final lines = text
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    for (final line in lines.reversed) {
      if (!_isGenericDiagnosticTail(line)) return line;
    }
    return lines.isEmpty ? '' : lines.last;
  }

  bool _isGenericDiagnosticTail(String line) {
    final lower = line.toLowerCase();
    return RegExp(
      r'^(node\.js v[\d.]+|python [\d.]+|'
      r'\d+ errors? generated\.?|'
      r'make(\[\d+\])?: \*\*\* .*error \d+|'
      r'note:|'
      r'error: could not compile .* due to)',
      caseSensitive: false,
    ).hasMatch(lower);
  }

  String _commandFailureFingerprint(
    AgentToolCall call,
    WorkToolResult result,
  ) {
    final payload = <String, dynamic>{
      'operation': _operationKey(call),
      'failureCode': result.failureCode ?? '',
      'runStatus': result.data['runStatus']?.toString() ?? result.status.name,
      'exitCode': result.data['exitCode']?.toString() ?? '',
      'message': _diagnosticText(result.message),
      'stderr': _diagnosticText(result.data['stderr']),
      'stdout': _diagnosticText(result.data['stdout']),
    };
    return sha256
        .convert(utf8.encode(jsonEncode(_canonical(payload))))
        .toString();
  }

  String _diagnosticText(Object? value) {
    if (value == null) return '';
    final text = value.toString().replaceAll('\r\n', '\n').trim();
    if (text.length <= 4096) return text;
    return '${text.substring(0, 2048)}…${text.substring(text.length - 2048)}';
  }

  void clearCommandFailureHistory(_LoopState state) {
    state.commandFailureKeys.clear();
    // The outcome counters must be cleared with the history. Otherwise a command
    // that failed once, was fixed, and fails with the same signature much later
    // in the same run looks like an immediate repeat and pauses a task that was
    // still making progress.
    state.commandOutcomeSignatures.clear();
  }

  bool _isBlockedCommandFailure(WorkToolResult result) =>
      result.failureCode == 'commandFailed' &&
      result.data['runStatus'] == WorkCommandRunStatus.blockedByDefault.name;

  /// Whether a failed tool result may be handed back to the model so it can
  /// repair its own call instead of ending the task.
  ///
  /// Approval, permission and path gates are excluded: their remedy is a user
  /// grant or a different plan, which the panel already offers, so retrying
  /// them would only repeat a refusal. A mutation that already reached the
  /// filesystem is excluded too: its effect may be half-applied, and the
  /// durable operation key means a repeat could only be a no-op, so it surfaces
  /// as a classified failure for the user to judge. Everything else — a
  /// rejected argument, a missing prerequisite, a resource conflict or an
  /// unhandled tool error — is something the model's next decision can still
  /// fix. Runaway repair is bounded by the failure-history detectors below and
  /// the task's repair budget, not by refusing the retry up front.
  bool _isRepairableToolFailure(WorkToolResult result) {
    if (result.succeeded || result.committed) return false;
    if (result.status == WorkToolResultStatus.pathRejected) return false;
    return result.failureCode != 'softLimit';
  }

  /// The imperative the model reads on its next turn after a repairable tool
  /// failure. The failed result is already in `recentToolResults`; this states
  /// what to do with it so the model does not simply repeat the same call.
  String _toolRepairInstruction(AgentToolCall call, WorkToolResult result) {
    final code = result.failureCode ?? result.status.name;
    final detail = _publicText(result.message, maximum: 400);
    return '上一次工具调用（${call.name.wireName}）失败（$code）：$detail。'
        '请根据该错误修正参数、补齐前置条件或改用其他可行工具后重试，'
        '不要重复完全相同的调用。';
  }

  Map<String, dynamic> _safeResult(
    WorkToolResult result,
    AgentToolCall call,
  ) {
    final rejected = result.data['rejected'] == true;
    final changed = result.data['changed'];
    return {
      'tool': call.name.wireName,
      'status': result.status.name,
      'message': _publicText(result.message),
      // A rejected mutation is a successful no-op. Keep it explicitly
      // uncommitted in the model/checkpoint view so a later continuation does
      // not treat a user's refusal as durable work.
      'committed': !rejected &&
          changed != false &&
          (result.committed ||
              result.succeeded &&
                  registry.definitionFor(call.name)?.isMutation == true),
      if (result.failureCode != null) 'failureCode': result.failureCode,
      if (result.data.isNotEmpty) 'data': _safeMap(result.data),
    };
  }

  /// Keeps only the current process's bounded tool result for the next model
  /// turn. Unlike [_safeResult], this view is never written to Hive or the
  /// event stream, so a file read can inform the model without becoming a
  /// durable copy of user content.
  Map<String, dynamic> _modelResult(
    WorkToolResult result,
    AgentToolCall call,
  ) {
    return {
      'tool': call.name.wireName,
      'status': result.status.name,
      'message': _publicText(result.message),
      if (result.failureCode != null) 'failureCode': result.failureCode,
      if (result.data.isNotEmpty) 'data': _modelValue(result.data),
    };
  }

  Object? _modelValue(Object? value, {int depth = 0, String? key}) {
    if (depth > 6 || (_isPrivateField(key) && !_isModelVisibleField(key!))) {
      return null;
    }
    if (value == null || value is num || value is bool) return value;
    if (value is String) {
      final isImageDataUri = key == 'url' && value.startsWith('data:image/');
      return _publicText(
        value,
        maximum: isImageDataUri ? _maxModelImageDataUriChars : 12000,
      );
    }
    if (value is List) {
      return value
          .take(128)
          .map((item) => _modelValue(item, depth: depth + 1))
          .toList(growable: false);
    }
    if (value is Map) {
      final output = <String, dynamic>{};
      for (final entry in value.entries.take(128)) {
        if (entry.key is! String) continue;
        final entryKey = entry.key as String;
        if (_isPrivateField(entryKey) && !_isModelVisibleField(entryKey)) {
          continue;
        }
        output[entryKey] = _modelValue(
          entry.value,
          depth: depth + 1,
          key: entryKey,
        );
      }
      return output;
    }
    return null;
  }

  bool _isModelVisibleField(String key) {
    final normalized = key.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    // This is an ephemeral, bounded view of a tool's public result. File
    // content and command output are useful to the next model turn, while
    // credential-bearing request fields remain excluded by the deny-list.
    return const {
      'content',
      'contents',
      'body',
      'text',
      'stdout',
      'stderr',
      'data',
      'output',
      'result',
      'response',
    }.contains(normalized);
  }

  String _operationKey(AgentToolCall call) {
    final normalized = _canonical(call.arguments);
    return '${call.name.wireName}:$normalized';
  }

  Object? _canonical(Object? value, [String? key]) {
    if (key != null &&
        _sensitiveOperationKeys.contains(key.toLowerCase()) &&
        value is String) {
      return 'sha256:${sha256.convert(utf8.encode(value))}';
    }
    if (value is Map) {
      final entries = value.entries.toList()
        ..sort((left, right) =>
            left.key.toString().compareTo(right.key.toString()));
      return <String, Object?>{
        for (final entry in entries)
          entry.key.toString(): _canonical(entry.value, entry.key.toString()),
      };
    }
    if (value is Iterable) return value.map(_canonical).toList(growable: false);
    return value;
  }

  Map<String, dynamic> _safeMap(Map<String, dynamic> source) {
    const blocked = {
      'content',
      'contents',
      'body',
      'stdout',
      'stderr',
      'script',
      'command',
      'prompt',
      'raw',
      'text',
      'data',
      'output',
      'result',
      'response',
      'messages',
      'conversationHistory',
      'conversationId',
      'groupId',
      'privateChat',
      'fileText',
      'fullText',
      'fileBody',
      'fileContents',
      'token',
      'secret',
      'apiKey',
      'authorization',
      'password',
    };
    final output = <String, dynamic>{};
    for (final entry in source.entries.take(32)) {
      final normalizedKey = entry.key.toLowerCase();
      if (normalizedKey == 'installsuggestion') {
        final suggestion = _safeInstallSuggestion(entry.value);
        if (suggestion != null) output[entry.key] = suggestion;
        continue;
      }
      if (blocked.contains(entry.key) ||
          blocked.any((key) => key.toLowerCase() == normalizedKey) ||
          _isPrivateField(entry.key)) {
        continue;
      }
      final value = entry.value;
      if (value is String) {
        output[entry.key] = _publicText(value, maximum: 512);
      } else if (value is num || value is bool || value == null) {
        output[entry.key] = value;
      }
    }
    return output;
  }

  Map<String, dynamic>? _safeInstallSuggestion(Object? value) {
    if (value is! Map) return null;
    final output = <String, dynamic>{};
    for (final key in const [
      'executable',
      'purpose',
      'trustedSource',
      'impactPaths',
      'message',
    ]) {
      final item = value[key];
      if (item is String && item.trim().isNotEmpty) {
        output[key] = _publicText(item, maximum: key == 'message' ? 1200 : 512);
      } else if (item is List && key == 'impactPaths') {
        output[key] = item
            .whereType<String>()
            .map((path) => _publicText(path, maximum: 1000))
            .take(32)
            .toList(growable: false);
      }
    }
    final rawCommand = value['installCommand'];
    if (rawCommand is Map) {
      final command = <String, dynamic>{};
      for (final key in const ['executable', 'workingDirectory']) {
        final item = rawCommand[key];
        if (item is String && item.trim().isNotEmpty) {
          command[key] = _publicText(item, maximum: 1000);
        }
      }
      final arguments = rawCommand['arguments'];
      if (arguments is List) {
        command['arguments'] = arguments
            .whereType<String>()
            .map((item) => _publicText(item, maximum: 512))
            .take(64)
            .toList(growable: false);
      }
      final impact = rawCommand['declaredImpact'];
      if (impact is List) {
        command['declaredImpact'] = impact
            .whereType<String>()
            .map((item) => _publicText(item, maximum: 1000))
            .take(64)
            .toList(growable: false);
      }
      if (command.isNotEmpty) output['installCommand'] = command;
    }
    return output.isEmpty ? null : output;
  }

  List<String> _updatedArtifactPaths(
    AgentTask task,
    AgentToolCall call, {
    WorkToolResult? result,
  }) {
    final paths = <String>{...task.lastArtifactPaths};
    final values = <String, Object?>{
      for (final key in const ['path', 'destinationPath'])
        key: call.arguments[key],
      if (result != null) ...{
        'path': result.data['path'] ?? call.arguments['path'],
        'destinationPath': result.data['destinationPath'],
      },
    };
    for (final key in const ['path', 'destinationPath']) {
      final value = values[key];
      if (value is String && value.trim().isNotEmpty) {
        paths.add(_publicText(value, maximum: 1000));
      }
    }
    final reportedArtifacts = result?.data['artifactPaths'];
    if (reportedArtifacts is List) {
      for (final value in reportedArtifacts.whereType<String>()) {
        if (value.trim().isNotEmpty) {
          paths.add(_publicText(value, maximum: 1000));
        }
      }
    }
    return paths.take(64).toList(growable: false);
  }

  void _recordArtifactChange(
    AgentTask task,
    AgentToolCall call,
    WorkToolResult result,
  ) {
    final rawPath = result.data['path'] ?? call.arguments['path'];
    final committed = result.data['changed'] == true;
    // A successful command reports the files it created. Recording them keeps
    // one definition of "changed by this run" for both mutation tools, so the
    // artifact auto-completion can recognize a script-produced deliverable.
    final commandArtifacts = call.name == AgentToolName.commandRun &&
            result.data['runStatus'] == WorkCommandRunStatus.completed.name
        ? (result.data['artifactPaths'] as List?)?.whereType<String>() ??
            const <String>[]
        : const <String>[];
    if (!committed && commandArtifacts.isEmpty) return;
    final execution = _decodeMap(task.executionStateJson);
    final existing = execution['artifactChanges'];
    final changes = <String, dynamic>{
      if (existing is Map)
        ...existing.map(
          (key, value) => MapEntry(key.toString(), value),
        ),
    };
    final hashes = <String, dynamic>{
      if (result.data['beforeSha256'] is String)
        'beforeSha256': result.data['beforeSha256'],
      if (result.data['afterSha256'] is String)
        'afterSha256': result.data['afterSha256'],
    };
    if (committed && rawPath is String && rawPath.trim().isNotEmpty) {
      changes[rawPath] = {'changed': true, ...hashes};
    }
    for (final path in commandArtifacts) {
      if (path.trim().isNotEmpty) changes[path] = {'changed': true};
    }
    execution['artifactChanges'] = changes;
    task.executionStateJson = jsonEncode(execution);
  }

  bool _modelFailed(Map<String, dynamic> response) =>
      response['success'] == false;

  bool _modelNeedsUserAction(Map<String, dynamic> response) {
    final statusCode = response['statusCode'];
    final parsedStatusCode = statusCode is num
        ? statusCode.toInt()
        : statusCode is String
            ? int.tryParse(statusCode.trim())
            : null;
    if (parsedStatusCode != null &&
        WorkAgentLoop._userAuthorizationStatusCodes
            .contains(parsedStatusCode)) {
      return true;
    }
    final code = response['failureCode']?.toString();
    final normalizedCode = code?.trim();
    if (normalizedCode != null &&
        (WorkAgentLoop._userActionFailureCodes.contains(normalizedCode) ||
            normalizedCode.toLowerCase() == 'permissiondenied' ||
            normalizedCode.toLowerCase() == 'authorizationlost')) {
      return true;
    }
    final message = _firstNonEmptyResponseText(response)?.toLowerCase() ?? '';
    return RegExp(
      r'权限|permission|access\s+denied|登录|登入|验证码|付费墙|付款|授权|需要确认|需要判断|captcha|login|paywall|payment|authorization',
      caseSensitive: false,
    ).hasMatch(message);
  }

  bool _toolNeedsUserAction(WorkToolResult result) {
    if (result.status == WorkToolResultStatus.pathRejected) return false;
    if (_isBlockedCommandFailure(result)) return true;
    if (result.requiresUserAction ||
        result.status == WorkToolResultStatus.permissionDenied) {
      return true;
    }
    final code = result.failureCode;
    if (code != null && WorkAgentLoop._userActionFailureCodes.contains(code)) {
      return true;
    }
    final diagnostic = <String>[
      result.message,
      for (final key in const ['stderr', 'stdout'])
        if (result.data[key] != null) _diagnosticText(result.data[key]),
    ].join('\n');
    return _userActionDiagnostic.hasMatch(diagnostic);
  }

  /// Publicly completed work is deliberately compact. The list is persisted
  /// with a failure so a restart/retry can explain what is already done
  /// without copying file bodies or command output into the task record.
  List<String> _completedContent(_LoopState state) {
    final task = state.task;
    final values = <String>[
      ...task.completedOperations,
      if (task.resultSummary.trim().isNotEmpty) task.resultSummary,
      ...task.lastArtifactPaths.map((path) => '产物：$path'),
    ];
    final seen = <String>{};
    return values
        .map((value) => _publicText(value, maximum: 512))
        .where((value) => value.isNotEmpty && seen.add(value))
        .take(32)
        .toList(growable: false);
  }

  String? _responseContent(Map<String, dynamic> response) {
    final content = response['content'];
    if (content is String && content.trim().isNotEmpty) return content;
    final message = response['message'];
    if ((content == null || content is String) &&
        message is String &&
        message.trim().isNotEmpty) {
      return message;
    }
    final reasoning = response['reasoning_content'];
    return reasoning is String && reasoning.trim().isNotEmpty
        ? reasoning
        : content is String
            ? content
            : message is String
                ? message
                : null;
  }

  String? _firstNonEmptyResponseText(Map<String, dynamic> response) {
    for (final key in const ['message', 'content']) {
      final value = response[key];
      if (value is String && value.trim().isNotEmpty) return value;
    }
    return null;
  }

  String _publicText(String value, {int maximum = 1000}) {
    var safe = value
        .replaceAll(
          RegExp(
            r'<\s*think\b[^>]*>[\s\S]*?<\s*/\s*think\s*>',
            caseSensitive: false,
          ),
          '',
        )
        .replaceAll(
          RegExp(r'<\s*think\b[^>]*>[\s\S]*$', caseSensitive: false),
          '',
        )
        .replaceAll(
          RegExp(r'<\s*/?\s*think\b[^>]*>', caseSensitive: false),
          '',
        )
        .replaceAll(
          RegExp(
            r'(?:chain[- ]of[- ]thought|思维链|隐藏思维|私有思维|内部推理)'
            r'\s*[:：]?[\s\S]*$',
            caseSensitive: false,
          ),
          '[已隐藏]',
        )
        .trim();
    if (safe.length <= maximum) return safe;
    return maximum <= 1 ? '…' : '${safe.substring(0, maximum - 1)}…';
  }

  String _safeText(String value) => _publicText(value, maximum: 400);

  Map<String, dynamic> _decodeMap(String raw) {
    if (raw.trim().isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
    } on Object {
      return <String, dynamic>{};
    }
  }

  Map<String, dynamic> _safeExistingMap(String raw) {
    final decoded = _decodeMap(raw);
    if (workExecutionCheckpointRequiresReview(raw)) {
      // Preserve only typed gates and known blockers while a future checkpoint
      // waits for an explicit user resume. Dropping the discussion/folder
      // marker here would turn an unknown state into a legacy runnable task.
      return workExecutionCheckpointReviewMetadata(decoded);
    }
    final sanitized = _safePersistedValue(decoded, depth: 0);
    return sanitized is Map
        ? Map<String, dynamic>.from(sanitized)
        : <String, dynamic>{};
  }

  Object? _safePersistedValue(Object? value,
      {required int depth, String? key}) {
    if (key == WorkDiscussionState.jsonKey) {
      // Discussion state is a typed execution gate. Its nested fields include
      // names such as conversationId/contentScope that the generic checkpoint
      // redactor intentionally removes; treating the marker as an ordinary
      // map would make every model checkpoint lose the gate and break resume.
      if (value is! Map) return null;
      final state = WorkDiscussionState.tryParse(value);
      return state?.toJson();
    }
    if (key == 'workFailure' && value is Map) {
      // WorkFailure owns its own allow-list and redaction. Treating this
      // structured diagnostic as a normal result would drop completedContent
      // because the generic content deny-list is intentionally conservative.
      try {
        return WorkFailure.fromJson(Map<String, dynamic>.from(value)).toJson();
      } on Object {
        return null;
      }
    }
    if (key == 'approvalPlan' && value is Map) {
      // A command plan is structured, reviewable metadata. The generic
      // persistence deny-list intentionally blocks an opaque `command` key,
      // but applying that rule here would erase the command details needed by
      // the approval panel and make an unsafe command appear like an ordinary
      // approval. Validate and normalize the plan before retaining it so only
      // policy-produced fields can cross the checkpoint boundary.
      try {
        final plan = WorkChangePlan.fromJson(
          Map<String, dynamic>.from(value),
        );
        final safe = plan.toJson();
        final rawCommand = safe['command'];
        if (rawCommand is Map) {
          final command = Map<String, dynamic>.from(rawCommand);
          final arguments = command['arguments'];
          if (arguments is List) {
            command['arguments'] = arguments
                .whereType<String>()
                .map(
                  (argument) => const SearchSecretScanner().redact(
                    argument,
                    includeOpaqueTokens: true,
                  ),
                )
                .toList(growable: false);
          }
          safe['command'] = command;
        }
        return safe;
      } on Object {
        return null;
      }
    }
    if (depth > 8 || _isPrivateField(key)) return null;
    if (value == null || value is num || value is bool) return value;
    if (value is String) return _publicText(value, maximum: 6000);
    if (value is List) {
      return value
          .take(128)
          .map((item) => _safePersistedValue(item, depth: depth + 1))
          .toList(growable: false);
    }
    if (value is Map) {
      final output = <String, dynamic>{};
      for (final entry in value.entries.take(128)) {
        if (entry.key is! String ||
            (entry.key as String) != 'workFailure' &&
                _isPrivateField(entry.key as String)) {
          continue;
        }
        output[entry.key as String] = _safePersistedValue(
          entry.value,
          depth: depth + 1,
          key: entry.key as String,
        );
      }
      return output;
    }
    return null;
  }

  bool _isPrivateField(String? key) {
    if (key == null) return false;
    final normalized = key.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    const bodyFields = {
      'content',
      'contents',
      'body',
      'stdout',
      'stderr',
      'script',
      'command',
      'prompt',
      'raw',
      'text',
      'data',
      'output',
      'result',
      'response',
      'messages',
      'conversationhistory',
      'conversationid',
      'groupid',
      'privatechat',
      'filetext',
      'fulltext',
      'filebody',
      'filecontents',
      'token',
      'secret',
      'apikey',
      'authorization',
      'password',
    };
    return bodyFields.contains(normalized) ||
        normalized.contains('content') ||
        normalized.contains('fulltext') ||
        normalized.contains('chainofthought') ||
        normalized.contains('reasoning') ||
        normalized.contains('rawresponse') ||
        normalized.contains('malformedresponse') ||
        normalized == 'think';
  }
}

class _LoopState {
  final AgentTask task;
  final WorkTaskCancellation cancellation;
  final List<Map<String, dynamic>> conversationHistory;
  final Set<String> committedActionKeys;
  final List<WorkTaskEvent> events = <WorkTaskEvent>[];
  final List<String> publicUpdates = <String>[];
  final List<Map<String, dynamic>> recentResults = <Map<String, dynamic>>[];
  final List<Map<String, dynamic>> modelResults = <Map<String, dynamic>>[];
  ToolRequest? pendingToolRequest;
  Map<String, dynamic>? handoff;
  WorkFailure? failure;
  int modelRetryCount = 0;
  int toolRetryCount = 0;
  int protocolRepairAttempts = 0;
  int invalidCommandRepairCount = 0;
  int toolRepairCount = 0;
  int completionRepairCount = 0;
  int unchangedMutationCount = 0;

  /// Turn-scoped instruction describing what the last tool call got wrong. It
  /// is deliberately not durable: a resumed run rebuilds it from the
  /// checkpointed tool results instead of trusting in-memory text.
  String toolRepairInstruction = '';
  String completionRepairInstruction = '';
  final List<String> commandFailureKeys = <String>[];

  /// Counts identical process outcomes, independent of the command text, so a
  /// repaired-but-equally-broken command cannot repeat forever. Cleared with the
  /// failure history after a successful mutation.
  final Map<String, int> commandOutcomeSignatures = <String, int>{};

  _LoopState({
    required this.task,
    required this.cancellation,
    required this.conversationHistory,
    required this.committedActionKeys,
  });
}

extension<T> on List<T> {
  Iterable<T> takeLast(int count) => skip(length > count ? length - count : 0);
}

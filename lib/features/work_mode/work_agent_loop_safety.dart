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

/// 截断抢救运行态在 `executionStateJson` 里的键（见 `_TruncationSalvageState`）。
///
/// 名字要避开 `_isPrivateField` 的正文黑名单（含 `content` / `raw` / `reasoning`
/// 之类子串的键会在检查点里被丢掉），否则审批暂停时这份状态活不到恢复。
const String _truncationSalvageStateKey = 'truncationSalvage';

/// 「原地重建分段文件」判定态在 `executionStateJson` 里的键
/// （见 `_StagedRewriteState`）。同样避开 `_isPrivateField` 的正文黑名单，
/// 否则一次暂停就能让护栏失忆。
const String _stagedRewriteKey = 'stagedRewrite';

/// 「本次运行写出的路径」在 `executionStateJson` 里的键。
///
/// 与 `task.lastArtifactPaths` 分开：那一份是整条任务血缘的候选集合（产物契约与
/// 完成校验都要它，见 `_retainArtifactPaths` 的注释），这一份只服务失败报告里
/// 「本次运行写出的 N 个中间文件」那句话。私聊任务的一条记录是**长期血缘**
/// （2026-10-01 现场那条从 9-11 跨到当天），整份历史一附就是 19 个文件 /
/// 350 KB，而真正属于这次失败运行的只有 2 个。
///
/// 起算点是"最近一次进入 [WorkAgentLoop.execute]"：审批暂停后恢复、软上限后点
/// 「继续」都会重进一次，于是那之前写出的文件不计入本次运行——用户在更早那次
/// 的失败报告里已经见过它们，而且它们仍在磁盘上。
const String _runArtifactPathsKey = 'runArtifactPaths';

/// 失败报告该附哪些文件。
///
/// 有运行记录就用记录，**哪怕它是空的**：那次运行确实什么都没写成，报告就该
/// 这么说，而不是把更早运行的文件再列一遍。没有记录（本次改动之前落下的检查点、
/// 或在建立记录之前就返回的调用）才退回整份候选，行为与改动前一致。
///
/// 顶层函数而不是扩展成员：读它的那一侧在另一个库里（`default_work_task_runner.dart`），
/// 拿不到私有的 `_WorkAgentLoopSafety`。它因此自带一次解码，而不是复用扩展里的
/// `_safeExistingMap`。
List<String> workRunScopedArtifactPaths(AgentTask task) {
  final Map<String, dynamic> execution;
  try {
    final decoded = jsonDecode(task.executionStateJson);
    execution = decoded is Map
        ? Map<String, dynamic>.from(decoded)
        : const <String, dynamic>{};
  } on Object {
    return task.lastArtifactPaths;
  }
  if (!execution.containsKey(_runArtifactPathsKey)) {
    return task.lastArtifactPaths;
  }
  final value = execution[_runArtifactPathsKey];
  if (value is! List) return task.lastArtifactPaths;
  return value.whereType<String>().toList(growable: false);
}

/// How many distinct artifact paths one task remembers across its whole run.
///
/// The list is durable and is replayed into the model context every turn, so it
/// needs a bound. Which entries survive a full window is decided where the list
/// is written, next to the rule that keeps deliverables inside it.
const int _maxRetainedArtifactPaths = 64;

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

  /// 读回「原地重建分段文件」的判定态。
  ///
  /// 逐字段校验而不是 `as`：检查点是可被外部写回的持久数据，缺字段或类型不对时
  /// 必须退回"没有这个态"，而不是让一次恢复崩在类型转换上。
  _StagedRewriteState _loadStagedRewrite(AgentTask task) {
    final value = _safeExistingMap(task.executionStateJson)[_stagedRewriteKey];
    if (value is! Map) return const _StagedRewriteState();
    final count = value['count'];
    final path = value['lastPath'];
    final contents = value['writeDigests'];
    return _StagedRewriteState(
      // 判据只比较"是否达到阈值"，再往上的计数不参与任何决定，落盘时钳住即可。
      count: count is num
          ? count.clamp(0, _stagedRewriteRepeatedThreshold).toInt()
          : 0,
      corrected: value['corrected'] == true,
      lastPath: path is String ? path : '',
      // 旧版落盘的是"正文开头"指纹（`headFingerprints`），在整份正文的判据下
      // 永远匹配不上，刻意不读回来：留着只会占掉有限的槽位。
      writeDigests: contents is List          ? contents
              .whereType<String>()
              .take(_stagedRewriteFingerprintLimit)
              .toList(growable: false)
          : const <String>[],
    );
  }

  void _persistStagedRewrite(AgentTask task, _StagedRewriteState staged) {
    final execution = _decodeMap(task.executionStateJson);
    if (staged.isEmpty) {
      execution.remove(_stagedRewriteKey);
    } else {
      execution[_stagedRewriteKey] = {
        'count': staged.count,
        'corrected': staged.corrected,
        'lastPath': staged.lastPath,
        'writeDigests': staged.writeDigests,
      };
    }
    task.executionStateJson = jsonEncode(execution);
  }

  /// 开始一次新运行：本次运行写出的路径清零。
  ///
  /// 放在 `execute` 里终态早退**之后**是刻意的：终态任务上的一次迟到调用不该把
  /// 记录擦掉，否则紧随其后的失败报告会一个文件都附不出来。
  void _resetRunArtifactPaths(AgentTask task) {
    final execution = _decodeMap(task.executionStateJson);
    execution[_runArtifactPathsKey] = const <String>[];
    task.executionStateJson = jsonEncode(execution);
  }

  void _addRunArtifactPaths(AgentTask task, Set<String> written) {
    if (written.isEmpty) return;
    final execution = _decodeMap(task.executionStateJson);
    final merged = <String>{..._loadRunArtifactPaths(task), ...written}
        .toList(growable: false);
    execution[_runArtifactPathsKey] = merged.length <= _maxRetainedArtifactPaths
        ? merged
        : merged.sublist(merged.length - _maxRetainedArtifactPaths);
    task.executionStateJson = jsonEncode(execution);
  }

  List<String> _loadRunArtifactPaths(AgentTask task) {
    final value =
        _safeExistingMap(task.executionStateJson)[_runArtifactPathsKey];
    if (value is! List) return const <String>[];
    return value.whereType<String>().toList(growable: false);
  }

  /// 读回一次截断抢救的运行态（见 `_TruncationSalvageState`）。
  ///
  /// 逐字段校验而不是 `as`：检查点是可被外部写回的持久数据，缺字段或类型不对时
  /// 必须退回"没有运行态"，而不是让一次恢复崩在类型转换上。
  _TruncationSalvageState? _loadTruncationSalvage(AgentTask task) {
    final value =
        _safeExistingMap(task.executionStateJson)[_truncationSalvageStateKey];
    if (value is! Map) return null;
    final target = value['truncatedTargetPath'];
    final part = value['partPath'];
    final characters = value['salvagedCharacters'];
    if (target is! String || target.trim().isEmpty) return null;
    if (part is! String || part.trim().isEmpty) return null;
    if (characters is! int || characters < 1) return null;
    return _TruncationSalvageState(
      truncatedTargetPath: target,
      partPath: part,
      salvagedCharacters: characters,
    );
  }

  void _persistTruncationSalvage(
    AgentTask task,
    _TruncationSalvageState salvage,
  ) {
    final execution = _decodeMap(task.executionStateJson);
    execution[_truncationSalvageStateKey] = {
      'truncatedTargetPath': salvage.truncatedTargetPath,
      'partPath': salvage.partPath,
      'salvagedCharacters': salvage.salvagedCharacters,
    };
    task.executionStateJson = jsonEncode(execution);
  }

  void _clearTruncationSalvage(AgentTask task) {
    final execution = _decodeMap(task.executionStateJson);
    if (!execution.containsKey(_truncationSalvageStateKey)) return;
    execution.remove(_truncationSalvageStateKey);
    task.executionStateJson = execution.isEmpty ? '' : jsonEncode(execution);
  }

  /// 那次抢救写入是否**确实落盘**：它的分段路径出现在已提交的操作键里。
  ///
  /// `committedActionKeys` 的操作键是"工具名 + 规范化参数"，而 `path` 不是敏感字段
  /// （只有 content 之类被哈希），所以路径明文可比。这是唯一能区分"记录在"与
  /// "内容在"的现成证据：记录写在发起写入之前（否则审批暂停会把续写指令一起丢掉），
  /// 而用户拒绝审批、路径被拒或写入失败时记录都还在。
  bool _salvageLanded(_LoopState state, _TruncationSalvageState salvage) {
    for (final key in state.committedActionKeys) {
      if (key.contains(salvage.partPath)) return true;
    }
    return false;
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

  String _operationKey(AgentToolCall call, {AgentTask? task}) {
    final normalized = _canonical(call.arguments);
    final binding = task == null
        ? null
        : _decodeMap(task.executionStateJson)['workItemExecution'];
    final scope = binding is Map
        ? '${task!.id}:${binding['stage']}:${binding['workItemId']}:${binding['iterationId']}:${binding['requestRevision']}:${binding['verificationRevision']}:'
        : '';
    final legacy = '$scope${call.name.wireName}:$normalized';
    if (task != null && WorkTaskExecutionPolicy.isValidatedV2GroupTask(task)) {
      // Preserve old cached identities; new durable indexes contain hashes only.
      final cached = _decodeMap(task.executionStateJson)['committedActionKeys'];
      if (cached is List && cached.contains(legacy)) return legacy;
      return 'v2-action:${sha256.convert(utf8.encode('$legacy:${binding is Map ? binding['teamRevision'] : ''}:${task.characterId}'))}';
    }
    return legacy;
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
    return _retainArtifactPaths(task, <String>{
      ...task.lastArtifactPaths,
      ..._writtenArtifactPaths(call, result: result),
    });
  }

  /// 这一次工具调用写出的路径，不含已被剔掉的形态（截断抢救的暂存分段）。
  ///
  /// 与 [_updatedArtifactPaths] 分开是因为两者的消费者要的东西不同：那一份是
  /// 整条任务血缘的候选集合（产物契约、完成校验都要它），这一份只服务"本次运行
  /// 写了什么"（失败报告的附件）。
  Set<String> _writtenArtifactPaths(
    AgentToolCall call, {
    WorkToolResult? result,
  }) {
    final paths = <String>{};
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
        // 截断抢救的暂存分段与目标同目录、同扩展名、内容非空：一旦进产物历史，
        // `WorkArtifactDeliveryGuard` 就会把它当交付候选，用户每次遭遇截断都会多
        // 收到一个 `xxx.rescue-<hash>.md` 附件。它只是中转，不登记。
        // 判据来自命名规则的所有者，不在这里另写一份（见 `WorkTruncationSalvage`）。
        if (WorkTruncationSalvage.isRescuePath(value)) continue;
        paths.add(_publicText(value, maximum: 1000));
      }
    }
    final reportedArtifacts = result?.data['artifactPaths'];
    if (reportedArtifacts is List) {
      for (final value in reportedArtifacts.whereType<String>()) {
        if (value.trim().isEmpty) continue;
        if (WorkTruncationSalvage.isRescuePath(value)) continue;
        paths.add(_publicText(value, maximum: 1000));
      }
    }
    return paths;
  }

  /// Keeps a task's artifact history inside its retention window.
  ///
  /// The window exists because the list is durable (it is rewritten into the
  /// task checkpoint on every step) and is replayed into the model context each
  /// turn, so it cannot grow with the run. What it must not do is drop the
  /// *newest* entries, which is what `take(64)` did: one recorded run wrote
  /// 130+ distinct files (scripts, then 70 assets, then the two real
  /// deliverables), so the deliverables never entered the record at all and the
  /// completion guard reported "没有可读取的真实文件" while both files sat on
  /// disk — and no repair round could fix it, because rewriting the same path
  /// only appended it past the window again.
  ///
  /// Two rules keep the window useful:
  ///  * a path in a format the request (or the discussion contract) named as an
  ///    output is retained ahead of everything else — that is the deliverable
  ///    the completion guard has to find;
  ///  * the remaining slots go to the most recently written paths, because a
  ///    run writes its intermediates before it writes the deliverable.
  ///
  /// Insertion order is preserved so the record still reads as a history.
  List<String> _retainArtifactPaths(AgentTask task, Set<String> paths) {
    final ordered = paths.toList(growable: false);
    if (ordered.length <= _maxRetainedArtifactPaths) return ordered;

    final deliverableFormats =
        WorkArtifactDeliveryGuard.declaredOutputFormats(task);
    bool isDeliverable(String path) =>
        deliverableFormats.isNotEmpty &&
        deliverableFormats.any(
          (format) => WorkArtifactDeliveryGuard.matchesDeclaredFormat(
            path,
            format,
          ),
        );

    // Two passes, both newest-first, so the window never overflows: a request
    // naming a format (say “生成 50 张 png 图片”) declares the same format for
    // every file the run writes, and pinning those would otherwise fill the
    // window past its bound. Deliverables take the slots first because they are
    // what the completion guard has to find; intermediates take what is left.
    final retained = <String>{};
    for (final path in ordered.reversed) {
      if (retained.length >= _maxRetainedArtifactPaths) break;
      if (isDeliverable(path)) retained.add(path);
    }
    for (final path in ordered.reversed) {
      if (retained.length >= _maxRetainedArtifactPaths) break;
      retained.add(path);
    }
    return ordered.where(retained.contains).toList(growable: false);
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

  String _publicText(String value, {int maximum = 1000}) => _boundedText(
        _foldChainOfThought(_stripThinkBlocks(value)),
        maximum,
      );

  /// 续写指令（含其中回显的"已写入内容结尾"）专用的转义。
  ///
  /// 与 [_publicText] 只差一处：**不做思维链折叠**。那条正则
  /// （`chain-of-thought|思维链|隐藏思维|内部推理`）从命中处一直吃到字符串结尾，而
  /// 续写指令的最后一段正是回显的结尾——被抢救的正文里只要出现"思维链"（本 App 的
  /// 产物主题里很常见），模型拿到的结尾就整段变成 `[已隐藏]`，无缝续写失去接点。
  ///
  /// 密钥与 URL 脱敏照做（回显的是模型原文）。**本地路径刻意不脱敏**：这条指令必须
  /// 点名分段文件与目标文件的路径，而路径正则会把 `/work/report.rescue-3f9a2b1c.md`
  /// 整段换成 `[本地路径]`，模型就不知道该往哪个文件续写。事件、检查点与面板各有
  /// 自己的路径脱敏（事件存储 `_safeText` 那条），不受这里影响——面板详情同样有一条
  /// "需要点名的路径被脱敏就失去了意义"的既有口径。
  String _continuationText(String value, {int maximum = 1000}) => _boundedText(
        const SearchSecretScanner()
            .redact(_stripThinkBlocks(value), includeOpaqueTokens: true)
            .replaceAll(RegExp(r'https?://[^\s,;）)]+'), '[外部地址]'),
        maximum,
      );

  /// 抹掉模型写在正文里的 think 标记块。
  String _stripThinkBlocks(String value) => value
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
      );

  /// 把正文里从思维链标记起（含标记）到结尾的内容换成 `[已隐藏]`。
  String _foldChainOfThought(String value) => value.replaceAll(
        RegExp(
          r'(?:chain[- ]of[- ]thought|思维链|隐藏思维|私有思维|内部推理)'
          r'\s*[:：]?[\s\S]*$',
          caseSensitive: false,
        ),
        '[已隐藏]',
      );

  String _boundedText(String value, int maximum) {
    final safe = value.trim();
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

  /// 「原地重建分段文件」判定态，见 [_WorkAgentLoopActions._observeStagedRewrite]。
  _StagedRewriteState stagedRewrite = const _StagedRewriteState();

  /// Turn-scoped instruction describing what the last tool call got wrong. It
  /// is deliberately not durable: a resumed run rebuilds it from the
  /// checkpointed tool results instead of trusting in-memory text.
  String toolRepairInstruction = '';
  String completionRepairInstruction = '';

  /// 重建护栏给出的续写指令。与 [_StagedRewriteState] 同寿命：续写或成功合并
  /// 才会清掉它，所以"纠正过一次"这件事不会因为中间夹了一次读取就丢失。
  String stagedRewriteInstruction = '';

  /// 修复请求这一次拿到的正文（有界），只服务于协议失败的诊断。
  ///
  /// 协议重试记下的 `reason` 描述的多半是**修复后**那次解析的失败，而诊断里的
  /// 计数与首次正文都属于首次决策响应；两者对不上时，只留首次正文会让人按错误
  /// 的形状去推断。turn-scoped：每次修复前重置，不落检查点。
  String repairResponseSnippet = '';

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

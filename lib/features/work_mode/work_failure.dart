import 'dart:convert';

import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/agentic/tool_request.dart';
import 'package:chat_group/features/web_search/security/search_secret_scanner.dart';

import 'work_task_error_sanitizer.dart';
import 'work_command_policy.dart';
import 'work_tool_registry.dart';

/// The only failure categories that may cross the work-mode task boundary.
///
/// Keep this list deliberately small. A stable category lets the execution
/// panel choose a safe action without parsing provider or OS error strings.
enum WorkFailureType {
  retryableNetwork,
  modelProtocol,
  permissionDenied,
  authorizationLost,
  fileConflict,
  snapshotUnavailable,
  toolMissing,
  commandFailed,
  userActionRequired,
  internal,
}

/// A public, durable description of one failed or paused work-mode attempt.
///
/// Raw model responses, command output, credentials and full file contents are
/// intentionally not represented here. The object is safe to put in the
/// existing [AgentTask.executionStateJson] checkpoint and to render in the
/// panel after an app restart.
class WorkFailure {
  final WorkFailureType type;
  final String title;
  final String reason;
  final String technicalDetail;
  final List<String> completedContent;
  final bool retryable;
  final String suggestedAction;

  const WorkFailure({
    required this.type,
    required this.title,
    required this.reason,
    required this.technicalDetail,
    required this.completedContent,
    required this.retryable,
    required this.suggestedAction,
  });

  /// Alias used by callers that describe the field as the concrete reason.
  String get specificReason => reason;

  /// Alias used by UI code that calls the redacted diagnostics a safe detail.
  String get safeTechnicalDetail => technicalDetail;

  /// Alias for the next user-visible recovery instruction.
  String get nextAction => suggestedAction;

  bool get canRetry => retryable;

  bool get canContinue => type == WorkFailureType.userActionRequired;

  bool get canReauthorize =>
      type == WorkFailureType.permissionDenied ||
      type == WorkFailureType.authorizationLost;

  bool get canViewConflict => type == WorkFailureType.fileConflict;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'type': type.name,
        'title': title,
        'reason': reason,
        'technicalDetail': technicalDetail,
        'completedContent': completedContent,
        'retryable': retryable,
        'suggestedAction': suggestedAction,
      };

  String toJsonString() => jsonEncode(toJson());

  factory WorkFailure.fromJson(Map<String, dynamic> json) {
    final rawType = json['type'];
    final type = rawType is String
        ? WorkFailureType.values
            .where((item) => item.name == rawType)
            .firstOrNull
        : null;
    final resolved = type ?? WorkFailureType.internal;
    final defaults = WorkFailure.defaults(resolved);
    return WorkFailure(
      type: resolved,
      title: _clean(json['title'], fallback: defaults.title),
      reason: _clean(json['reason'], fallback: defaults.reason),
      technicalDetail: _clean(
        json['technicalDetail'] ?? json['safeTechnicalDetail'],
        fallback: defaults.technicalDetail,
      ),
      completedContent: _cleanList(json['completedContent']),
      retryable: json['retryable'] is bool
          ? json['retryable'] as bool
          : defaults.retryable,
      suggestedAction: _clean(
        json['suggestedAction'] ?? json['nextAction'],
        fallback: defaults.suggestedAction,
      ),
    );
  }

  /// Returns the durable failure stored by the work loop, if any.
  static WorkFailure? fromTask(AgentTask task) {
    final raw = task.executionStateJson.trim();
    if (raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['workFailure'] is! Map) return null;
      final failure = _migrateLegacyInvalidCommandFailure(
        task,
        WorkFailure.fromJson(
          Map<String, dynamic>.from(decoded['workFailure'] as Map),
        ),
      );
      if (failure.type == WorkFailureType.toolMissing) {
        final hasTrustedInstaller = _hasInstallableMissingTool(task, decoded);
        return hasTrustedInstaller
            ? _installToolGuidance(failure)
            : _manualToolGuidance(failure);
      }
      return failure;
    } on Object {
      // A malformed optional diagnostic must never erase the task itself.
      return null;
    }
  }

  /// Returns whether the current paused checkpoint, rather than an older tool
  /// result, authorizes the one-shot trusted installer action.
  static bool hasInstallableMissingTool(AgentTask task) {
    if (task.status != AgentTaskStatus.paused) return false;
    return _hasInstallableMissingTool(
      task,
      _decodeMetadata(task.executionStateJson),
    );
  }

  /// Older builds incorrectly persisted command-policy validation failures as
  /// user-action pauses. Reclassify those checkpoints when they are read so a
  /// task already visible in the panel loses the misleading Continue action.
  static WorkFailure _migrateLegacyInvalidCommandFailure(
    AgentTask task,
    WorkFailure failure,
  ) {
    if (failure.type != WorkFailureType.userActionRequired) return failure;
    final text =
        '${failure.reason} ${failure.technicalDetail} ${task.lastError}';
    if (!text.contains('命令包含控制字符')) return failure;
    return _fromSignals(
      code: 'modelProtocol',
      message: failure.reason,
      technicalDetail: failure.technicalDetail,
      scope: 'model',
      completedContent: failure.completedContent,
      retryableHint: true,
    );
  }

  static bool _hasInstallableMissingTool(
    AgentTask task,
    Map<dynamic, dynamic> metadata,
  ) {
    if (task.status != AgentTaskStatus.paused ||
        task.pendingToolRequestJson.trim().isEmpty) {
      return false;
    }
    final failure = metadata['workFailure'];
    final hasMissingToolBoundary = metadata['toolMissing'] == true ||
        failure is Map && failure['type'] == WorkFailureType.toolMissing.name;
    return hasMissingToolBoundary &&
        _pendingHasTrustedInstaller(task.pendingToolRequestJson);
  }

  /// Stores a redacted failure while preserving every other checkpoint key.
  static void persistOnTask(AgentTask task, WorkFailure failure) {
    final metadata = _decodeMetadata(task.executionStateJson);
    metadata['workFailure'] = failure.toJson();
    task.executionStateJson = jsonEncode(metadata);
  }

  /// Removes only the failure marker. Committed actions, queue and artifacts
  /// remain untouched so a retry starts at the last safe checkpoint.
  static void clearFromTask(AgentTask task) {
    final metadata = _decodeMetadata(task.executionStateJson);
    if (!metadata.containsKey('workFailure')) return;
    metadata.remove('workFailure');
    task.executionStateJson = metadata.isEmpty ? '' : jsonEncode(metadata);
  }

  /// Builds a failure from a normalized model response.
  factory WorkFailure.fromModelResponse(
    Map<String, dynamic> response, {
    Iterable<String> completedContent = const <String>[],
  }) {
    final statusCode = _statusCode(response['statusCode']);
    final code = _string(response['failureCode']);
    final rawMessage = _firstText(response, const <String>[
      'message',
      'error',
      'detail',
    ]);
    final message = _safeModelMessage(rawMessage);
    final content = response['content'];
    final reasoning = response['reasoning_content'];
    final hasNoContent = (content is! String || content.trim().isEmpty) &&
        (reasoning is! String || reasoning.trim().isEmpty);
    // Some streaming adapters report an empty body with success=false and no
    // separate error field. Treat that as the same protocol failure as a
    // nominally successful empty stream, but preserve explicit status/code or
    // timeout text so those signals still classify as network/auth failures.
    final isEmptyStream = hasNoContent &&
        statusCode == null &&
        code == null &&
        rawMessage.isEmpty;
    return _fromSignals(
      code: isEmptyStream ? 'modelProtocol' : code,
      statusCode: statusCode,
      message: message.isEmpty ? '模型没有返回可处理的响应。' : message,
      scope: 'model',
      completedContent: completedContent,
      retryableHint: response['retryable'] == true,
    );
  }

  /// Creates the protocol category for a parser failure without requiring the
  /// parser to expose its raw response.
  factory WorkFailure.fromSignalsForProtocol(
    String detail, {
    Iterable<String> completedContent = const <String>[],
  }) {
    return _fromSignals(
      code: 'modelProtocol',
      message: detail,
      technicalDetail: detail,
      scope: 'model',
      completedContent: completedContent,
    );
  }

  /// Creates a user-action pause while retaining the completed checkpoint.
  factory WorkFailure.fromSignalsForUserAction(
    String detail, {
    Iterable<String> completedContent = const <String>[],
  }) {
    return _fromSignals(
      code: 'userActionRequired',
      message: detail,
      technicalDetail: detail,
      scope: 'user',
      completedContent: completedContent,
    );
  }

  /// Generic typed factory for loop validation and adapter boundaries.
  factory WorkFailure.fromToolFailure({
    required String code,
    required String message,
    String scope = 'tool',
    Iterable<String> completedContent = const <String>[],
    bool? retryable,
  }) {
    return _fromSignals(
      code: code,
      message: message,
      technicalDetail: message,
      scope: scope,
      completedContent: completedContent,
      retryableHint: retryable,
    );
  }

  /// Builds a failure from a tool result without exposing its result body.
  factory WorkFailure.fromToolResult(
    WorkToolResult result, {
    Iterable<String> completedContent = const <String>[],
  }) {
    final code = result.failureCode;
    final scope = result.data['scope'] is String
        ? result.data['scope'] as String
        : 'tool';
    final isInvalidCommand = code == 'modelProtocol' &&
        result.data['rejectionKind'] ==
            WorkCommandRejectionKind.invalidInput.name;
    final technicalDetail = code == 'commandFailed' || isInvalidCommand
        ? _commandTechnicalDetail(result)
        : '';
    final failure = _fromSignals(
      code: code,
      message: result.message,
      technicalDetail: technicalDetail,
      scope: scope,
      completedContent: completedContent,
      // Snapshot completion can fail after the file write has already
      // committed. It is safe to retry the loop because the committed action
      // key is persisted and the mutation will be skipped on replay; the
      // retry is for checkpoint/bookkeeping recovery, not a second write.
      retryableHint: result.retryable ||
          result.committed &&
              (code == 'snapshotUnavailable' ||
                  result.message.contains('撤销记录')),
    );
    // An unknown executable is diagnosable but has no trusted package-manager
    // command. Keep the recovery copy aligned with the panel: do not promise
    // a "帮助安装工具" button when only official manual guidance exists.
    if (failure.type == WorkFailureType.toolMissing &&
        !_hasInstallCommand(result.data['installSuggestion'])) {
      return _manualToolGuidance(failure);
    }
    return failure;
  }

  static String _commandTechnicalDetail(WorkToolResult result) {
    final details = <String>[];
    final command = _clean(
      result.data['commandDisplay'] ?? result.data['command'],
      fallback: '',
    );
    if (command.isNotEmpty) details.add('命令：$command');

    final exitCode = result.data['exitCode'];
    if (exitCode is num || exitCode is String && exitCode.trim().isNotEmpty) {
      final exitText = exitCode is num ? '$exitCode' : exitCode as String;
      details.add('退出码：${_clean(exitText, fallback: '未知')}');
    }
    for (final entry in const <String, String>{
      'stderr': 'stderr',
      'stdout': 'stdout',
    }.entries) {
      final output = _clean(result.data[entry.key], fallback: '');
      if (output.isNotEmpty) details.add('${entry.value}：$output');
    }
    return details.join('；');
  }

  static bool _hasInstallCommand(Object? rawSuggestion) {
    if (rawSuggestion is! Map) return false;
    return rawSuggestion['installCommand'] is Map;
  }

  static WorkFailure _manualToolGuidance(WorkFailure failure) {
    return WorkFailure(
      type: failure.type,
      title: failure.title,
      reason: failure.reason,
      technicalDetail: failure.technicalDetail,
      completedContent: failure.completedContent,
      retryable: failure.retryable,
      suggestedAction: '请按上方可信来源的官方文档手动安装，或改用已存在的工具。',
    );
  }

  static WorkFailure _installToolGuidance(WorkFailure failure) {
    return WorkFailure(
      type: failure.type,
      title: failure.title,
      reason: failure.reason,
      technicalDetail: failure.technicalDetail,
      completedContent: failure.completedContent,
      retryable: failure.retryable,
      suggestedAction: '点击“帮助安装工具”完成一次性安装，或改用已存在的工具。',
    );
  }

  static bool _pendingHasTrustedInstaller(String raw) {
    if (raw.trim().isEmpty) return false;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map ||
          AgentToolName.fromWire(decoded['tool']?.toString() ?? '') !=
              AgentToolName.commandRun) {
        return false;
      }
      final args = decoded['args'];
      final executable = args is Map ? args['executable'] : null;
      return executable is String &&
          WorkCommandInstallSuggestion.hasTrustedInstaller(executable);
    } on Object {
      return false;
    }
  }

  /// Converts an exception at a named boundary into a public failure.
  factory WorkFailure.fromError(
    Object error, {
    String scope = '',
    Iterable<String> completedContent = const <String>[],
    bool? retryable,
  }) {
    final message = sanitizeWorkTaskError(error);
    final inferredStatus = _statusFromText(error.toString());
    return _fromSignals(
      message: message,
      technicalDetail: message,
      scope: scope,
      completedContent: completedContent,
      retryableHint: retryable,
      statusCode: inferredStatus,
    );
  }

  /// Default public copy for a category. Dynamic details are added by the
  /// factories above; keeping defaults here makes deserialization stable.
  static WorkFailure defaults(WorkFailureType type) {
    return switch (type) {
      WorkFailureType.retryableNetwork => const WorkFailure(
          type: WorkFailureType.retryableNetwork,
          title: '网络或模型服务暂时不可用',
          reason: '模型服务没有在本次尝试中完成响应。',
          technicalDetail: '网络请求失败或服务暂时不可用。',
          completedContent: <String>[],
          retryable: true,
          suggestedAction: '点击“重试”，从最近安全检查点继续；已提交的写入不会重复执行。',
        ),
      WorkFailureType.modelProtocol => const WorkFailure(
          type: WorkFailureType.modelProtocol,
          title: '模型返回格式无法识别',
          reason: '模型没有按工作模式协议返回可执行的 AgentDecision。',
          technicalDetail: '标准响应为空或 JSON 协议校验失败。',
          completedContent: <String>[],
          retryable: true,
          suggestedAction: '点击“重试”让模型重新按协议输出；仍失败时检查模型配置。',
        ),
      WorkFailureType.permissionDenied => const WorkFailure(
          type: WorkFailureType.permissionDenied,
          title: '当前操作没有权限',
          reason: '当前角色或目录权限不允许执行这一步。',
          technicalDetail: '权限门禁拒绝了操作，未执行未授权动作。',
          completedContent: <String>[],
          retryable: false,
          suggestedAction: '点击“重新授权”选择有权限的目录，或调整角色工具权限后继续。',
        ),
      WorkFailureType.authorizationLost => const WorkFailure(
          type: WorkFailureType.authorizationLost,
          title: '工作目录授权已失效',
          reason: '之前授权的目录已不存在、不可访问或不再满足当前操作。',
          technicalDetail: '授权路径重新校验失败，未执行新的文件变更。',
          completedContent: <String>[],
          retryable: false,
          suggestedAction: '点击“重新授权”选择原目录或新的可用工作目录。',
        ),
      WorkFailureType.fileConflict => const WorkFailure(
          type: WorkFailureType.fileConflict,
          title: '文件内容发生冲突',
          reason: '文件在任务读取后被外部修改，安全检查点不再匹配。',
          technicalDetail: '目标文件的当前状态与预期校验值不同，已拒绝覆盖。',
          completedContent: <String>[],
          retryable: false,
          suggestedAction: '点击“查看冲突”确认外部修改，再让任务重新规划。',
        ),
      WorkFailureType.snapshotUnavailable => const WorkFailure(
          type: WorkFailureType.snapshotUnavailable,
          title: '无法创建可撤销快照',
          reason: '当前磁盘或快照存储不可用，无法安全记录变更前状态。',
          technicalDetail: '快照预留/保存失败，默认未执行覆盖性变更。',
          completedContent: <String>[],
          retryable: false,
          suggestedAction: '释放磁盘空间后点击“重试”，或在明确确认无法撤销后批准这次变更。',
        ),
      WorkFailureType.toolMissing => const WorkFailure(
          type: WorkFailureType.toolMissing,
          title: '缺少执行工具',
          reason: '当前设备没有找到完成这一步所需的命令或运行时。',
          technicalDetail: '工具入口不存在，原任务检查点已保留。',
          completedContent: <String>[],
          retryable: false,
          suggestedAction: '点击“帮助安装工具”完成一次性安装，或改用已存在的工具。',
        ),
      WorkFailureType.commandFailed => const WorkFailure(
          type: WorkFailureType.commandFailed,
          title: '命令执行未完成',
          reason: '命令启动、运行或退出时发生失败。',
          technicalDetail: '命令进程没有返回成功状态。',
          completedContent: <String>[],
          retryable: false,
          suggestedAction: '请检查命令和工作目录后重新规划或重新发起任务；若命令需要登录，请先在外部终端处理。',
        ),
      WorkFailureType.userActionRequired => const WorkFailure(
          type: WorkFailureType.userActionRequired,
          title: '需要你的操作才能继续',
          reason: '这一步需要授权、登录、人工确认或浏览器交互。',
          technicalDetail: '任务已暂停，未丢弃队列、上下文或已完成动作。',
          completedContent: <String>[],
          retryable: false,
          suggestedAction: '完成提示的操作后点击“继续”；不确定时可点击“停止”。',
        ),
      WorkFailureType.internal => const WorkFailure(
          type: WorkFailureType.internal,
          title: '工作任务内部处理失败',
          reason: '应用在保存或执行任务时遇到未分类错误。',
          technicalDetail: '内部错误已脱敏记录，最近安全检查点仍被保留。',
          completedContent: <String>[],
          retryable: false,
          suggestedAction: '先检查任务上下文；确认环境正常后可重新发起任务或停止当前任务。',
        ),
    };
  }

  static WorkFailure _fromSignals({
    String? code,
    int? statusCode,
    required String message,
    String technicalDetail = '',
    String scope = '',
    Iterable<String> completedContent = const <String>[],
    bool? retryableHint,
  }) {
    final type = _typeFor(
      code: code,
      statusCode: statusCode,
      message: message,
      scope: scope,
    );
    final defaults = WorkFailure.defaults(type);
    final inferredRetryable = _retryableFor(
      type: type,
      code: code,
      statusCode: statusCode,
      message: message,
      scope: scope,
    );
    final retryable = retryableHint == true || inferredRetryable;
    final safeReason = _clean(
      message,
      fallback: defaults.reason,
    );
    final safeTechnical = _clean(
      technicalDetail.isEmpty ? message : technicalDetail,
      fallback: defaults.technicalDetail,
    );
    return WorkFailure(
      type: type,
      title: defaults.title,
      reason: safeReason,
      technicalDetail: safeTechnical,
      completedContent: _cleanList(completedContent),
      retryable: retryable,
      suggestedAction: retryable &&
              (type == WorkFailureType.commandFailed ||
                  type == WorkFailureType.snapshotUnavailable ||
                  type == WorkFailureType.internal)
          ? '点击“重试”，从最近安全检查点继续；已提交的写入不会重复执行。'
          : defaults.suggestedAction,
    );
  }

  static WorkFailureType _typeFor({
    String? code,
    int? statusCode,
    required String message,
    required String scope,
  }) {
    final normalizedCode = code?.trim().toLowerCase() ?? '';
    final normalized = '$normalizedCode ${message.toLowerCase()}';
    // HTTP status semantics are authoritative at the model boundary: a 401
    // means the saved credential/session is no longer valid, while 403 means
    // the caller is authenticated but lacks permission. Resolve these before
    // inspecting provider prose such as “permission denied”.
    // Command processes can legitimately print a three-digit exit code (for
    // example `exit 500`). Only treat status-like values as HTTP semantics at
    // provider/authorization boundaries; command failures remain command
    // failures so the panel does not offer an inappropriate network retry.
    if (scope != 'command' && statusCode == 401) {
      return WorkFailureType.authorizationLost;
    }
    if (scope != 'command' && statusCode == 403) {
      return WorkFailureType.permissionDenied;
    }
    if (scope != 'command' &&
        (statusCode == 429 || statusCode != null && statusCode >= 500)) {
      return WorkFailureType.retryableNetwork;
    }
    if (normalizedCode == 'modelprotocol' ||
        normalizedCode == 'protocol' ||
        normalizedCode == 'invalidresponse' ||
        normalizedCode == 'emptyresponse' ||
        normalizedCode == 'invalidcommand' && scope == 'model') {
      return WorkFailureType.modelProtocol;
    }
    if (normalizedCode == 'toolmissing' ||
        normalizedCode == 'missingtool' ||
        normalizedCode == 'tool_missing' ||
        normalized.contains('tool missing') ||
        normalized.contains('missing tool') ||
        normalized.contains('工具未注册') ||
        normalized.contains('缺失工具')) {
      return WorkFailureType.toolMissing;
    }
    if (normalizedCode == 'fileconflict' ||
        normalizedCode == 'conflict' ||
        normalizedCode == 'externalchange' ||
        normalizedCode == 'external_change' ||
        normalizedCode == 'externalmodified' ||
        normalizedCode == 'external_modified' ||
        normalizedCode == 'filechangedexternally' ||
        normalizedCode == 'file_changed_externally' ||
        normalizedCode == 'postconditionfailed' ||
        normalizedCode == 'postcondition_failed' ||
        normalizedCode == 'hashmismatch' ||
        normalizedCode == 'hash_mismatch' ||
        normalizedCode == 'postcondition_unverified' ||
        normalizedCode == 'targetexists' ||
        normalizedCode == 'fileexists' ||
        normalized.contains('外部修改') ||
        normalized.contains('external change') ||
        normalized.contains('externally changed') ||
        normalized.contains('external modification') ||
        normalized.contains('file changed') ||
        normalized.contains('conflict') ||
        normalized.contains('校验值不同') ||
        normalized.contains('hash mismatch')) {
      return WorkFailureType.fileConflict;
    }
    if (normalizedCode == 'snapshotunavailable' ||
        normalizedCode == 'snapshot_unavailable' ||
        normalizedCode == 'nosnapshot' ||
        normalizedCode == 'diskfull' ||
        normalizedCode == 'disk_full' ||
        normalizedCode == 'enospc' ||
        normalized.contains('快照') ||
        normalized.contains('no space left') ||
        normalized.contains('disk full') ||
        normalized.contains('磁盘满') ||
        normalized.contains('磁盘空间不足') ||
        normalized.contains('enospc')) {
      return WorkFailureType.snapshotUnavailable;
    }
    if (normalizedCode == 'authorizationlost' ||
        normalizedCode == 'authorizationrequired' ||
        normalizedCode == 'directorynotfound' ||
        normalizedCode == 'directory_not_found' ||
        normalizedCode == 'foldernotfound' ||
        normalizedCode == 'folder_not_found' ||
        normalizedCode == 'pathnotfound' ||
        normalizedCode == 'path_not_found' ||
        normalizedCode == 'workspaceunavailable' ||
        normalizedCode == 'workspace_unavailable' ||
        normalizedCode == 'foldergrantexpired' ||
        normalizedCode == 'folder_grant_expired' ||
        normalizedCode == 'folder_not_writable' ||
        normalizedCode == 'foldernotwritable' ||
        normalized.contains('授权目录') ||
        normalized.contains('directory does not exist') ||
        normalized.contains('directory not found') ||
        normalized.contains('invalid directory') ||
        normalized.contains('folder not found') ||
        normalized.contains('invalid folder') ||
        normalized.contains('目录不存在') ||
        normalized.contains('目录失效') ||
        normalized.contains('path is no longer available') ||
        normalized.contains('workspacepathexception') ||
        normalized.contains('已保存的工作目录') ||
        normalized.contains('工作目录不再受授权覆盖') ||
        normalized.contains('work directory is no longer authorized')) {
      return WorkFailureType.authorizationLost;
    }
    if (normalizedCode == 'permissiondenied' ||
        normalizedCode == 'accessdenied' ||
        normalizedCode == 'access_denied' ||
        normalizedCode == 'pathrejected' ||
        normalizedCode == 'notapproved' ||
        normalized.contains('权限不足') ||
        normalized.contains('permission denied') ||
        normalized.contains('access denied')) {
      return WorkFailureType.permissionDenied;
    }
    if (normalizedCode == 'useractionrequired' ||
        normalizedCode == 'userjudgmentrequired' ||
        normalizedCode == 'clarificationrequired' ||
        normalizedCode == 'loginrequired' ||
        normalizedCode == 'captchaRequired'.toLowerCase() ||
        normalizedCode == 'paymentrequired' ||
        normalizedCode == 'paywall' ||
        normalizedCode == 'browsermanualintervention' ||
        normalizedCode == 'browser_manual_intervention' ||
        normalized.contains('浏览器') &&
            (normalized.contains('人工') || normalized.contains('交互')) ||
        normalized.contains('需要确认') ||
        normalized.contains('需要登录') ||
        normalized.contains('captcha')) {
      return WorkFailureType.userActionRequired;
    }
    if (normalizedCode == 'commandfailed' ||
        normalizedCode == 'commandtimeout' ||
        normalizedCode == 'invalidcommand' && scope != 'model' ||
        normalizedCode == 'commandplanmissing' ||
        normalizedCode == 'commandlockscopemissing' ||
        normalizedCode == 'commandlockunavailable' ||
        normalizedCode == 'timeout' && scope == 'command' ||
        scope == 'command' &&
            (normalized.contains('命令') || normalized.contains('process'))) {
      return WorkFailureType.commandFailed;
    }
    if (normalizedCode == 'retryablenetwork' ||
        normalizedCode == 'ratelimited' ||
        normalizedCode == 'serviceunavailable' ||
        normalizedCode == 'temporarilyunavailable' ||
        normalizedCode == 'temporaryfailure' ||
        normalized.contains('网络') ||
        normalized.contains('connection') ||
        normalized.contains('timed out') ||
        normalized.contains('超时')) {
      return scope == 'command'
          ? WorkFailureType.commandFailed
          : WorkFailureType.retryableNetwork;
    }
    if (scope == 'model' && normalizedCode.isNotEmpty) {
      return WorkFailureType.modelProtocol;
    }
    return WorkFailureType.internal;
  }

  static bool _retryableFor({
    required WorkFailureType type,
    String? code,
    int? statusCode,
    required String message,
    required String scope,
  }) {
    if (type == WorkFailureType.retryableNetwork ||
        type == WorkFailureType.modelProtocol) {
      return true;
    }
    if (type == WorkFailureType.commandFailed) {
      final text = '${code ?? ''} $message'.toLowerCase();
      return text.contains('timeout') ||
          text.contains('timed out') ||
          text.contains('超时') ||
          text.contains('temporar') ||
          text.contains('暂时');
    }
    if (type == WorkFailureType.snapshotUnavailable) {
      final text = '${code ?? ''} $message'.toLowerCase();
      return text.contains('no space') ||
          text.contains('disk full') ||
          text.contains('enospc') ||
          text.contains('磁盘空间不足') ||
          text.contains('磁盘满');
    }
    return false;
  }

  static int? _statusCode(Object? value) {
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  static int? _statusFromText(String value) {
    final match = RegExp(r'\b(?:HTTP\s*)?(\d{3})\b', caseSensitive: false)
        .firstMatch(value);
    final parsed = match == null ? null : int.tryParse(match.group(1)!);
    return parsed != null && parsed >= 400 && parsed <= 599 ? parsed : null;
  }

  static String _firstText(Map<String, dynamic> source, List<String> keys) {
    for (final key in keys) {
      final value = source[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
    }
    return '';
  }

  /// Model adapters sometimes put the complete exception string in a
  /// response map. Keep the useful category-specific reason, but do not
  /// persist provider exception names, timeout payloads, or raw HTTP bodies.
  static String _safeModelMessage(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return '';
    final lower = value.toLowerCase();
    final looksLikeException = RegExp(
      r'^(?:[a-z_$][\w.$]*(?:exception|error)|exception|error)\b',
      caseSensitive: false,
    ).hasMatch(value);
    if (looksLikeException ||
        lower.contains('timeout') ||
        lower.contains('timed out') ||
        value.contains('超时') ||
        lower.contains('connection reset') ||
        lower.contains('socket')) {
      return sanitizeWorkTaskError(value);
    }
    return value;
  }

  static String _clean(
    Object? value, {
    required String fallback,
    bool replacePaths = true,
  }) {
    final raw = value is String ? value.trim() : '';
    if (raw.isEmpty) return fallback;
    var safe = const SearchSecretScanner().redact(
      raw,
      includeOpaqueTokens: true,
    );
    safe = safe.replaceAll(
      RegExp(r'https?://[^\s,;）)]+', caseSensitive: false),
      '[外部地址]',
    );
    if (replacePaths) {
      safe = safe.replaceAll(
        RegExp(
          r'(?:(?:[A-Za-z]:[\\/])|(?:\\\\|//)|/(?:Users|home|Volumes|private|tmp|var|etc|usr|opt|bin|sbin|Applications|System|Library|Desktop|Documents|Downloads)/)[^\s,;）)]*',
        ),
        '[本地路径]',
      );
    }
    safe = safe.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (safe.isEmpty) return fallback;
    const maximum = 1200;
    return safe.length <= maximum ? safe : '${safe.substring(0, maximum - 1)}…';
  }

  static List<String> _cleanList(Object? value) {
    if (value is! Iterable) return const <String>[];
    return value
        .whereType<Object>()
        .map((item) => _clean(item, fallback: ''))
        .where((item) => item.isNotEmpty)
        .take(32)
        .toList(growable: false);
  }

  static Map<String, dynamic> _decodeMetadata(String raw) {
    if (raw.trim().isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
    } on Object {
      // Replacing malformed optional metadata is safer than persisting raw
      // model text. The task's typed fields remain authoritative.
      return <String, dynamic>{};
    }
  }
}

/// Convenience extension for panel/coordinator call sites.
extension WorkFailureAgentTaskExtension on AgentTask {
  WorkFailure? get workFailure => WorkFailure.fromTask(this);
}

String? _string(Object? value) =>
    value is String && value.trim().isNotEmpty ? value.trim() : null;

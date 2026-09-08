part of 'work_agent_loop.dart';

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

  Map<String, dynamic> _safeResult(
    WorkToolResult result,
    AgentToolCall call,
  ) {
    final rejected = result.data['rejected'] == true;
    return {
      'tool': call.name.wireName,
      'status': result.status.name,
      'message': _publicText(result.message),
      // A rejected mutation is a successful no-op. Keep it explicitly
      // uncommitted in the model/checkpoint view so a later continuation does
      // not treat a user's refusal as durable work.
      'committed': !rejected &&
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
    return paths.take(64).toList(growable: false);
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
    if (result.requiresUserAction ||
        result.status == WorkToolResultStatus.permissionDenied) {
      return true;
    }
    final code = result.failureCode;
    if (code != null && WorkAgentLoop._userActionFailureCodes.contains(code)) {
      return true;
    }
    return RegExp(
      r'权限|permission|access\s+denied|登录|登入|验证码|付费墙|付款|授权|需要确认|需要判断|captcha|login|paywall|payment|authorization',
      caseSensitive: false,
    ).hasMatch(result.message);
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
    final sanitized = _safePersistedValue(decoded, depth: 0);
    return sanitized is Map
        ? Map<String, dynamic>.from(sanitized)
        : <String, dynamic>{};
  }

  Object? _safePersistedValue(Object? value,
      {required int depth, String? key}) {
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

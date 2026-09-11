import 'dart:async';
import 'dart:convert';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/features/agentic/tool_request.dart';
import 'package:chat_group/features/work_mode/agent_decision.dart';

/// The repair callback is supplied by the caller that owns the current model.
/// It receives the original response as data and may be invoked at most once.
typedef AgentDecisionRepair = FutureOr<String?> Function(String rawResponse);

class AgentDecisionParseResult {
  final AgentDecision? decision;
  final AgentDecisionParseFailure? failure;
  final String? detail;
  final bool usedReasoningContent;
  final bool repairAttempted;

  const AgentDecisionParseResult.success(
    this.decision, {
    this.usedReasoningContent = false,
    this.repairAttempted = false,
  })  : failure = null,
        detail = null;

  const AgentDecisionParseResult.failure({
    required this.failure,
    required this.detail,
    this.usedReasoningContent = false,
    this.repairAttempted = false,
  }) : decision = null;

  bool get isSuccess => decision != null;

  bool get isFailure => !isSuccess;

  String? get errorCode => failure?.wireName;

  AgentDecisionParseResult withMetadata({
    bool? usedReasoningContent,
    bool? repairAttempted,
  }) {
    if (isSuccess) {
      return AgentDecisionParseResult.success(
        decision,
        usedReasoningContent: usedReasoningContent ?? this.usedReasoningContent,
        repairAttempted: repairAttempted ?? this.repairAttempted,
      );
    }
    return AgentDecisionParseResult.failure(
      failure: failure!,
      detail: detail!,
      usedReasoningContent: usedReasoningContent ?? this.usedReasoningContent,
      repairAttempted: repairAttempted ?? this.repairAttempted,
    );
  }
}

/// Strict parser for the Stage 03 decision protocol.
///
/// This parser deliberately does not extract JSON from surrounding text. It
/// accepts either bare JSON or one exact Markdown fence containing only JSON;
/// XML, surrounding prose, and multiple objects remain invalid. A malformed
/// non-empty response may be sent to the same model once through
/// [AgentDecisionRepair]; the caller owns that model identity and the parser
/// never retries it itself.
class AgentDecisionParser {
  static const Set<String> _topLevelFields = {
    'action',
    'public_update',
    'tool',
    'completion',
  };

  static const Set<String> _planFields = {'steps'};
  static const Set<String> _clarifyFields = {'question', 'options'};
  static const Set<String> _handoffFields = {'target', 'summary'};
  static const Set<String> _finishFields = {'summary', 'evidence'};
  // Keep the protocol parser in lockstep with the production registry. The
  // legacy browser bridge still has its own parser, but browser.context is not
  // a Stage 03 WorkAgentLoop capability and must not look executable here.
  static const Set<AgentToolName> _stage03Tools = {
    AgentToolName.workspaceList,
    AgentToolName.workspaceRead,
    AgentToolName.workspaceSearch,
    AgentToolName.workspaceDocument,
    AgentToolName.workspacePatch,
    AgentToolName.workspaceRename,
    AgentToolName.workspaceDelete,
    AgentToolName.commandRun,
    AgentToolName.skillCreate,
    AgentToolName.skillDownload,
  };

  /// Optional injection keeps parser tests deterministic. Production work
  /// mode passes the resolved processing directory for the current task.
  final String? defaultCommandWorkingDirectory;

  const AgentDecisionParser({this.defaultCommandWorkingDirectory});

  /// Parses the response body using `content` first. `reasoningContent` is
  /// considered only when [content] is null/blank, matching ChatApiService's
  /// compatibility rule for reasoning models.
  Future<AgentDecisionParseResult> parse(
    String? content, {
    String? reasoningContent,
    AgentDecisionRepair? repair,
  }) async {
    final selected = _selectResponseContent(content, reasoningContent);
    if (selected.failure != null) {
      return AgentDecisionParseResult.failure(
        failure: selected.failure!,
        detail: selected.detail!,
        usedReasoningContent: selected.usedReasoningContent,
      );
    }

    final raw = selected.content!;
    final first = parseJson(raw).withMetadata(
      usedReasoningContent: selected.usedReasoningContent,
    );
    if (first.isSuccess || repair == null) return first;

    String? repaired;
    try {
      // Exactly one call. The malformed response is an untrusted data value,
      // not a prompt fragment interpreted by this parser.
      repaired = await repair(raw);
    } on Object {
      repaired = null;
    }
    if (repaired == null || repaired.trim().isEmpty) {
      final firstDetail = first.detail ?? '模型 JSON 校验失败。';
      return AgentDecisionParseResult.failure(
        failure: AgentDecisionParseFailure.modelProtocol,
        detail: '模型 JSON 修复失败：修复响应为空。首次校验失败：$firstDetail',
        usedReasoningContent: selected.usedReasoningContent,
        repairAttempted: true,
      );
    }
    return parseJson(repaired).withMetadata(
      usedReasoningContent: selected.usedReasoningContent,
      repairAttempted: true,
    );
  }

  /// Accepts either the normalized ChatApiService `message` field or a raw
  /// API-shaped `content`/`reasoning_content` pair without changing priority.
  Future<AgentDecisionParseResult> parseResponse(
    Map<String, dynamic> response, {
    AgentDecisionRepair? repair,
  }) {
    final rawContent = response['content'];
    if (rawContent != null && rawContent is! String) {
      return Future.value(const AgentDecisionParseResult.failure(
        failure: AgentDecisionParseFailure.modelProtocol,
        detail: '模型标准 content 必须是字符串。',
      ));
    }
    String? content;
    if (rawContent is String && rawContent.trim().isNotEmpty) {
      content = rawContent;
    } else {
      final rawMessage = response['message'];
      if (rawMessage != null && rawMessage is! String) {
        return Future.value(const AgentDecisionParseResult.failure(
          failure: AgentDecisionParseFailure.modelProtocol,
          detail: '模型 message 必须是字符串。',
        ));
      }
      final message = rawMessage as String?;
      if (message != null && message.trim().isNotEmpty) content = message;
    }
    // The compatibility channel is inspected only when standard content is
    // empty. A malformed, unused reasoning field must not override content.
    final shouldUseReasoning = content == null || content.trim().isEmpty;
    final rawReasoning = response['reasoning_content'];
    if (shouldUseReasoning && rawReasoning != null && rawReasoning is! String) {
      return Future.value(const AgentDecisionParseResult.failure(
        failure: AgentDecisionParseFailure.modelProtocol,
        detail: '模型 reasoning_content 必须是字符串。',
      ));
    }
    return parse(
      content,
      reasoningContent: shouldUseReasoning ? rawReasoning as String? : null,
      repair: repair,
    );
  }

  /// Parses exactly one JSON object. This method never repairs or extracts a
  /// nested object; callers that need repair must use [parse].
  AgentDecisionParseResult parseJson(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return _protocolFailure('JSON 响应不能为空。');
    }
    final fencedJson = _extractSingleJsonCodeFence(trimmed);
    if (trimmed.startsWith('```') && fencedJson == null) {
      return _protocolFailure('Markdown code fence 必须只包裹一个 JSON object。');
    }
    final jsonText = fencedJson ?? trimmed;

    Object? decoded;
    try {
      decoded = jsonDecode(jsonText);
    } on FormatException {
      return _protocolFailure('响应不是单个合法 JSON object。');
    }
    final object = _stringMap(decoded);
    if (object == null) {
      return _protocolFailure('顶层必须是 JSON object。');
    }
    if (!_hasExactlyFields(object, _topLevelFields)) {
      return _protocolFailure(
        '顶层字段必须且只能是 action、public_update、tool、completion。',
      );
    }

    final action = AgentDecisionAction.fromWire(object['action']);
    if (action == null) {
      return _protocolFailure('action 必须是 plan、tool、clarify、handoff 或 finish。');
    }
    final publicUpdate = object['public_update'];
    if (publicUpdate is! String || publicUpdate.trim().isEmpty) {
      return _protocolFailure('public_update 必须是非空字符串。');
    }
    if (_containsPrivateReasoning(publicUpdate)) {
      return _protocolFailure('public_update 只能描述公开动作、依据或结论。');
    }

    return switch (action) {
      AgentDecisionAction.plan => _parsePlan(publicUpdate, object),
      AgentDecisionAction.tool => _parseTool(publicUpdate, object),
      AgentDecisionAction.clarify => _parseClarify(publicUpdate, object),
      AgentDecisionAction.handoff => _parseHandoff(publicUpdate, object),
      AgentDecisionAction.finish => _parseFinish(publicUpdate, object),
    };
  }

  /// Unwraps only a complete outer fence. Returning null for any other shape
  /// prevents the parser from accidentally extracting JSON from prose or from
  /// accepting a partial/multiple Markdown response.
  String? _extractSingleJsonCodeFence(String trimmed) {
    if (!trimmed.startsWith('```')) return null;
    final lines = trimmed.split('\n');
    if (lines.length < 3 || lines.last.trim() != '```') return null;
    final language = lines.first.substring(3).trim().toLowerCase();
    if (language.isNotEmpty && language != 'json') return null;
    final body = lines.sublist(1, lines.length - 1).join('\n').trim();
    return body.isEmpty ? null : body;
  }

  _ResponseContent _selectResponseContent(
    String? content,
    String? reasoningContent,
  ) {
    if (content != null && content.trim().isNotEmpty) {
      return _ResponseContent(content: content);
    }
    if (reasoningContent != null && reasoningContent.trim().isNotEmpty) {
      return _ResponseContent(
        content: reasoningContent,
        usedReasoningContent: true,
      );
    }
    return const _ResponseContent(
      failure: AgentDecisionParseFailure.emptyResponse,
      detail: '模型 content 与 reasoning_content 均为空。',
    );
  }

  AgentDecisionParseResult _parsePlan(
    String publicUpdate,
    Map<String, dynamic> object,
  ) {
    if (object['tool'] != null) {
      return _protocolFailure('plan 的 tool 必须为 null。');
    }
    final completion = _stringMap(object['completion']);
    if (completion == null || !_hasOnlyFields(completion, _planFields)) {
      return _protocolFailure('plan 的 completion 必须只包含 steps。');
    }
    final rawSteps = completion['steps'];
    final steps = _stringList(rawSteps);
    if (steps == null || steps.isEmpty) {
      return _protocolFailure('plan.completion.steps 必须是非空字符串数组。');
    }
    return AgentDecisionParseResult.success(
      AgentPlanDecision(
        publicUpdate: publicUpdate,
        completion: AgentPlanCompletion(steps: steps),
      ),
    );
  }

  AgentDecisionParseResult _parseTool(
    String publicUpdate,
    Map<String, dynamic> object,
  ) {
    if (object['completion'] != null) {
      return _protocolFailure('tool 的 completion 必须为 null。');
    }
    final toolObject = _stringMap(object['tool']);
    if (toolObject == null ||
        !_hasExactlyFields(toolObject, {'name', 'arguments'})) {
      return _protocolFailure('tool 必须包含且只能包含 name、arguments。');
    }
    final name = AgentToolName.fromWire(toolObject['name']);
    if (name == null) {
      return _protocolFailure('tool.name 不是已注册工具。');
    }
    if (!_stage03Tools.contains(name)) {
      return _protocolFailure('tool.name 尚未接入 Stage 03 WorkAgentLoop。');
    }
    final rawArguments = _stringMap(toolObject['arguments']);
    if (rawArguments == null) {
      return _protocolFailure('tool.arguments 必须是 JSON object。');
    }
    final arguments = _normaliseToolArguments(name, rawArguments);
    final argumentError = _validateArguments(name, arguments);
    if (argumentError != null) return _protocolFailure(argumentError);
    return AgentDecisionParseResult.success(
      AgentToolDecision(
        publicUpdate: publicUpdate,
        tool: AgentToolCall(name: name, arguments: arguments),
      ),
    );
  }

  AgentDecisionParseResult _parseClarify(
    String publicUpdate,
    Map<String, dynamic> object,
  ) {
    if (object['tool'] != null) {
      return _protocolFailure('clarify 的 tool 必须为 null。');
    }
    final completion = _stringMap(object['completion']);
    if (completion == null || !_hasOnlyFields(completion, _clarifyFields)) {
      return _protocolFailure('clarify 的 completion 字段不合法。');
    }
    final question = completion['question'];
    if (question is! String || question.trim().isEmpty) {
      return _protocolFailure('clarify.completion.question 必须是非空字符串。');
    }
    final options = completion.containsKey('options')
        ? _stringList(completion['options'])
        : const <String>[];
    if (options == null) {
      return _protocolFailure('clarify.completion.options 必须是字符串数组。');
    }
    return AgentDecisionParseResult.success(
      AgentClarifyDecision(
        publicUpdate: publicUpdate,
        completion: AgentClarifyCompletion(
          question: question,
          options: options,
        ),
      ),
    );
  }

  AgentDecisionParseResult _parseHandoff(
    String publicUpdate,
    Map<String, dynamic> object,
  ) {
    if (object['tool'] != null) {
      return _protocolFailure('handoff 的 tool 必须为 null。');
    }
    final completion = _stringMap(object['completion']);
    if (completion == null || !_hasExactlyFields(completion, _handoffFields)) {
      return _protocolFailure('handoff 的 completion 必须包含 target、summary。');
    }
    final target = completion['target'];
    final summary = completion['summary'];
    if (target is! String ||
        target.trim().isEmpty ||
        summary is! String ||
        summary.trim().isEmpty) {
      return _protocolFailure('handoff 的 target、summary 必须是非空字符串。');
    }
    return AgentDecisionParseResult.success(
      AgentHandoffDecision(
        publicUpdate: publicUpdate,
        completion: AgentHandoffCompletion(
          target: target,
          summary: summary,
        ),
      ),
    );
  }

  AgentDecisionParseResult _parseFinish(
    String publicUpdate,
    Map<String, dynamic> object,
  ) {
    if (object['tool'] != null) {
      return _protocolFailure('finish 的 tool 必须为 null。');
    }
    final completion = _stringMap(object['completion']);
    if (completion == null || !_hasOnlyFields(completion, _finishFields)) {
      return _protocolFailure('finish 的 completion 字段不合法。');
    }
    final summary = completion['summary'];
    if (summary is! String || summary.trim().isEmpty) {
      return _protocolFailure('finish.completion.summary 必须是非空字符串。');
    }
    final evidence = completion.containsKey('evidence')
        ? _stringList(completion['evidence'])
        : const <String>[];
    if (evidence == null) {
      return _protocolFailure('finish.completion.evidence 必须是字符串数组。');
    }
    return AgentDecisionParseResult.success(
      AgentFinishDecision(
        publicUpdate: publicUpdate,
        completion: AgentFinishCompletion(
          summary: summary,
          evidence: evidence,
        ),
      ),
    );
  }

  String? _validateArguments(AgentToolName name, Map<String, dynamic> args) {
    if (!_isJsonValue(args)) return 'tool.arguments 含有不可序列化值。';
    switch (name) {
      case AgentToolName.workspaceList:
        return _validateFields(args, const {
          'path': _ArgumentType.string,
          'page': _ArgumentType.integer,
          'pageSize': _ArgumentType.integer,
          'recursive': _ArgumentType.boolean,
        });
      case AgentToolName.workspaceRead:
        return _validateRequiredFields(args, const {
          'path': _ArgumentType.string,
          'startByte': _ArgumentType.integer,
          'byteLength': _ArgumentType.integer,
        }, const {
          'path'
        });
      case AgentToolName.workspaceSearch:
        return _validateRequiredFields(args, const {
          'path': _ArgumentType.string,
          'query': _ArgumentType.string,
          'recursive': _ArgumentType.boolean,
          'caseSensitive': _ArgumentType.boolean,
        }, const {
          'path',
          'query'
        });
      case AgentToolName.workspaceDocument:
        return _validateRequiredFields(args, const {
          'path': _ArgumentType.string,
          'query': _ArgumentType.string,
        }, const {
          'path'
        });
      case AgentToolName.workspacePatch:
        return _validateWorkspacePatchArguments(args);
      case AgentToolName.workspaceRename:
        return _validateRequiredFields(args, const {
          'path': _ArgumentType.string,
          'destinationPath': _ArgumentType.string,
        }, const {
          'path',
          'destinationPath'
        });
      case AgentToolName.workspaceDelete:
        return _validateRequiredFields(args, const {
          'path': _ArgumentType.string,
        }, const {
          'path'
        });
      case AgentToolName.commandRun:
        return _validateCommandArguments(args);
      case AgentToolName.browserContext:
        return args.isEmpty ? null : 'browser.context 不接受参数。';
      case AgentToolName.skillCreate:
        return _validateSkillCreateArguments(args);
      case AgentToolName.skillDownload:
        return _validateFields(args, const {
          'name': _ArgumentType.string,
          'skillId': _ArgumentType.string,
          'id': _ArgumentType.string,
          'templateId': _ArgumentType.string,
          'url': _ArgumentType.string,
          'source': _ArgumentType.string,
        });
    }
  }

  Map<String, dynamic> _normaliseToolArguments(
    AgentToolName name,
    Map<String, dynamic> arguments,
  ) {
    if (name != AgentToolName.commandRun) return arguments;
    final normalised = Map<String, dynamic>.from(arguments);
    final encodedArguments = normalised['arguments'];
    final decodedArguments = encodedArguments is String
        ? _normaliseCommandArgumentList(encodedArguments)
        : null;
    if (decodedArguments != null) {
      normalised['arguments'] = decodedArguments;
    }
    final workingDirectory = normalised['workingDirectory'];
    if (workingDirectory is String && workingDirectory.trim().isEmpty) {
      final configured = defaultCommandWorkingDirectory?.trim();
      normalised['workingDirectory'] =
          configured != null && configured.isNotEmpty
              ? configured
              : DatabaseService.defaultAiProcessingDirectoryPath();
    }
    return normalised;
  }

  List<String>? _normaliseCommandArgumentList(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return const <String>[];
    try {
      final encoded = _stringList(jsonDecode(trimmed));
      if (encoded != null) return encoded;
    } on FormatException {
      // Fall through to the deliberately limited argv compatibility path.
    }
    // The command runner uses shell=false. Split only plain whitespace; never
    // interpret quotes, pipes, redirects, or control syntax as shell input.
    if (RegExp(r'''["'&|;<>\u0000-\u001f]''').hasMatch(trimmed)) {
      return null;
    }
    return trimmed.split(RegExp(r'\s+'));
  }

  String? _validateSkillCreateArguments(Map<String, dynamic> args) {
    final error = _validateFields(args, const {
      'name': _ArgumentType.string,
      'domain': _ArgumentType.string,
      'description': _ArgumentType.string,
      'instructions': _ArgumentType.stringList,
      'permissions': _ArgumentType.stringList,
    });
    if (error != null) return error;
    for (final key in const ['name', 'description']) {
      final value = args[key];
      if (value is! String || value.trim().isEmpty) {
        return 'skill.create.arguments.$key 必须是非空字符串。';
      }
    }
    final instructions = args['instructions'];
    if (instructions is! List ||
        instructions.isEmpty ||
        instructions.any(
          (item) => item is! String || item.trim().isEmpty,
        )) {
      return 'skill.create.arguments.instructions 必须是非空字符串数组。';
    }
    return null;
  }

  String? _validateWorkspacePatchArguments(Map<String, dynamic> args) {
    final error = _validateFields(args, const {
      'path': _ArgumentType.string,
      'content': _ArgumentType.string,
      'overwrite': _ArgumentType.boolean,
      'expectedSha256': _ArgumentType.string,
      'expectedFragment': _ArgumentType.string,
      'replacement': _ArgumentType.string,
    });
    if (error != null) return error;
    final path = args['path'];
    if (path is! String || path.trim().isEmpty) {
      return 'tool.arguments.path 必须是非空字符串。';
    }
    const patchKeys = {
      'expectedSha256',
      'expectedFragment',
      'replacement',
    };
    final hasExactPatch = args.keys.any(patchKeys.contains);
    if (!hasExactPatch && args['content'] is! String) {
      return 'workspace.patch 必须提供 content 或完整精确补丁字段。';
    }
    if (hasExactPatch) {
      if (args['content'] != null ||
          args['expectedSha256'] is! String ||
          args['expectedFragment'] is! String ||
          args['replacement'] is! String) {
        return 'workspace.patch 的精确补丁必须包含 expectedSha256、expectedFragment、replacement。';
      }
      if ((args['expectedSha256'] as String).trim().isEmpty) {
        return 'workspace.patch.expectedSha256 必须是非空字符串。';
      }
    }
    return null;
  }

  String? _validateCommandArguments(Map<String, dynamic> args) {
    const fields = {
      'executable': _ArgumentType.string,
      'arguments': _ArgumentType.stringList,
      'workingDirectory': _ArgumentType.string,
      'declaredImpact': _ArgumentType.stringList,
    };
    final error = _validateFields(args, fields);
    if (error != null) return error;
    for (final key in const ['executable', 'workingDirectory']) {
      final value = args[key];
      if (value is! String || value.trim().isEmpty) {
        return 'command.run.arguments.$key 必须是非空字符串。';
      }
    }
    final arguments = args['arguments'];
    if (arguments is! List || arguments.any((item) => item is! String)) {
      return 'command.run.arguments.arguments 必须是字符串数组。';
    }
    final impact = args['declaredImpact'];
    if (impact is! List ||
        impact.isEmpty ||
        impact.any((item) => item is! String || item.trim().isEmpty)) {
      return 'command.run.arguments.declaredImpact 必须是非空字符串数组。';
    }
    return null;
  }

  String? _validateRequiredFields(
    Map<String, dynamic> args,
    Map<String, _ArgumentType> fields,
    Set<String> required,
  ) {
    final error = _validateFields(args, fields);
    if (error != null) return error;
    for (final key in required) {
      final value = args[key];
      if (value is! String || value.trim().isEmpty) {
        return 'tool.arguments.$key 必须是非空字符串。';
      }
    }
    return null;
  }

  String? _validateFields(
    Map<String, dynamic> args,
    Map<String, _ArgumentType> fields,
  ) {
    for (final entry in args.entries) {
      final expected = fields[entry.key];
      if (expected == null) return 'tool.arguments 不支持字段 ${entry.key}。';
      if (!_matchesArgumentType(entry.value, expected)) {
        return 'tool.arguments.${entry.key} 类型不正确。';
      }
    }
    return null;
  }

  bool _matchesArgumentType(Object? value, _ArgumentType type) {
    return switch (type) {
      _ArgumentType.string => value is String,
      _ArgumentType.integer => value is int,
      _ArgumentType.boolean => value is bool,
      _ArgumentType.stringList =>
        value is List && value.every((item) => item is String),
    };
  }

  AgentDecisionParseResult _protocolFailure(String detail) =>
      AgentDecisionParseResult.failure(
        failure: AgentDecisionParseFailure.modelProtocol,
        detail: detail,
      );

  bool _hasExactlyFields(Map<String, dynamic> object, Set<String> fields) =>
      object.length == fields.length && object.keys.toSet().containsAll(fields);

  bool _hasOnlyFields(Map<String, dynamic> object, Set<String> fields) =>
      object.keys.every(fields.contains);

  Map<String, dynamic>? _stringMap(Object? value) {
    if (value is! Map) return null;
    if (value.keys.any((key) => key is! String)) return null;
    return Map<String, dynamic>.from(value);
  }

  List<String>? _stringList(Object? value) {
    if (value is! List ||
        value.any((item) => item is! String || item.trim().isEmpty)) {
      return null;
    }
    return List<String>.from(value);
  }

  bool _isJsonValue(Object? value, [int depth = 0]) {
    if (depth > 8) return false;
    if (value == null || value is String || value is bool) return true;
    if (value is num) return value.isFinite;
    if (value is List) {
      return value.length <= 100 &&
          value.every((item) => _isJsonValue(item, depth + 1));
    }
    if (value is Map) {
      return value.length <= 100 &&
          value.keys.every((key) => key is String) &&
          value.values.every((item) => _isJsonValue(item, depth + 1));
    }
    return false;
  }

  bool _containsPrivateReasoning(String value) {
    return RegExp(
      r'<\s*/?\s*think\b|chain[- ]of[- ]thought|思维链|隐藏思维|私有思维|内部推理',
      caseSensitive: false,
    ).hasMatch(value);
  }
}

enum _ArgumentType { string, integer, boolean, stringList }

class _ResponseContent {
  final String? content;
  final AgentDecisionParseFailure? failure;
  final String? detail;
  final bool usedReasoningContent;

  const _ResponseContent({
    this.content,
    this.failure,
    this.detail,
    this.usedReasoningContent = false,
  });
}

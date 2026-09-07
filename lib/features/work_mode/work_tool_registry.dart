import 'dart:async';

import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/core/retry_handler.dart';
import 'package:chat_group/features/work_mode/agent_decision.dart';
import 'package:chat_group/features/agentic/tool_request.dart';
import 'package:chat_group/features/work_mode/work_task_coordinator.dart';
import 'package:chat_group/features/work_mode/work_task_error_sanitizer.dart';

/// Whether a registered tool can change local or external state.
enum WorkToolAccess { readOnly, mutation }

/// Technical-design alias used by callers that describe tools as kinds.
typedef WorkToolKind = WorkToolAccess;

/// The small schema vocabulary needed by work-mode tools.
enum WorkToolValueType {
  string,
  integer,
  number,
  boolean,
  stringList,
  object,
  any,
}

/// A closed JSON-object schema for one tool's arguments.
class WorkToolSchema {
  final Map<String, WorkToolValueType> fields;
  final Set<String> required;
  final bool allowAdditional;

  const WorkToolSchema({
    this.fields = const {},
    this.required = const {},
    this.allowAdditional = false,
  });

  String? validate(Map<String, dynamic> arguments) {
    for (final key in required) {
      if (!arguments.containsKey(key)) {
        return '缺少必填参数：$key';
      }
    }
    for (final entry in arguments.entries) {
      final expected = fields[entry.key];
      if (expected == null && !allowAdditional) {
        return '不支持参数：${entry.key}';
      }
      if (expected != null && !_matches(entry.value, expected)) {
        return '参数 ${entry.key} 类型不正确。';
      }
    }
    return null;
  }

  static bool _matches(Object? value, WorkToolValueType type) {
    return switch (type) {
      WorkToolValueType.string => value is String,
      WorkToolValueType.integer => value is int,
      WorkToolValueType.number => value is num,
      WorkToolValueType.boolean => value is bool,
      WorkToolValueType.stringList =>
        value is List && value.every((item) => item is String),
      WorkToolValueType.object => value is Map && _isJsonValue(value),
      WorkToolValueType.any => _isJsonValue(value),
    };
  }

  static bool _isJsonValue(Object? value, [int depth = 0]) {
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

  static bool isJsonValue(Object? value) => _isJsonValue(value);
}

/// The callback used by a registered tool. It receives only validated JSON
/// arguments and a task-scoped cancellation handle.
typedef WorkToolHandler = FutureOr<WorkToolResult> Function(
  WorkToolInvocation invocation,
);

/// A validated invocation passed to a tool handler or mutation gate.
class WorkToolInvocation {
  final AgentTask task;
  final AgentToolCall call;
  final WorkToolExecutionContext context;

  const WorkToolInvocation({
    required this.task,
    required this.call,
    required this.context,
  });

  AgentToolName get name => call.name;

  Map<String, dynamic> get arguments => call.arguments;
}

/// The public outcome of one tool attempt. Tool handlers must not return raw
/// model output or secrets in [data]; it is safe-result data for the next
/// checkpoint and event only.
enum WorkToolResultStatus {
  success,
  alreadyCommitted,
  retryableFailure,
  permissionDenied,
  pathRejected,
  waitingForApproval,
  paused,
  failed,
}

class WorkToolResult {
  static const Set<String> retryableFailureCodes = {
    'retryableNetwork',
    'rateLimited',
    'timeout',
    'serviceUnavailable',
    'temporarilyUnavailable',
  };
  static const Set<String> nonRetryableFailureCodes = {
    'permissionDenied',
    'pathRejected',
    'userActionRequired',
    'userJudgmentRequired',
    'clarificationRequired',
    'authorizationRequired',
    'authorizationLost',
    'loginRequired',
    'captchaRequired',
    'paymentRequired',
    'paywall',
    'toolMissing',
    'softLimit',
  };

  final WorkToolResultStatus status;
  final String message;
  final Map<String, dynamic> data;
  final String? failureCode;
  final bool committed;

  WorkToolResult({
    required this.status,
    this.message = '',
    Map<String, dynamic>? data,
    this.failureCode,
    this.committed = false,
  }) : data = Map.unmodifiable(Map<String, dynamic>.from(data ?? const {}));

  const WorkToolResult.success({
    this.message = '',
    this.data = const {},
    this.committed = false,
  })  : status = WorkToolResultStatus.success,
        failureCode = null;

  const WorkToolResult.alreadyCommitted({
    this.message = '该动作已在先前检查点提交，已跳过重复执行。',
    this.data = const {},
  })  : status = WorkToolResultStatus.alreadyCommitted,
        failureCode = null,
        committed = true;

  const WorkToolResult.retryableFailure({
    required this.message,
    this.data = const {},
    this.failureCode = 'retryableNetwork',
  })  : status = WorkToolResultStatus.retryableFailure,
        committed = false;

  const WorkToolResult.permissionDenied({
    required this.message,
    this.data = const {},
    this.failureCode = 'permissionDenied',
  })  : status = WorkToolResultStatus.permissionDenied,
        committed = false;

  const WorkToolResult.pathRejected({
    required this.message,
    this.data = const {},
    this.failureCode = 'pathRejected',
  })  : status = WorkToolResultStatus.pathRejected,
        committed = false;

  const WorkToolResult.waitingForApproval({
    required this.message,
    this.data = const {},
    this.failureCode = 'userActionRequired',
  })  : status = WorkToolResultStatus.waitingForApproval,
        committed = false;

  const WorkToolResult.paused({
    required this.message,
    this.data = const {},
    this.failureCode = 'userActionRequired',
  })  : status = WorkToolResultStatus.paused,
        committed = false;

  const WorkToolResult.failed({
    required this.message,
    this.data = const {},
    this.failureCode = 'internal',
    this.committed = false,
  }) : status = WorkToolResultStatus.failed;

  bool get succeeded =>
      status == WorkToolResultStatus.success ||
      status == WorkToolResultStatus.alreadyCommitted;

  bool get retryable =>
      !requiresUserAction &&
      !isRejected &&
      !(failureCode != null &&
          nonRetryableFailureCodes.contains(failureCode)) &&
      (status == WorkToolResultStatus.retryableFailure ||
          (failureCode != null && retryableFailureCodes.contains(failureCode)));

  bool get requiresUserAction =>
      status == WorkToolResultStatus.waitingForApproval ||
      status == WorkToolResultStatus.paused;

  bool get isRejected =>
      status == WorkToolResultStatus.permissionDenied ||
      status == WorkToolResultStatus.pathRejected;
}

/// The context shared with tools. It is intentionally small and has no model
/// response or private reasoning field.
class WorkToolExecutionContext {
  final AgentTask task;
  final WorkTaskCancellation? cancellation;
  final DateTime Function() clock;
  final Map<String, dynamic> state;
  final WorkToolActionStarter? _actionStarter;

  WorkToolExecutionContext({
    required this.task,
    this.cancellation,
    DateTime Function()? clock,
    Map<String, dynamic>? state,
    WorkToolActionStarter? actionStarter,
  })  : clock = clock ?? DateTime.now,
        state = Map.unmodifiable(Map<String, dynamic>.from(state ?? const {})),
        _actionStarter = actionStarter;

  bool get isCancelled => cancellation?.isCancelled == true;

  Future<WorkToolResult?> startAction() async => _actionStarter?.call();
}

/// One policy/approval/snapshot/lock gate. Returning a result stops the
/// pipeline; returning null allows the next gate to run.
typedef WorkToolMutationGate = FutureOr<WorkToolResult?> Function(
  WorkToolInvocation invocation,
);

/// Called immediately before a real tool handler starts. A loop can use this
/// boundary to account for an action only after policy/approval/snapshot/lock
/// gates have all passed.
typedef WorkToolActionStarter = FutureOr<WorkToolResult?> Function();

/// Explicit mutation pipeline. Keeping the four gates named and ordered makes
/// it impossible for a mutation definition to accidentally execute before
/// policy, approval, snapshot and lock checks.
class WorkToolMutationPipeline {
  final WorkToolMutationGate? policy;
  final WorkToolMutationGate? approval;
  final WorkToolMutationGate? snapshot;
  final WorkToolMutationGate? lock;

  const WorkToolMutationPipeline({
    this.policy,
    this.approval,
    this.snapshot,
    this.lock,
  });

  Future<WorkToolResult> run(
    WorkToolInvocation invocation,
    WorkToolHandler handler,
  ) async {
    for (final gate in <WorkToolMutationGate?>[
      policy,
      approval,
      snapshot,
      lock,
    ]) {
      if (invocation.context.isCancelled) {
        return const WorkToolResult.paused(message: '工具执行已停止。');
      }
      final result = await _runGate(invocation, gate);
      if (result != null) {
        // A rejection is a successful, safe no-op.  Do not continue through
        // snapshot/lock gates into the real handler, otherwise a mutation
        // gate that clears its one-shot decision could accidentally execute
        // the very change the user rejected.
        if (result.succeeded && result.data['rejected'] == true) return result;
        return result;
      }
    }
    if (invocation.context.isCancelled) {
      return const WorkToolResult.paused(message: '工具执行已停止。');
    }
    final startResult = await invocation.context.startAction();
    if (startResult != null) return startResult;
    if (invocation.context.isCancelled) {
      return const WorkToolResult.paused(message: '工具执行已停止。');
    }
    return await handler(invocation);
  }

  Future<WorkToolResult?> _runGate(
    WorkToolInvocation invocation,
    WorkToolMutationGate? gate,
  ) {
    if (gate == null) return Future<WorkToolResult?>.value();
    final pending = Future<WorkToolResult?>.value(gate(invocation));
    final cancellation = invocation.context.cancellation;
    if (cancellation == null) return pending;
    return Future.any<WorkToolResult?>([
      pending,
      cancellation.whenCancelled.then<WorkToolResult?>(
        (_) => const WorkToolResult.paused(message: '工具执行已停止。'),
      ),
    ]);
  }
}

class WorkToolDefinition {
  final AgentToolName name;
  final WorkToolAccess access;
  final WorkToolSchema schema;
  final WorkToolHandler handler;
  final WorkToolMutationPipeline? mutationPipeline;

  const WorkToolDefinition({
    required this.name,
    required this.access,
    required this.schema,
    required this.handler,
    this.mutationPipeline,
  });

  bool get isReadOnly => access == WorkToolAccess.readOnly;

  bool get isMutation => access == WorkToolAccess.mutation;
}

class WorkToolValidationResult {
  final WorkToolDefinition? definition;
  final String? error;

  const WorkToolValidationResult.valid(this.definition) : error = null;

  const WorkToolValidationResult.invalid(this.error) : definition = null;

  bool get isValid => definition != null;
}

/// A closed registry for structured work-mode tools. There is deliberately no
/// shell fallback: a tool must be explicitly registered before it can run.
class WorkToolRegistry {
  final Map<String, WorkToolDefinition> _definitions =
      <String, WorkToolDefinition>{};
  final WorkToolMutationPipeline? mutationPipeline;

  WorkToolRegistry({
    Iterable<WorkToolDefinition> definitions = const <WorkToolDefinition>[],
    this.mutationPipeline,
  }) {
    for (final definition in definitions) {
      register(definition);
    }
  }

  Iterable<WorkToolDefinition> get definitions =>
      List<WorkToolDefinition>.unmodifiable(_definitions.values);

  void register(WorkToolDefinition definition) {
    final key = definition.name.wireName;
    if (_definitions.containsKey(key)) {
      throw StateError('工具已注册：$key');
    }
    _definitions[key] = definition;
  }

  void registerAll(Iterable<WorkToolDefinition> definitions) {
    for (final definition in definitions) {
      register(definition);
    }
  }

  bool contains(String name) => _definitions.containsKey(name);

  WorkToolDefinition? definitionFor(AgentToolName name) =>
      _definitions[name.wireName];

  WorkToolValidationResult validateName(String name) {
    final definition = _definitions[name];
    return definition == null
        ? const WorkToolValidationResult.invalid('工具未注册。')
        : WorkToolValidationResult.valid(definition);
  }

  WorkToolValidationResult validate(AgentToolCall call) {
    final byName = validateName(call.name.wireName);
    if (!byName.isValid) return byName;
    if (!WorkToolSchema.isJsonValue(call.arguments)) {
      return const WorkToolValidationResult.invalid('工具参数必须是有限 JSON 值。');
    }
    final schemaError = byName.definition!.schema.validate(call.arguments);
    return schemaError == null
        ? byName
        : WorkToolValidationResult.invalid(schemaError);
  }

  Future<WorkToolResult> execute(
    AgentToolCall call, {
    required WorkToolExecutionContext context,
  }) async {
    final validation = validate(call);
    final definition = validation.definition;
    if (definition == null) {
      return WorkToolResult.failed(
        message: validation.error ?? '工具校验失败。',
        failureCode: 'toolMissing',
      );
    }
    if (context.isCancelled) {
      return const WorkToolResult.paused(message: '工具执行已停止。');
    }

    final invocation = WorkToolInvocation(
      task: context.task,
      call: call,
      context: context,
    );
    try {
      if (definition.isReadOnly) {
        final startResult = await context.startAction();
        if (startResult != null) return startResult;
        if (context.isCancelled) {
          return const WorkToolResult.paused(message: '工具执行已停止。');
        }
        return await definition.handler(invocation);
      }
      final pipeline = definition.mutationPipeline ?? mutationPipeline;
      if (pipeline == null) {
        return const WorkToolResult.failed(
          message: '变更工具缺少策略、审批、快照和锁流水线，未执行。',
          failureCode: 'mutationPipelineMissing',
        );
      }
      return await pipeline.run(invocation, definition.handler);
    } on Object catch (error) {
      if (RetryHandler.isTransientError(error)) {
        return WorkToolResult.retryableFailure(
          message: _safeError(error),
        );
      }
      return WorkToolResult.failed(
        message: _safeError(error),
        failureCode: 'internal',
      );
    }
  }

  static String _safeError(Object error) {
    final value = sanitizeWorkTaskError(error);
    return value == '任务执行失败' ? '工具执行失败。' : value;
  }
}

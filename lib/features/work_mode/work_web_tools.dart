import 'dart:convert';

import '../../core/models/ai_character.dart';
import '../../core/models/agent_task.dart';
import 'package:path/path.dart' as p;
import '../web_search/application/autonomous_web_policy.dart';
import 'workspace_path_policy.dart';
import '../agentic/tool_request.dart';
import '../web_search/desktop/desktop_web_service.dart';
import 'work_tool_registry.dart';

const _autonomousNetworkToolNames = <AgentToolName>{
  AgentToolName.webSearch,
  AgentToolName.webRead,
  AgentToolName.webDownload,
  AgentToolName.skillDownload,
  AgentToolName.skillGithubSearch,
  AgentToolName.skillGithubImport,
  AgentToolName.skillResourceRead,
};

bool workModeAllowsAutonomousNetworkTools(AICharacter character) =>
    AutonomousWebPolicy.allows(character, AutonomousWebScene.workMode);

List<WorkToolDefinition> filterWorkModeNetworkTools(
  Iterable<WorkToolDefinition> definitions,
  AICharacter character,
) {
  if (workModeAllowsAutonomousNetworkTools(character)) {
    return definitions.toList(growable: false);
  }
  return definitions
      .where((definition) =>
          !_autonomousNetworkToolNames.contains(definition.name))
      .toList(growable: false);
}

Map<String, dynamic> safeWorkWebFailureReceipt(Object error) {
  if (error is DesktopWebToolFailure) {
    return {
      ...error.toSafeMap(),
      'error': error.safeMessage,
    };
  }
  if (error is StateError && error.message == '免 Key 搜索未返回可用来源。') {
    return {
      'code': 'NO_SEARCH_RESULTS',
      'error': error.message,
    };
  }
  return const {
    'code': 'REQUEST_FAILED',
    'error': '公开来源请求失败，未取得内容。',
  };
}

Map<String, dynamic> recordWorkWebToolReceipt({
  required DesktopWebService service,
  required String tool,
  required Map<String, dynamic> arguments,
  required Object result,
  void Function()? onEvidenceChanged,
}) {
  final receipt = service.recordToolReceipt(
    tool: tool,
    arguments: arguments,
    result: result,
  );
  onEvidenceChanged?.call();
  return receipt;
}

void persistWorkWebEvidence(AgentTask task, DesktopWebService service) {
  Map<String, dynamic> state;
  try {
    final decoded = jsonDecode(task.executionStateJson);
    state = decoded is Map ? Map<String, dynamic>.from(decoded) : {};
  } on Object {
    state = {};
  }
  state['webSources'] = service.exportSources();

  final previous = state['webToolReceipts'];
  final merged = <Map<String, dynamic>>[];
  final seen = <String>{};
  void addReceipt(Object? value) {
    if (value is! Map) return;
    final receipt = Map<String, dynamic>.from(value);
    final id = receipt['receiptId'];
    if (id is! String || id.trim().isEmpty || !seen.add(id)) return;
    merged.add(receipt);
  }

  if (previous is List) {
    for (final receipt in previous) {
      addReceipt(receipt);
    }
  }
  for (final receipt in service.exportToolReceipts()) {
    addReceipt(receipt);
  }
  if (merged.length > 100) {
    merged.removeRange(0, merged.length - 100);
  }
  if (merged.isNotEmpty || previous is List) {
    state['webToolReceipts'] = merged;
  }
  task.executionStateJson = jsonEncode(state);
}

/// Shared definitions for execution and discussion; downloads use the mutation pipeline separately.
List<WorkToolDefinition> webInvestigationTools(DesktopWebService service,
        {void Function()? onEvidenceChanged}) =>
    [
      WorkToolDefinition(
        name: AgentToolName.webSearch,
        access: WorkToolAccess.readOnly,
        schema: const WorkToolSchema(
          fields: {'query': WorkToolValueType.string},
          required: {'query'},
        ),
        handler: (invocation) async {
          if (invocation.context.isCancelled) {
            return const WorkToolResult.paused(message: '联网查询已停止。');
          }
          final query = invocation.arguments['query'] as String;
          late final List<Map<String, String>> results;
          try {
            results = await service.search(
              query,
              cancellation: invocation.context.cancellation?.whenCancelled,
            );
          } on Object catch (error) {
            recordWorkWebToolReceipt(
              service: service,
              tool: 'web.search',
              arguments: invocation.arguments,
              result: safeWorkWebFailureReceipt(error),
              onEvidenceChanged: onEvidenceChanged,
            );
            rethrow;
          }
          final toolReceipt = recordWorkWebToolReceipt(
            service: service,
            tool: 'web.search',
            arguments: invocation.arguments,
            result: results,
            onEvidenceChanged: onEvidenceChanged,
          );
          if (invocation.context.isCancelled) {
            return const WorkToolResult.paused(message: '联网查询已停止。');
          }
          return WorkToolResult.success(
            message: '已取得公开网络来源。',
            data: {'sources': results, 'toolReceipt': toolReceipt},
          );
        },
      ),
      WorkToolDefinition(
        name: AgentToolName.webRead,
        access: WorkToolAccess.readOnly,
        schema: const WorkToolSchema(fields: {
          'sourceId': WorkToolValueType.string,
          'startSection': WorkToolValueType.integer,
        }, required: {
          'sourceId'
        }),
        handler: (invocation) async {
          if (invocation.context.isCancelled) {
            return const WorkToolResult.paused(message: '来源读取已停止。');
          }
          final sourceId = invocation.arguments['sourceId'] as String;
          late final Map<String, dynamic> result;
          try {
            result = await service.read(
              sourceId,
              startSection: invocation.arguments['startSection'] as int? ?? 0,
              cancellation: invocation.context.cancellation?.whenCancelled,
            );
          } on Object catch (error) {
            recordWorkWebToolReceipt(
              service: service,
              tool: 'web.read',
              arguments: invocation.arguments,
              result: safeWorkWebFailureReceipt(error),
              onEvidenceChanged: onEvidenceChanged,
            );
            rethrow;
          }
          final toolReceipt = recordWorkWebToolReceipt(
            service: service,
            tool: 'web.read',
            arguments: invocation.arguments,
            result: result,
            onEvidenceChanged: onEvidenceChanged,
          );
          if (invocation.context.isCancelled) {
            return const WorkToolResult.paused(message: '来源读取已停止。');
          }
          return WorkToolResult.success(
            message: '已读取来源正文。',
            data: {...result, 'toolReceipt': toolReceipt},
          );
        },
      ),
    ];

Future<WorkspaceResolvedPath> resolveWorkDownloadDirectory(
    WorkspacePathPolicy policy, String workspaceRoot) async {
  final workspace = await policy.resolveExisting(workspaceRoot);
  final target = await policy.resolve(p.join(workspaceRoot, 'downloads'));
  final grants = policy.grantService;
  final writable = grants == null
      ? policy.isPathWritable(target.requestedPath)
      : await grants.isPathWritableResolved(target.path);
  if (!p.isWithin(workspace.path, target.path)) {
    throw WorkspacePathException(
        WorkspacePathErrorKind.symlinkEscape, '下载目录越过任务工作区。',
        path: target.path);
  }
  if (!writable) {
    throw WorkspacePathException(
        WorkspacePathErrorKind.notAuthorized, '下载目录不属于可写任务工作区。',
        path: target.path);
  }
  return target;
}

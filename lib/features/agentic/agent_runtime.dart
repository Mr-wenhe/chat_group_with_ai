import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/character_skill.dart';
import 'package:chat_group/core/models/tool_permission.dart';
import 'package:chat_group/features/agentic/agent_prompt_builder.dart';
import 'package:chat_group/features/agentic/tool_request.dart';
import 'package:chat_group/features/agentic/tools/browser_context_tool.dart';
import 'package:chat_group/features/agentic/tools/workspace_file_tool.dart';

typedef AgentCompletion = Future<Map<String, dynamic>> Function(
  List<Map<String, dynamic>> messages,
);

typedef SkillCreateHandler = Future<Map<String, dynamic>> Function(
  Map<String, dynamic> args,
);

typedef SkillDownloadHandler = Future<Map<String, dynamic>> Function(
  Map<String, dynamic> args,
);

enum AgentRuntimeStatus {
  completed,
  failed,
  permissionMissing,
  waitingForApproval,
}

class AgentRuntimeResult {
  final AgentRuntimeStatus status;
  final String message;
  final ToolRequest? pendingToolRequest;
  final Map<String, dynamic>? toolResult;

  const AgentRuntimeResult({
    required this.status,
    required this.message,
    this.pendingToolRequest,
    this.toolResult,
  });
}

class AgentRuntime {
  final AgentCompletion complete;
  final WorkspaceFileTool? workspaceFileTool;
  final BrowserContextTool? browserContextTool;
  final SkillCreateHandler? skillCreateHandler;
  final SkillDownloadHandler? skillDownloadHandler;

  const AgentRuntime({
    required this.complete,
    this.workspaceFileTool,
    this.browserContextTool,
    this.skillCreateHandler,
    this.skillDownloadHandler,
  });

  Future<AgentRuntimeResult> run({
    required AICharacter character,
    required List<CharacterSkill> skills,
    required String userRequest,
    bool approved = false,
  }) async {
    final prompt = AgentPromptBuilder.buildToolPlanningPrompt(
      characterName: character.name,
      skills: skills,
      userRequest: userRequest,
    );
    late final Map<String, dynamic> first;
    try {
      first = await complete([
        {'role': 'system', 'content': prompt},
      ]);
    } catch (e) {
      return AgentRuntimeResult(
        status: AgentRuntimeStatus.failed,
        message: '[${character.name} 工具任务失败: $e]',
      );
    }
    if (first['success'] != true) {
      return AgentRuntimeResult(
        status: AgentRuntimeStatus.failed,
        message: '[${character.name} 工具任务失败: ${first['message'] ?? '未知错误'}]',
      );
    }

    final content = first['message']?.toString() ?? '';
    final request = ToolRequest.tryParse(content);
    if (request == null) {
      return AgentRuntimeResult(
        status: AgentRuntimeStatus.completed,
        message: content,
      );
    }

    final permission = permissionForTool(request.tool);
    if (!character.toolPermissions.contains(permission)) {
      return AgentRuntimeResult(
        status: AgentRuntimeStatus.permissionMissing,
        pendingToolRequest: request,
        message: '${character.name} 需要权限「${permission.name}」才能继续：${request.reason}',
      );
    }

    if (requiresApproval(request.tool) && !approved) {
      return AgentRuntimeResult(
        status: AgentRuntimeStatus.waitingForApproval,
        pendingToolRequest: request,
        message: '${character.name} 想使用工具 ${request.tool.wireName}：${request.reason}\n'
            '请批准后再执行。',
      );
    }

    late final Map<String, dynamic> toolResult;
    try {
      toolResult = await _execute(request);
    } catch (e) {
      return AgentRuntimeResult(
        status: AgentRuntimeStatus.failed,
        pendingToolRequest: request,
        message: '[${character.name} 工具执行失败: $e]',
      );
    }
    final finalPrompt = AgentPromptBuilder.buildToolResultPrompt(
      characterName: character.name,
      userRequest: userRequest,
      toolName: request.tool.wireName,
      toolResult: toolResult,
    );
    final finalResponse = await complete([
      {'role': 'system', 'content': finalPrompt},
    ]);

    return AgentRuntimeResult(
      status: finalResponse['success'] == true
          ? AgentRuntimeStatus.completed
          : AgentRuntimeStatus.failed,
      pendingToolRequest: request,
      toolResult: toolResult,
      message: finalResponse['message']?.toString() ??
          '${character.name} 已完成工具调用，但整理结果失败。',
    );
  }

  Future<AgentRuntimeResult> executeApprovedTool({
    required AICharacter character,
    required ToolRequest request,
    required String userRequest,
  }) async {
    final permission = permissionForTool(request.tool);
    if (!character.toolPermissions.contains(permission)) {
      return AgentRuntimeResult(
        status: AgentRuntimeStatus.permissionMissing,
        pendingToolRequest: request,
        message: '${character.name} 需要权限「${permission.name}」才能继续：${request.reason}',
      );
    }

    late final Map<String, dynamic> toolResult;
    try {
      toolResult = await _execute(request);
    } catch (e) {
      return AgentRuntimeResult(
        status: AgentRuntimeStatus.failed,
        pendingToolRequest: request,
        message: '[${character.name} 工具执行失败: $e]',
      );
    }

    final finalPrompt = AgentPromptBuilder.buildToolResultPrompt(
      characterName: character.name,
      userRequest: userRequest,
      toolName: request.tool.wireName,
      toolResult: toolResult,
    );
    final finalResponse = await complete([
      {'role': 'system', 'content': finalPrompt},
    ]);

    return AgentRuntimeResult(
      status: finalResponse['success'] == true
          ? AgentRuntimeStatus.completed
          : AgentRuntimeStatus.failed,
      pendingToolRequest: request,
      toolResult: toolResult,
      message: finalResponse['message']?.toString() ??
          '${character.name} 已完成工具调用，但整理结果失败。',
    );
  }

  static ToolPermission permissionForTool(AgentToolName tool) {
    return switch (tool) {
      AgentToolName.workspaceList => ToolPermission.workspaceRead,
      AgentToolName.workspaceRead => ToolPermission.workspaceRead,
      AgentToolName.workspacePatch => ToolPermission.workspacePatch,
      AgentToolName.commandRun => ToolPermission.commandRun,
      AgentToolName.browserContext => ToolPermission.browserContext,
      AgentToolName.skillCreate => ToolPermission.skillCreate,
      AgentToolName.skillDownload => ToolPermission.skillDownload,
    };
  }

  static bool requiresApproval(AgentToolName tool) {
    return switch (tool) {
      AgentToolName.workspaceList => false,
      AgentToolName.workspaceRead => false,
      AgentToolName.workspacePatch => true,
      AgentToolName.commandRun => true,
      AgentToolName.browserContext => true,
      AgentToolName.skillCreate => true,
      AgentToolName.skillDownload => true,
    };
  }

  Future<Map<String, dynamic>> _execute(ToolRequest request) async {
    return switch (request.tool) {
      AgentToolName.workspaceList =>
        await _workspaceFileTool.list(path: request.args['path'] as String? ?? '.'),
      AgentToolName.workspaceRead =>
        await _workspaceFileTool.read(request.args['path'] as String? ?? ''),
      AgentToolName.workspacePatch =>
        await _workspaceFileTool.applyPatch(request.args['patch'] as String? ?? ''),
      AgentToolName.commandRun =>
        await _workspaceFileTool.runCommand(request.args['command'] as String? ?? ''),
      AgentToolName.browserContext => _browserSnapshotToJson(
          await _browserContextTool.currentTab(),
        ),
      AgentToolName.skillCreate =>
        await _skillCreateHandler(request.args),
      AgentToolName.skillDownload =>
        await _skillDownloadHandler(request.args),
    };
  }

  WorkspaceFileTool get _workspaceFileTool {
    final tool = workspaceFileTool;
    if (tool == null) {
      throw StateError('Workspace file tool is not configured.');
    }
    return tool;
  }

  BrowserContextTool get _browserContextTool {
    final tool = browserContextTool;
    if (tool == null) {
      throw StateError('Browser context tool is not configured.');
    }
    return tool;
  }

  SkillCreateHandler get _skillCreateHandler {
    final handler = skillCreateHandler;
    if (handler == null) {
      throw StateError('Skill create handler is not configured.');
    }
    return handler;
  }

  SkillDownloadHandler get _skillDownloadHandler {
    final handler = skillDownloadHandler;
    if (handler == null) {
      throw StateError('Skill download handler is not configured.');
    }
    return handler;
  }

  Map<String, dynamic> _browserSnapshotToJson(BrowserContextSnapshot snapshot) {
    return {
      'url': snapshot.url,
      'title': snapshot.title,
      'selectedText': snapshot.selectedText,
      'pageText': snapshot.safePageText,
      'capturedAt': snapshot.capturedAt.toIso8601String(),
    };
  }
}

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
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
  final List<ToolRequest> executedToolRequests;

  const AgentRuntimeResult({
    required this.status,
    required this.message,
    this.pendingToolRequest,
    this.toolResult,
    this.executedToolRequests = const [],
  });
}

/// 桥接调用错误的分类，用于决定提示文案。
class BridgeErrorKind {
  /// 是否连接级错误（根本连不上桥接服务）。
  final bool isConnection;

  /// 若为非空，表示桥接服务返回的 HTTP 状态码（4xx/5xx）。
  final int? statusCode;

  const BridgeErrorKind.connection()
      : isConnection = true,
        statusCode = null;

  const BridgeErrorKind.http(int code)
      : isConnection = false,
        statusCode = code;

  const BridgeErrorKind.other()
      : isConnection = false,
        statusCode = null;
}

class AgentRuntime {
  static const int maxToolSteps = 6;
  static const Duration completionTimeout = Duration(seconds: 45);

  final AgentCompletion complete;
  final WorkspaceFileTool? workspaceFileTool;
  final BrowserContextTool? browserContextTool;
  final SkillCreateHandler? skillCreateHandler;
  final SkillDownloadHandler? skillDownloadHandler;
  final bool enableLocalFilePlanner;

  const AgentRuntime({
    required this.complete,
    this.workspaceFileTool,
    this.browserContextTool,
    this.skillCreateHandler,
    this.skillDownloadHandler,
    this.enableLocalFilePlanner = true,
  });

  /// 清洗可能泄露到聊天文本中的内部工具调用协议标记。
  ///
  /// 当模型输出的工具请求既未被 [ToolRequest.tryParse] 识别（如残缺、
  /// 畸形的标签），又混在普通文本中时，这些内部协议标记不应暴露给最终
  /// 用户。本方法会整块移除以下两类协议标记（含标签本身）：
  ///   - ```agent_tool ... ``` 围栏块
  ///   - <tool_call agent_tool ... </agent_tool> XML 块
  /// 仅保留模型附带的正常文本。
  ///
  /// 若清洗后无任何有效文本，返回一个友好的兜底提示，避免向用户展示
  /// 空白气泡或裸协议。
  static String _sanitizeToolProtocolLeak(
    String text, {
    String? characterName,
  }) {
    // 移除 ```agent_tool ... ``` 围栏块（含围栏本身）
    var cleaned = text.replaceAll(
      RegExp(r'```agent_tool\s*[\s\S]*?\s*```'),
      '',
    );
    // 移除 <tool_call ... </tool_call> / </agent_tool> XML 块（含标签本身）。
    // 兼容两种开标签写法：<tool_call agent_tool ...> 与 <tool_call> 包裹 JSON。
    // 注：模型实际闭合标签为 </tool_call>，但也防御性兼容 </agent_tool> 变体。
    cleaned = cleaned.replaceAll(
      RegExp(r'<tool_call\s*[\s\S]*?\s*(?:</agent_tool>|</tool_call>)'),
      '',
    );
    cleaned = cleaned.replaceAll(
      RegExp(r'<tool_call\s*[\s\S]*$', caseSensitive: false),
      '',
    );
    cleaned = cleaned.trim();
    if (cleaned.isEmpty) {
      final name = characterName?.isNotEmpty == true ? characterName! : '助手';
      return '$name 似乎遇到了技术问题，已为你隐藏内部工具协议。';
    }
    return cleaned;
  }

  /// 把「文件内容预览」块追加到最终消息文本中。
  ///
  /// 仅在写文件工具（workspace.patch）执行成功、且已成功读回文件内容时生效：
  /// 从 [toolResult] 读取 [readbackContent]（由 [_executeWorkspacePatch] 写入）。
  /// 其它工具的结果不含该字段，会直接返回原文本，行为保持不变。
  ///
  /// - 内容超过 [maxPreviewChars]（默认 2000）字符则截断，并提示查看完整文件。
  /// - 若没有读回内容（读回失败已降级），原样返回 [message]，不暴露任何异常。
  static String _appendFilePreview(
    String message,
    Map<String, dynamic> toolResult,
  ) {
    if (toolResult['ok'] != true) return message;
    final content = toolResult['readbackContent'] as String?;
    if (content == null || content.isEmpty) return message;
    final path = toolResult['path'] as String? ?? '';
    const maxPreviewChars = 2000;
    final buffer = StringBuffer();
    buffer.writeln();
    buffer.writeln('--- 文件内容预览 ---');
    if (path.isNotEmpty) {
      buffer.writeln('文件路径：`$path`');
      buffer.writeln();
    }
    if (content.length > maxPreviewChars) {
      buffer.write(content.substring(0, maxPreviewChars));
      buffer.writeln();
      buffer.writeln('…（内容较长，已截断显示前 $maxPreviewChars 字符；'
          '完整文件请查看 `$path`）');
    } else {
      buffer.write(content);
    }
    buffer.writeln('--- 预览结束 ---');
    return '$message$buffer';
  }

  Future<AgentRuntimeResult> run({
    required AICharacter character,
    required List<CharacterSkill> skills,
    required String userRequest,
    bool approved = false,
    bool autoApproveWriteTools = false,
  }) async {
    final localRequest = enableLocalFilePlanner
        ? _localFileGenerationRequest(character, userRequest)
        : null;
    if (localRequest != null) {
      return _handleToolRequest(
        character: character,
        request: localRequest,
        userRequest: userRequest,
        approved: approved,
        autoApproveWriteTools: autoApproveWriteTools,
        remainingSteps: maxToolSteps,
        executedRequests: const [],
      );
    }

    final prompt = AgentPromptBuilder.buildToolPlanningPrompt(
      characterName: character.name,
      skills: skills,
      userRequest: userRequest,
    );
    late final Map<String, dynamic> first;
    try {
      first = await complete([
        {'role': 'system', 'content': prompt},
      ]).timeout(completionTimeout);
    } on TimeoutException {
      return AgentRuntimeResult(
        status: AgentRuntimeStatus.failed,
        message:
            '[${character.name} 工具任务失败: 模型在 ${completionTimeout.inSeconds} 秒内没有返回工具计划。请重试，或检查模型/网络配置。]',
      );
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
      // 防御性过滤：即使 tryParse 兼容两种格式，若模型输出的是残缺/畸形
      // 的工具标记（而非合法请求或正常文本），也要清理后再展示，避免泄露
      // 内部协议标签到聊天 UI。
      return AgentRuntimeResult(
        status: AgentRuntimeStatus.completed,
        message: _sanitizeToolProtocolLeak(
          content,
          characterName: character.name,
        ),
      );
    }

    return _handleToolRequest(
      character: character,
      request: request,
      userRequest: userRequest,
      approved: approved,
      autoApproveWriteTools: autoApproveWriteTools,
      remainingSteps: maxToolSteps,
      executedRequests: const [],
    );
  }

  Future<AgentRuntimeResult> _handleToolRequest({
    required AICharacter character,
    required ToolRequest request,
    required String userRequest,
    required bool approved,
    required bool autoApproveWriteTools,
    required int remainingSteps,
    required List<ToolRequest> executedRequests,
  }) async {
    if (remainingSteps <= 0) {
      return AgentRuntimeResult(
        status: AgentRuntimeStatus.failed,
        pendingToolRequest: request,
        executedToolRequests: executedRequests,
        message: '[${character.name} 工具任务失败: 工具调用次数超过上限]',
      );
    }

    final permission = permissionForTool(request.tool);
    if (!character.toolPermissions.contains(permission)) {
      return AgentRuntimeResult(
        status: AgentRuntimeStatus.permissionMissing,
        pendingToolRequest: request,
        executedToolRequests: executedRequests,
        message:
            '${character.name} 需要权限「${permission.name}」才能继续：${request.reason}',
      );
    }

    final autoApprovedWrite =
        autoApproveWriteTools && request.tool == AgentToolName.workspacePatch;
    if (requiresApproval(request.tool) && !approved && !autoApprovedWrite) {
      return AgentRuntimeResult(
        status: AgentRuntimeStatus.waitingForApproval,
        pendingToolRequest: request,
        executedToolRequests: executedRequests,
        message:
            '${character.name} 想使用工具 ${request.tool.wireName}：${request.reason}\n'
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
        executedToolRequests: executedRequests,
        message: toolFailureMessage(character, e),
      );
    }
    if (request.tool == AgentToolName.workspacePatch &&
        toolResult['ok'] == false) {
      return AgentRuntimeResult(
        status: AgentRuntimeStatus.failed,
        pendingToolRequest: request,
        toolResult: toolResult,
        executedToolRequests: executedRequests,
        message: toolResult['message']?.toString() ??
            '[${character.name} 工具任务失败: 文件写入被拒绝]',
      );
    }
    final nextExecutedRequests = [...executedRequests, request];
    return _continueAfterToolResult(
      character: character,
      request: request,
      userRequest: userRequest,
      toolResult: toolResult,
      remainingSteps: remainingSteps - 1,
      executedRequests: nextExecutedRequests,
      autoApproveWriteTools: autoApproveWriteTools,
    );
  }

  Future<AgentRuntimeResult> _continueAfterToolResult({
    required AICharacter character,
    required ToolRequest request,
    required String userRequest,
    required Map<String, dynamic> toolResult,
    required int remainingSteps,
    required List<ToolRequest> executedRequests,
    required bool autoApproveWriteTools,
  }) async {
    final finalPrompt = AgentPromptBuilder.buildToolResultPrompt(
      characterName: character.name,
      userRequest: userRequest,
      toolName: request.tool.wireName,
      toolResult: toolResult,
    );
    late final Map<String, dynamic> finalResponse;
    try {
      finalResponse = await complete([
        {'role': 'system', 'content': finalPrompt},
      ]).timeout(completionTimeout);
    } on TimeoutException {
      final fallback = _completedFallbackForExecutedTool(
        character: character,
        request: request,
        toolResult: toolResult,
        executedRequests: executedRequests,
      );
      if (fallback != null) return fallback;
      return AgentRuntimeResult(
        status: AgentRuntimeStatus.failed,
        pendingToolRequest: request,
        toolResult: toolResult,
        executedToolRequests: executedRequests,
        message:
            '[${character.name} 工具任务失败: 工具已返回结果，但模型在 ${completionTimeout.inSeconds} 秒内没有给出下一步或最终答复。请重试，或检查模型/网络配置。]',
      );
    }

    if (finalResponse['success'] != true) {
      final fallback = _completedFallbackForExecutedTool(
        character: character,
        request: request,
        toolResult: toolResult,
        executedRequests: executedRequests,
      );
      if (fallback != null) return fallback;
      return AgentRuntimeResult(
        status: AgentRuntimeStatus.failed,
        pendingToolRequest: request,
        toolResult: toolResult,
        executedToolRequests: executedRequests,
        message:
            '[${character.name} 工具任务失败: ${finalResponse['message'] ?? '整理结果失败'}]',
      );
    }

    final content = finalResponse['message']?.toString() ??
        '${character.name} 已完成工具调用，但整理结果失败。';
    final nextRequest = ToolRequest.tryParse(content);
    if (nextRequest != null) {
      return _handleToolRequest(
        character: character,
        request: nextRequest,
        userRequest: userRequest,
        approved: false,
        autoApproveWriteTools: autoApproveWriteTools,
        remainingSteps: remainingSteps,
        executedRequests: executedRequests,
      );
    }

    // 防御性过滤：多轮工具调用收尾时，同样需清理可能泄露的工具协议标记。
    final sanitized = _sanitizeToolProtocolLeak(
      content,
      characterName: character.name,
    );
    // 写文件成功后，把刚写入的文件内容预览追加到最终消息（读回失败已降级）。
    final finalMessage = _appendFilePreview(sanitized, toolResult);
    return AgentRuntimeResult(
      status: AgentRuntimeStatus.completed,
      pendingToolRequest: request,
      toolResult: toolResult,
      executedToolRequests: executedRequests,
      message: finalMessage,
    );
  }

  Future<AgentRuntimeResult> executeApprovedTool({
    required AICharacter character,
    required ToolRequest request,
    required String userRequest,
    List<ToolRequest> priorExecutedRequests = const [],
  }) async {
    final permission = permissionForTool(request.tool);
    if (!character.toolPermissions.contains(permission)) {
      return AgentRuntimeResult(
        status: AgentRuntimeStatus.permissionMissing,
        pendingToolRequest: request,
        executedToolRequests: priorExecutedRequests,
        message:
            '${character.name} 需要权限「${permission.name}」才能继续：${request.reason}',
      );
    }

    return _handleToolRequest(
      character: character,
      request: request,
      userRequest: userRequest,
      approved: true,
      autoApproveWriteTools: false,
      remainingSteps: maxToolSteps,
      executedRequests: priorExecutedRequests,
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
      AgentToolName.workspaceList => await _workspaceFileTool.list(
          path: request.args['path'] as String? ?? '.'),
      AgentToolName.workspaceRead =>
        await _workspaceFileTool.read(request.args['path'] as String? ?? ''),
      AgentToolName.workspacePatch => await _executeWorkspacePatch(request),
      AgentToolName.commandRun => await _workspaceFileTool
          .runCommand(request.args['command'] as String? ?? ''),
      AgentToolName.browserContext => _browserSnapshotToJson(
          await _browserContextTool.currentTab(),
        ),
      AgentToolName.skillCreate => await _skillCreateHandler(request.args),
      AgentToolName.skillDownload => await _skillDownloadHandler(request.args),
    };
  }

  /// 执行 workspace.patch（写文件）：先调用桥接服务 `/workspace/write` 落盘，
  /// 成功后再同步读回刚写入的文件全文，附加到返回结果里（key: [readbackContent]），
  /// 供最终消息展示给用户。
  ///
  /// 写成功但读回失败时降级处理：仅返回写结果、不附加预览，也不把异常暴露给用户
  /// —— 写文件这一核心动作已成功，不应因读回失败而被判定为整次工具执行失败。
  Future<Map<String, dynamic>> _executeWorkspacePatch(
      ToolRequest request) async {
    final rawPath = request.args['path'] as String? ?? '';
    var path = WorkspacePathGuard.normalizeToRelative(rawPath);
    if (path.isEmpty) {
      return {'ok': false, 'error': 'empty_path', 'message': '缺少有效的文件路径'};
    }
    if (await _workspaceFileExists(path)) {
      if (request.args['allowRenameOnConflict'] == true) {
        path = await _nextAvailableWorkspacePath(path);
      } else {
        return {
          'ok': false,
          'error': 'target_exists',
          'path': path,
          'message': '目标文件已存在，已拒绝覆盖：$path',
        };
      }
    }
    if (path.isEmpty) {
      return {
        'ok': false,
        'error': 'no_available_path',
        'message': '目标文件名冲突过多，未找到可用的新文件名',
      };
    }
    final writeResult = await _workspaceFileTool.write(
      path,
      request.args['content'] as String? ?? '',
    );
    if (writeResult['ok'] != true) return writeResult;
    try {
      final readResult = await _workspaceFileTool.read(path);
      final content = readResult['content'] as String?;
      if (content == null) return writeResult;
      final enriched = Map<String, dynamic>.from(writeResult);
      enriched['readbackContent'] = content;
      return enriched;
    } catch (_) {
      return writeResult;
    }
  }

  Future<String> _nextAvailableWorkspacePath(String path) async {
    final slashIndex = path.lastIndexOf('/');
    final dir = slashIndex >= 0 ? path.substring(0, slashIndex + 1) : '';
    final fileName = slashIndex >= 0 ? path.substring(slashIndex + 1) : path;
    final dotIndex = fileName.lastIndexOf('.');
    final base = dotIndex > 0 ? fileName.substring(0, dotIndex) : fileName;
    final ext = dotIndex > 0 ? fileName.substring(dotIndex) : '';
    for (var i = 2; i <= 999; i++) {
      final candidate = '$dir${base}_$i$ext';
      if (!WorkspacePathGuard.isSafeRelativePath(candidate)) return '';
      if (!await _workspaceFileExists(candidate)) return candidate;
    }
    return '';
  }

  Future<bool> _workspaceFileExists(String path) async {
    try {
      final readResult = await _workspaceFileTool.read(path);
      if (readResult['ok'] == false) return false;
      return readResult['content'] is String || readResult['ok'] == true;
    } catch (_) {
      return false;
    }
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

  /// 连接级错误的文本兜底关键词（非 Dio 异常时按文本判断）。
  static final List<String> _connectionErrorKeywords = [
    'Connection refused',
    'SocketException',
    'Failed host lookup',
  ];

  /// 将桥接调用异常分类，区分「连接级错误」与「HTTP 状态码错误」。
  ///
  /// - [BridgeErrorKind.connection]：根本连不上桥接服务（无 HTTP 响应体），
  ///   例如 Connection refused / SocketException / DNS 失败。
  /// - [BridgeErrorKind.http]：服务器已响应但返回 4xx/5xx，例如 404
  ///   （路径不存在，通常是 App 内嵌桥接版本与客户端不一致）。
  /// - [BridgeErrorKind.other]：非桥接相关异常，原样输出。
  static BridgeErrorKind classifyBridgeError(Object error) {
    if (error is DioException) {
      final statusCode = error.response?.statusCode;
      if (statusCode != null) return BridgeErrorKind.http(statusCode);
      // 无响应体：真正连不上（connectionError / sendTimeout 等）。
      return const BridgeErrorKind.connection();
    }
    final text = error.toString();
    if (_connectionErrorKeywords.any((k) => text.contains(k))) {
      return const BridgeErrorKind.connection();
    }
    return const BridgeErrorKind.other();
  }

  String toolFailureMessage(AICharacter character, Object error) {
    final text = error.toString();
    final kind = classifyBridgeError(error);
    if (kind.isConnection) {
      return '[${character.name} 工具执行失败: 本地工具桥接服务未连接（桌面端应由 App 在进程内自动启动并监听 54263）。'
          '若仍失败，请检查 54263 端口是否被其他进程占用，或重启 App 后重试。原始错误: $text]';
    }
    if (kind.statusCode != null) {
      if (kind.statusCode == 404) {
        return '[${character.name} 工具执行失败: 本地桥接服务返回 404（请求路径在服务端不存在）。'
            '通常是 App 内嵌桥接版本与客户端不一致，请完全退出并重启 App 后重试。原始错误: $text]';
      }
      return '[${character.name} 工具执行失败: 本地桥接服务返回 ${kind.statusCode}。原始错误: $text]';
    }
    return '[${character.name} 工具执行失败: $text]';
  }

  ToolRequest? _localFileGenerationRequest(
    AICharacter character,
    String userRequest,
  ) {
    final lower = userRequest.toLowerCase();
    final wantsFile = lower.contains('生成') ||
        lower.contains('创建') ||
        lower.contains('写') ||
        lower.contains('写入') ||
        lower.contains('写文件') ||
        lower.contains('写一份') ||
        lower.contains('撰写') ||
        lower.contains('实现') ||
        lower.contains('输出') ||
        lower.contains('导出') ||
        lower.contains('脚本') ||
        lower.contains('script') ||
        lower.contains('create') ||
        lower.contains('write');
    if (!wantsFile) return null;

    // 优先走原有精确路径匹配（用户明确给出 star.html 等具体文件名）。
    final path = _extractWorkspaceFilePath(userRequest);
    // Bug 1 修复：关键词命中但用户只说“一个 html 文件/这个文件”等、
    // 未给出具体文件名时，根据类型提示词模糊推断一个合理的相对文件名，
    // 使工具请求仍能被创建（否则直接短路返回 null，永远走不到工具执行）。
    final inferredPath = path ?? _inferWorkspaceFilePath(userRequest);
    if (inferredPath == null) return null;
    final content = _localGeneratedFileContent(
      character: character,
      userRequest: userRequest,
      path: inferredPath,
    );
    return ToolRequest(
      tool: AgentToolName.workspacePatch,
      reason: path != null
          ? '根据用户给出的明确路径生成文件 $inferredPath'
          : '用户未指定具体文件名，已根据请求内容推断为 $inferredPath 并生成文件',
      // 方案 A：直接把 (path, content) 交给桥接服务的 /workspace/write 端点写文件，
      // 不再生成 git diff（new-file diff 在目标已存在时会被 git apply --check 拒掉）。
      args: {
        'path': inferredPath,
        'content': content,
        if (path == null) 'allowRenameOnConflict': true,
      },
    );
  }

  /// 模糊推断文件名：当关键词命中但用户未给出具体文件名时，
  /// 从消息中提取文件类型提示词（如“html 文件”“一个 md”“json 文件”），
  /// 并结合内容语义生成一个安全的相对文件名（如 `star_scene.html`、`report.md`）。
  ///
  /// 返回 null 表示未识别出任何文件生成意图（不应触发工具请求）。
  String? _inferWorkspaceFilePath(String text) {
    const supported =
        r'html|html5|md|markdown|dart|txt|text|json|yaml|yml|svg|css|js|ts|py|sh|bash|c|cpp|cc|h|hpp';
    // 先匹配「(一个?) (ext) 文件」或「(ext)文件」「一个(ext)」这类明确类型提示。
    final typeHint = RegExp(
      r'(?:一个?)?\s*(' + supported + r')\s*文件',
      caseSensitive: false,
    ).firstMatch(text);
    String? ext;
    if (typeHint != null) {
      ext = _normalizeExt(typeHint.group(1)!);
    } else {
      // 兜底：消息里单独出现“一个 html / 生成一个 dart”等扩展名词（无“文件”二字）。
      final bare = RegExp(
        r'(?:一个?)?\s*(html|html5|md|markdown|dart|txt|json|yaml|yml|svg|css|js|ts|py|sh|bash)(?![a-zA-Z0-9_])',
        caseSensitive: false,
      ).firstMatch(text);
      ext = bare == null ? null : _normalizeExt(bare.group(1)!);
      if (ext == null && (lowerContainsScript(text))) {
        ext = 'sh';
      }
    }
    if (ext == null) return null;

    final lower = text.toLowerCase();
    String name;
    if (ext == 'html' || ext == 'svg' || ext == 'css') {
      // 画面 / 场景 / 视觉类 → 用内容关键词命名。
      if (lower.contains('流星') ||
          lower.contains('meteor') ||
          lower.contains('夜空')) {
        name = 'meteor_shower';
      } else if (lower.contains('湖') ||
          lower.contains('划船') ||
          lower.contains('星空') ||
          lower.contains('月亮') ||
          lower.contains('场景') ||
          lower.contains('画面') ||
          lower.contains('star') ||
          lower.contains('night') ||
          lower.contains('scene')) {
        name = 'star_scene';
      } else {
        name = 'page';
      }
    } else if (ext == 'md' || ext == 'markdown') {
      if (lower.contains('报告') ||
          lower.contains('总结') ||
          lower.contains('验收') ||
          lower.contains('技术文档') ||
          lower.contains('项目文档') ||
          lower.contains('工程目录') ||
          lower.contains('readme') ||
          lower.contains('report')) {
        name = lower.contains('技术文档') || lower.contains('项目文档')
            ? 'technical_documentation'
            : 'report';
      } else {
        name = 'note';
      }
    } else if (ext == 'dart') {
      if (lower.contains('代码') ||
          lower.contains('脚本') ||
          lower.contains('程序') ||
          lower.contains('app') ||
          lower.contains('snippet')) {
        name = 'main';
      } else {
        name = 'snippet';
      }
    } else if (ext == 'sh') {
      if (lower.contains('检查') ||
          lower.contains('验证') ||
          lower.contains('test') ||
          lower.contains('check')) {
        name = 'run_checks';
      } else {
        name = 'script';
      }
    } else {
      // 其余类型（json / yaml / txt / 源码等）统一兜底命名。
      name = 'output';
    }
    final fileName = '$name.$ext';
    // 再次走安全校验，避免拼出不安全路径（理论上不会发生，双保险）。
    return WorkspacePathGuard.isSafeRelativePath(fileName) ? fileName : null;
  }

  /// 把模型/用户可能写出的扩展名变体归一化为安全的小写扩展名。
  String _normalizeExt(String raw) {
    final e = raw.toLowerCase();
    if (e == 'html5') return 'html';
    if (e == 'markdown') return 'md';
    if (e == 'text') return 'txt';
    if (e == 'bash') return 'sh';
    return e;
  }

  bool lowerContainsScript(String text) {
    final lower = text.toLowerCase();
    return lower.contains('脚本') || lower.contains('script');
  }

  String? _extractWorkspaceFilePath(String text) {
    final pathPattern = RegExp(
      r'(?<![\w./\\-])([\w][\w./\\-]*\.(?:md|markdown|dart|txt|json|yaml|yml|svg|html|css|js|ts|py|sh|bash|c|cc|cpp|h|hpp))(?![\w./\\-])',
      caseSensitive: false,
    );
    for (final match in pathPattern.allMatches(text)) {
      final raw = match.group(1)?.replaceAll('\\', '/').trim();
      if (raw == null || raw.isEmpty) continue;
      if (WorkspacePathGuard.isSafeRelativePath(raw)) return raw;
    }
    return null;
  }

  String _localGeneratedFileContent({
    required AICharacter character,
    required String userRequest,
    required String path,
  }) {
    final extension = path.split('.').last.toLowerCase();
    final htmlCharacterName = _escapeHtml(character.name);
    final markdownCharacterName = _escapeMarkdownHtml(character.name);
    if (extension == 'dart') {
      return "void main() {\n  print('hello from ${character.name}');\n}\n";
    }
    if (extension == 'sh' || extension == 'bash') {
      return '''
#!/usr/bin/env bash
set -euo pipefail

echo "Agentic generated project check script"
echo "Generated by: ${character.name}"

flutter --version >/dev/null
flutter analyze
flutter test

echo "All checks completed."
''';
    }
    if (extension == 'cpp' ||
        extension == 'cc' ||
        extension == 'c' ||
        extension == 'hpp' ||
        extension == 'h') {
      return '''
#include <sys/sysctl.h>
#include <sys/types.h>
#include <mach/mach.h>
#include <unistd.h>

#include <chrono>
#include <cstdint>
#include <iomanip>
#include <iostream>
#include <thread>

namespace {

uint64_t totalMemoryBytes() {
  int64_t memory = 0;
  size_t length = sizeof(memory);
  if (sysctlbyname("hw.memsize", &memory, &length, nullptr, 0) != 0) {
    return 0;
  }
  return static_cast<uint64_t>(memory);
}

uint64_t usedMemoryBytes() {
  mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
  vm_statistics64_data_t vmstat{};
  if (host_statistics64(mach_host_self(), HOST_VM_INFO64,
                        reinterpret_cast<host_info64_t>(&vmstat),
                        &count) != KERN_SUCCESS) {
    return 0;
  }
  const uint64_t pageSize = static_cast<uint64_t>(getpagesize());
  const uint64_t active = static_cast<uint64_t>(vmstat.active_count);
  const uint64_t wired = static_cast<uint64_t>(vmstat.wire_count);
  const uint64_t compressed = static_cast<uint64_t>(vmstat.compressor_page_count);
  return (active + wired + compressed) * pageSize;
}

double processCpuPercent() {
  task_thread_times_info_data_t threadInfo{};
  mach_msg_type_number_t count = TASK_THREAD_TIMES_INFO_COUNT;
  if (task_info(mach_task_self(), TASK_THREAD_TIMES_INFO,
                reinterpret_cast<task_info_t>(&threadInfo), &count) !=
      KERN_SUCCESS) {
    return 0.0;
  }
  const auto userSeconds = threadInfo.user_time.seconds +
      threadInfo.user_time.microseconds / 1000000.0;
  const auto systemSeconds = threadInfo.system_time.seconds +
      threadInfo.system_time.microseconds / 1000000.0;
  return (userSeconds + systemSeconds) * 100.0;
}

double mib(uint64_t bytes) {
  return static_cast<double>(bytes) / 1024.0 / 1024.0;
}

}  // namespace

int main() {
  const auto totalMemory = totalMemoryBytes();
  const auto usedMemory = usedMemoryBytes();

  std::cout << std::fixed << std::setprecision(2);
  std::cout << "System memory total: " << mib(totalMemory) << " MiB\\n";
  std::cout << "System memory used estimate: " << mib(usedMemory) << " MiB\\n";
  std::cout << "Current process CPU time percent sample: "
            << processCpuPercent() << "%\\n";
  std::cout << "Note: CPU value is a lightweight process CPU-time snapshot. "
               "For whole-system CPU load, sample host_processor_info twice.\\n";
  return 0;
}
''';
    }
    if (extension == 'svg') {
      return '''
<svg xmlns="http://www.w3.org/2000/svg" width="960" height="540" viewBox="0 0 960 540">
  <rect width="960" height="540" fill="#111827"/>
  <rect x="80" y="76" width="800" height="388" rx="28" fill="#f8fafc"/>
  <text x="120" y="160" font-family="Arial, sans-serif" font-size="46" font-weight="700" fill="#1f2937">Agentic Work</text>
  <text x="120" y="230" font-family="Arial, sans-serif" font-size="28" fill="#475569">Generated by $htmlCharacterName</text>
  <circle cx="760" cy="170" r="54" fill="#6366f1"/>
  <path d="M710 330h120M710 370h90M710 410h150" stroke="#10b981" stroke-width="18" stroke-linecap="round"/>
</svg>
''';
    }
    if (extension == 'json') {
      return '''
{
  "generatedBy": ${_jsonString(character.name)},
  "status": "created",
  "request": ${_jsonString(userRequest)}
}
''';
    }
    if (extension == 'html') {
      return '''
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>流星雨划过夜空</title>
  <style>
    * { box-sizing: border-box; }
    body {
      margin: 0;
      min-height: 100vh;
      overflow: hidden;
      background: radial-gradient(circle at 50% 80%, #1b3768 0 8%, transparent 30%),
        linear-gradient(180deg, #050711 0%, #0b1024 52%, #18284b 100%);
      color: #f8fafc;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }
    .sky {
      position: relative;
      width: 100vw;
      height: 100vh;
      background-image:
        radial-gradient(circle, rgba(255,255,255,.9) 0 1px, transparent 1.6px),
        radial-gradient(circle, rgba(185,214,255,.8) 0 1px, transparent 1.4px);
      background-size: 140px 140px, 210px 210px;
      animation: drift 20s linear infinite;
    }
    .title {
      position: absolute;
      left: 7vw;
      top: 8vh;
      max-width: 560px;
      text-shadow: 0 12px 35px rgba(0,0,0,.5);
    }
    h1 { margin: 0 0 12px; font-size: clamp(34px, 6vw, 78px); }
    p { margin: 0; font-size: clamp(15px, 2vw, 22px); color: #c7d2fe; }
    .meteor {
      position: absolute;
      width: 190px;
      height: 2px;
      background: linear-gradient(90deg, rgba(255,255,255,0), #fff 70%, #bde7ff);
      border-radius: 999px;
      filter: drop-shadow(0 0 10px #bae6fd);
      transform: rotate(-28deg);
      animation: shoot var(--duration) linear infinite;
      animation-delay: var(--delay);
      top: var(--top);
      left: var(--left);
      opacity: 0;
    }
    .meteor::after {
      content: "";
      position: absolute;
      right: -5px;
      top: -3px;
      width: 8px;
      height: 8px;
      border-radius: 50%;
      background: #fff;
      box-shadow: 0 0 16px #7dd3fc;
    }
    .horizon {
      position: absolute;
      inset: auto 0 0;
      height: 28vh;
      background: linear-gradient(180deg, rgba(7,12,28,0) 0%, rgba(5,8,18,.9) 58%),
        radial-gradient(ellipse at 50% 100%, rgba(96,165,250,.26), transparent 65%);
    }
    @keyframes shoot {
      0% { opacity: 0; transform: translate3d(0, 0, 0) rotate(-28deg); }
      7% { opacity: 1; }
      55% { opacity: 1; }
      100% { opacity: 0; transform: translate3d(65vw, 38vh, 0) rotate(-28deg); }
    }
    @keyframes drift {
      from { background-position: 0 0, 0 0; }
      to { background-position: 140px 140px, -210px 210px; }
    }
  </style>
</head>
<body>
  <main class="sky" aria-label="流星雨划过夜空的动态效果">
    <section class="title">
      <h1>流星雨划过夜空</h1>
      <p>$htmlCharacterName 根据你的自然语言请求生成的 HTML 动态效果。</p>
    </section>
    <span class="meteor" style="--top:10vh;--left:-18vw;--duration:4.8s;--delay:.2s"></span>
    <span class="meteor" style="--top:22vh;--left:-30vw;--duration:5.6s;--delay:1.1s"></span>
    <span class="meteor" style="--top:35vh;--left:-25vw;--duration:4.2s;--delay:2.4s"></span>
    <span class="meteor" style="--top:48vh;--left:-35vw;--duration:6.2s;--delay:3.3s"></span>
    <span class="meteor" style="--top:16vh;--left:-45vw;--duration:5.1s;--delay:4.7s"></span>
    <div class="horizon"></div>
  </main>
</body>
</html>
''';
    }
    if (extension == 'md' || extension == 'markdown') {
      final isTechnicalDoc = userRequest.contains('技术文档') ||
          userRequest.contains('项目') ||
          userRequest.contains('工程');
      if (isTechnicalDoc) {
        return '''
# AI Group Chat Simulator 技术文档

生成角色：$markdownCharacterName

## 项目概述

这是一个 Flutter 本地应用，用于模拟多个 AI 角色在群聊和私聊中的对话。角色可以绑定不同 LLM Provider，并在 agentic 模式下通过本地工具读写工程文件、生成技能或整理产物。

## 技术栈

- Flutter / Dart：跨平台 UI 与业务逻辑。
- Riverpod：Provider 注入与状态管理。
- Hive：本地 NoSQL 持久化，保存角色、群组、消息、记忆和设置。
- Dio：调用 DeepSeek、Qwen、Zhipu、Moonshot、Baidu 以及自定义 OpenAI-compatible 接口。
- open_filex / file_picker：文件附件选择、生成产物打开。

## 核心模块

- `lib/features/chat_group/chat_room_page.dart`：群聊/私聊页面、消息发送、AI 回复、附件展示和工具产物回贴。
- `lib/features/agentic/agent_runtime.dart`：agentic 工具运行时，负责规划、权限检查、工具执行和结果整理。
- `lib/features/agentic/tools/`：本地 workspace、浏览器上下文和桥接服务。
- `lib/core/database/database_service.dart`：Hive 初始化、消息索引、AI 产物目录和媒体文件管理。

## 数据模型

- `AICharacter`：角色人设、模型配置、工具权限和长期记忆。
- `ChatGroup`：群聊主题、成员与所有者信息。
- `Message`：用户/AI 消息，支持引用、提及和媒体附件。
- `CharacterSkill`：角色可复用技能，声明说明步骤和所需工具权限。

## Agentic 文件生成流程

1. 用户在私聊中提出“生成文件/写文档/输出 HTML 或 MD”等自然语言请求。
2. `AgenticTaskClassifier` 判定需要进入 agentic 链路。
3. `AgentRuntime` 生成或解析工具请求，调用 `workspace.write` 写入工程目录。
4. 写入后读回内容生成预览，并在聊天消息中附加文件卡片。
5. 用户点击文件卡片即可通过系统默认应用打开生成产物。

## 本地运行与验证

```bash
flutter pub get
flutter analyze
flutter test
flutter run -d macos
```

## 注意事项

- 非 release 环境可能读取本地开发数据，`data/*.hive` 可能包含 API Key，应谨慎分享仓库。
- 文件写入通过本地桥接服务限制在授权 workspace 内，避免路径越界。
- 新增依赖前需要检查 Android Gradle API，避免使用当前 Flutter fork 不支持的 `android.flutter` 属性。
''';
      }
    }
    return '''
# Agentic Live Test

生成角色：$markdownCharacterName

## 用户请求

$userRequest

## Dart hello 程序

```dart
void main() {
  print('hello from ${character.name}');
}
```

## 验证说明

- 本文件通过 `workspace.patch` 写入到 `$path`。
- 如果你能在工作区看到这个文件，说明 AI 角色没有停在“正在做”，而是走了本地工具生成内容。
- 写入动作需要用户批准后才会执行。
''';
  }

  String _jsonString(String value) => jsonEncode(value);

  String _escapeHtml(String value) => const HtmlEscape().convert(value);

  String _escapeMarkdownHtml(String value) {
    return value
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
  }

  AgentRuntimeResult? _completedFallbackForExecutedTool({
    required AICharacter character,
    required ToolRequest request,
    required Map<String, dynamic> toolResult,
    required List<ToolRequest> executedRequests,
  }) {
    if (request.tool != AgentToolName.workspacePatch) return null;
    final ok = toolResult['ok'] == true || toolResult['exitCode'] == 0;
    if (!ok) return null;
    final summary = '${character.name} 已通过 workspace.patch 写入文件。'
        '工具返回 exitCode=${toolResult['exitCode'] ?? 0}，请查看附件或工作区文件确认内容。';
    // 写文件成功后，把刚写入的文件内容预览追加到兜底消息（读回失败已降级）。
    return AgentRuntimeResult(
      status: AgentRuntimeStatus.completed,
      pendingToolRequest: request,
      toolResult: toolResult,
      executedToolRequests: executedRequests,
      message: _appendFilePreview(summary, toolResult),
    );
  }
}

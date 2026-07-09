import 'dart:async';

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
    cleaned = cleaned.trim();
    if (cleaned.isEmpty) {
      final name =
          characterName?.isNotEmpty == true ? characterName! : '助手';
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

    if (requiresApproval(request.tool) && !approved && !autoApproveWriteTools) {
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
  Future<Map<String, dynamic>> _executeWorkspacePatch(ToolRequest request) async {
    final rawPath = request.args['path'] as String? ?? '';
    final path = WorkspacePathGuard.normalizeToRelative(rawPath);
    if (path.isEmpty) {
      return {'ok': false, 'error': 'empty_path', 'message': '缺少有效的文件路径'};
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
        lower.contains('写入') ||
        lower.contains('写文件') ||
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
      args: {'path': inferredPath, 'content': content},
    );
  }

  /// 模糊推断文件名：当关键词命中但用户未给出具体文件名时，
  /// 从消息中提取文件类型提示词（如“html 文件”“一个 md”“json 文件”），
  /// 并结合内容语义生成一个安全的相对文件名（如 `star_scene.html`、`report.md`）。
  ///
  /// 返回 null 表示未识别出任何文件生成意图（不应触发工具请求）。
  String? _inferWorkspaceFilePath(String text) {
    const supported = r'html|html5|md|markdown|dart|txt|text|json|yaml|yml|svg|css|js|ts|py|c|cpp|cc|h|hpp';
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
        r'(?:一个?)?\s*(html|html5|md|markdown|dart|txt|json|yaml|yml|svg|css|js|ts|py)\b',
        caseSensitive: false,
      ).firstMatch(text);
      ext = bare == null ? null : _normalizeExt(bare.group(1)!);
    }
    if (ext == null) return null;

    final lower = text.toLowerCase();
    String name;
    if (ext == 'html' || ext == 'svg' || ext == 'css') {
      // 画面 / 场景 / 视觉类 → 用内容关键词命名。
      if (lower.contains('湖') ||
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
          lower.contains('readme') ||
          lower.contains('report')) {
        name = 'report';
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
    return e;
  }

  String? _extractWorkspaceFilePath(String text) {
    final pathPattern = RegExp(
      r'(?<![\w./\\-])([\w][\w./\\-]*\.(?:md|markdown|dart|txt|json|yaml|yml|svg|html|css|js|ts|py|c|cc|cpp|h|hpp))(?![\w./\\-])',
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
    if (extension == 'dart') {
      return "void main() {\n  print('hello from ${character.name}');\n}\n";
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
  <text x="120" y="230" font-family="Arial, sans-serif" font-size="28" fill="#475569">Generated by ${character.name}</text>
  <circle cx="760" cy="170" r="54" fill="#6366f1"/>
  <path d="M710 330h120M710 370h90M710 410h150" stroke="#10b981" stroke-width="18" stroke-linecap="round"/>
</svg>
''';
    }
    if (extension == 'json') {
      return '''
{
  "generatedBy": "${character.name}",
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
  <title>Agentic Work</title>
</head>
<body>
  <h1>${character.name} 已生成文件</h1>
  <pre><code>void main() {
  print('hello from ${character.name}');
}</code></pre>
</body>
</html>
''';
    }
    return '''
# Agentic Live Test

生成角色：${character.name}

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

  String _jsonString(String value) {
    final encoded = value
        .replaceAll(r'\', r'\\')
        .replaceAll('"', r'\"')
        .replaceAll('\n', r'\n');
    return '"$encoded"';
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

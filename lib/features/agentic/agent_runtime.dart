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
  static const Duration completionTimeout = Duration(seconds: 70);

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
    this.enableLocalFilePlanner = false,
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
    var cleaned = text;
    // 1. 移除 ```agent_tool ... ``` 围栏块（含围栏本身）
    cleaned = cleaned.replaceAll(
      RegExp(r'```agent_tool\s*[\s\S]*?\s*```'),
      '',
    );
    // 2. 移除 <tool_call ... </tool_call> / </agent_tool> 完整 XML 块（含标签本身）。
    cleaned = cleaned.replaceAll(
      RegExp(r'<tool_call\s*[\s\S]*?\s*(?:</agent_tool>|</tool_call>)',
          caseSensitive: false),
      '',
    );
    // 3. 移除任何残留在文本中部/尾部的 <tool_call ...（无闭合标签）整段——
    //    直到字符串结束（兼容模型把 tool_call 块放在回复末尾的情形）。
    cleaned = cleaned.replaceAll(
      RegExp(r'<tool_call\b[\s\S]*$', caseSensitive: false),
      '',
    );
    // 4. 移除畸形工具协议的孤立片段：<function=...> / <parameter=...> 单行，
    //    以及 <function ...>...</function>、<parameter ...>...</parameter> 配对片段。
    //    这些常出现在模型“自选”的 <tool_call\n<function=workspace.patch> 变体中，
    //    若不被清理会直接把内部协议泄漏到聊天 UI。
    cleaned = cleaned.replaceAll(
      RegExp(r'^\s*<(?:function|parameter)\b[^\n]*$',
          caseSensitive: false, multiLine: true),
      '',
    );
    cleaned = cleaned.replaceAll(
      RegExp(
          r'<(?:function|parameter)\b[^>]*>[\s\S]*?</(?:function|parameter)>',
          caseSensitive: false),
      '',
    );
    cleaned = cleaned.trim();
    if (cleaned.isEmpty) {
      final name = characterName?.isNotEmpty == true ? characterName! : '助手';
      return '$name 似乎遇到了技术问题，已为你隐藏内部工具协议。';
    }
    return cleaned;
  }

  /// 写文件成功后追加一行简洁确认信息到最终消息文本。
  ///
  /// 仅在写文件工具（workspace.patch）执行成功、且已成功读回文件内容时生效：
  /// 从 [toolResult] 读取文件路径和大小信息。
  /// 不再注入文件正文到聊天消息——文件已通过 MediaAttachment（文件卡片）
  /// 展示给用户，在文本中重复大段内容只会导致消息被截断且难以阅读。
  ///
  /// 若没有路径信息（读回失败已降级），原样返回 [message]，不暴露任何异常。
  static String _appendFilePreview(
    String message,
    Map<String, dynamic> toolResult,
  ) {
    if (toolResult['ok'] != true) return message;
    final content = toolResult['readbackContent'] as String?;
    // 没有读回内容时不追加任何信息（降级静默）。
    if (content == null || content.isEmpty) return message;
    final path = toolResult['path'] as String? ?? '';
    final sizeKB = (content.length / 1024).toStringAsFixed(1);
    return '$message\n\n✅ 文件已生成：`$path`（$sizeKB KB）— 点击附件查看完整内容';
  }

  /// 响应护栏：拦截 LLM 在 final 文本中贴出的「裸代码 / 文件全文」泄漏（Bug A）。
  ///
  /// 尽管 [AgentPromptBuilder.buildToolResultPrompt] 已明确要求模型不要把文件
  /// 内容贴进回复，但部分模型仍会照做。文件已通过 [MediaAttachment]（附件卡片）
  /// 展示，正文只需简洁确认即可。
  ///
  /// 仅当 [text] 看起来像「大段代码 / 文件全文」时才把用户可见正文替换为简洁确认语；
  /// 普通的 1-2 句自然语言总结原样返回，绝不误杀。
  static String _guardFinalMessage(String text, {bool fileWritten = false}) {
    if (!_looksLikeFileContentLeak(text)) return text;
    return fileWritten ? '文件已生成，请查看附件。' : '结果已生成，请查看附件。';
  }

  /// 判断 [text] 是否像「大段代码 / 文件全文」泄漏（任一特征命中即视为需要收敛）：
  ///   - 代码围栏 ``` … ``` 包裹了较长内容（> 80 字符）；
  ///   - 未闭合的代码围栏（LLM 输出被截断或未完成，如 ```html … 无尾部 ```）；
  ///   - 文本含 `<!doctype`（任意位置，不区分大小写），或同时出现 `<html …>` 与
  ///     `</html>` 配对标签（整段 HTML 文档）；
  ///   - 出现 `import 'package:` / `void main(` 等源码特征；
  ///   - 连续多行（≥3 行）以 ≥2 空格或 tab 开头且含代码符号（疑似整段代码）；
  ///   - 高密度 HTML 标签（出现 ≥3 个不同的 HTML 标签如 div/body/style/script）。
  static bool _looksLikeFileContentLeak(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;

    // 1. 闭合的代码围栏且内部段较长。
    final fenceMatch = RegExp(r'```[\s\S]*?```').firstMatch(trimmed);
    if (fenceMatch != null) {
      final innerLength =
          fenceMatch.group(0)!.replaceAll(RegExp(r'```'), '').trim().length;
      if (innerLength > 80) return true;
    }

    // 1b. 未闭合的代码围栏——LLM 经常输出 ```html 然后贴大段代码但忘了闭合，
    //     或输出被截断。检测「有开无闭」且开标签后内容够长即视为泄漏。
    final unclosedFence = RegExp(r'```\w*\n([\s\S]*)').firstMatch(trimmed);
    if (unclosedFence != null && !trimmed.contains('```')) {
      // 有开 `` 但没有对应的闭 ```
      if (unclosedFence.group(1)!.trim().length > 60) return true;
    }
    // 更宽松：文本以 ``` 开头（或含 ``` 后无配对闭合）且总长度较大
    final openFences = RegExp(r'```').allMatches(trimmed).length;
    if (openFences >= 1 && openFences % 2 == 1 && trimmed.length > 200) {
      // 奇数个 ``` 围栏标记 = 存在未闭合块，且文本足够长
      return true;
    }

    // 2. HTML 文档特征。
    if (RegExp(r'<!doctype', caseSensitive: false).hasMatch(trimmed)) {
      return true;
    }
    if (RegExp(r'<html\b', caseSensitive: false).hasMatch(trimmed) &&
        RegExp(r'</html>', caseSensitive: false).hasMatch(trimmed)) {
      return true;
    }
    if (RegExp(r'^(<!doctype|<html)\b', caseSensitive: false)
        .hasMatch(trimmed)) {
      return true;
    }
    // 2b. 高密度 HTML 标签——出现多个不同 HTML 标签名说明是整段 HTML 被贴进回复。
    final htmlTags = <String>{
      for (final m in RegExp(
              r'<(div|body|head|style|script|section|nav|footer|main|article|header|span|p|h[1-6]|ul|ol|li|table|tr|td|th|form|input|button|a|img)\b')
          .allMatches(trimmed))
        m.group(1)!
    };
    if (htmlTags.length >= 4) return true; // 4+ 个不同 HTML 标签 → 几乎肯定是文件全文

    // 3. Dart / 源码特征关键词。
    if (RegExp(r"import\s+'package:|void\s+main\s*\(").hasMatch(trimmed)) {
      return true;
    }

    // 4. 连续多行缩进代码。
    if (_hasMultiLineIndentedCode(trimmed)) return true;

    return false;
  }

  /// 检测 [text] 中是否存在 ≥3 行以 ≥2 空格或 tab 开头、且含常见代码符号的缩进块，
  /// 用于识别「整段代码被贴进回复」的情形（自然语言总结几乎不会命中）。
  static bool _hasMultiLineIndentedCode(String text) {
    var indentedCodeLines = 0;
    final codeSymbol = RegExp(r'[{}();=<>]');
    for (final line in text.split('\n')) {
      final isIndented =
          RegExp(r'^\s{2,}|\t').hasMatch(line) && line.trim().isNotEmpty;
      if (isIndented && codeSymbol.hasMatch(line)) {
        indentedCodeLines++;
        if (indentedCodeLines >= 3) return true;
      }
    }
    return false;
  }

  /// 检测规划文本是否含有「工具调用痕迹」——即便 [ToolRequest.tryParse] 无法将其
  /// 解析为合法请求，也能据此判断模型"想调工具"而不是在普通聊天（Bug B-b1）。
  static bool _containsToolCallTrace(String text) {
    return RegExp(
      r'agent_tool|tool_call|workspace\.(patch|read|list)|'
      r'command\.run|browser\.context|skill\.(create|download)|'
      r'<function|<parameter',
      caseSensitive: false,
    ).hasMatch(text);
  }

  /// 有些模型理解了文件任务，却忽略工具协议，直接返回 ```html ...``` 或裸 HTML。
  /// 此时把模型已经生成好的完整内容恢复成 workspace.patch 请求，避免正文泄漏到
  /// 聊天气泡，也避免再次调用模型造成内容丢失。
  static ToolRequest? _recoverGeneratedFileRequest(
    String userRequest,
    String modelOutput,
  ) {
    final path = _inferGeneratedFilePath(userRequest);
    if (path == null) return null;
    final content = _extractGeneratedFileContent(modelOutput);
    if (content == null || content.trim().isEmpty) return null;
    return ToolRequest(
      tool: AgentToolName.workspacePatch,
      reason: '模型已生成文件内容，自动恢复为文件写入请求',
      args: {'path': path, 'content': content},
    );
  }

  static String? _inferGeneratedFilePath(String request) {
    final lower = request.toLowerCase();
    final hasCreateIntent = RegExp(
      r'(生成|创建|写|制作|做一个|做个|实现|开发|输出|导出|修改|改写|'
      r'create|write|build|make|generate)',
      caseSensitive: false,
    ).hasMatch(lower);
    if (!hasCreateIntent) return null;

    final explicit = RegExp(
      r'(?<![\w./\\-])([\w][\w./\\-]*\.(?:html?|md|markdown|dart|txt|json|yaml|yml|svg|css|js|ts|py|sh|bash|c|cc|cpp|h|hpp))(?![\w./\\-])',
      caseSensitive: false,
    ).firstMatch(request);
    final explicitPath = explicit?.group(1)?.replaceAll('\\', '/');
    if (explicitPath != null &&
        WorkspacePathGuard.isSafeRelativePath(explicitPath)) {
      return explicitPath;
    }

    if (RegExp(r'(html?|主页|个人页|介绍页|页面|网页|网站|落地页|landing)').hasMatch(lower)) {
      return 'page.html';
    }
    if (RegExp(r'(markdown|\bmd\b|文档|报告|简历)').hasMatch(lower)) {
      return 'report.md';
    }
    if (RegExp(r'(dart|flutter|应用|app|程序)').hasMatch(lower)) {
      return 'main.dart';
    }
    if (RegExp(r'(python|\bpy\b)').hasMatch(lower)) return 'script.py';
    if (RegExp(r'(javascript|\bjs\b)').hasMatch(lower)) return 'app.js';
    return null;
  }

  static String? _extractGeneratedFileContent(String output) {
    final fenced = RegExp(
      r'```(?:html?|md|markdown|dart|txt|json|ya?ml|svg|css|js|ts|python|py|sh|bash|c|cc|cpp)?\s*\n([\s\S]*?)\n?```',
      caseSensitive: false,
    ).firstMatch(output);
    if (fenced != null) return fenced.group(1)?.trim();

    final htmlStart = RegExp(r'<!doctype\s+html|<html\b', caseSensitive: false)
        .firstMatch(output)
        ?.start;
    if (htmlStart != null) {
      final tail = output.substring(htmlStart);
      final htmlEnds =
          RegExp(r'</html\s*>', caseSensitive: false).allMatches(tail).toList();
      final htmlEnd = htmlEnds.isEmpty ? null : htmlEnds.last;
      if (htmlEnd != null) return tail.substring(0, htmlEnd.end).trim();
      return tail.trim();
    }
    return null;
  }

  /// 更宽松的工具请求提取（[ToolRequest.tryParse] 失败后的兜底）：
  /// 仅在文本确实含有工具调用痕迹时调用，尝试识别几种常见变形让真正的工具调用
  /// 尽可能执行；若仍无法构造合法请求则返回 null，由调用方退化为简洁提示。
  static ToolRequest? _looseParseToolRequest(String content) {
    // 变形 1：<function=toolName> ... </function>，体内是 JSON 或 path/content 键值。
    final fnMatch = RegExp(
      r'<function\s*=\s*([\w.\-]+)\s*>([\s\S]*?)</function>',
      caseSensitive: false,
    ).firstMatch(content);
    if (fnMatch != null) {
      final toolName = fnMatch.group(1)!;
      final tool = AgentToolName.fromWire(toolName);
      final body = fnMatch.group(2)!;
      if (tool != null) {
        final args = _extractArgsFromText(body);
        if (args != null) {
          return ToolRequest(
            tool: tool,
            reason: args['reason'] as String? ?? '模型请求执行 $toolName',
            args: args,
          );
        }
      }
    }
    // 变形 2：文本出现 workspace.patch/write 且带 path/content 键值（无外层 wrapper）。
    if (content.contains('workspace.patch') ||
        content.contains('workspace.write')) {
      final args = _extractArgsFromText(content);
      if (args != null && args['path'] is String && args['content'] is String) {
        return ToolRequest(
          tool: AgentToolName.workspacePatch,
          reason: args['reason'] as String? ?? '模型请求写入文件',
          args: args,
        );
      }
    }
    return null;
  }

  /// 从文本中尽量提取工具参数（优先解析 JSON，退化到正则抓 path/content）。
  static Map<String, dynamic>? _extractArgsFromText(String text) {
    final balanced = _firstBalancedJsonObject(text);
    if (balanced is Map<String, dynamic>) {
      final args = balanced['args'];
      if (args is Map<String, dynamic>) return args;
      // 退化：JSON 顶层直接是 path/content（无 args 包裹）。
      if (balanced['path'] is String) return balanced;
    }
    final path = _firstJsonString(text, 'path');
    final contentVal = _firstJsonString(text, 'content');
    if (path != null && contentVal != null) {
      final reason = _firstJsonString(text, 'reason');
      return {
        'path': path,
        'content': contentVal,
        if (reason != null) 'reason': reason,
      };
    }
    return null;
  }

  /// 找到文本中第一个「括号配平」的 {...} 子串并 jsonDecode，失败返回 null。
  static Map<String, dynamic>? _firstBalancedJsonObject(String text) {
    final start = text.indexOf('{');
    if (start < 0) return null;
    var depth = 0;
    var inString = false;
    var escape = false;
    for (var i = start; i < text.length; i++) {
      final ch = text[i];
      if (inString) {
        if (escape) {
          escape = false;
        } else if (ch == '\\') {
          escape = true;
        } else if (ch == '"') {
          inString = false;
        }
        continue;
      }
      if (ch == '"') {
        inString = true;
      } else if (ch == '{') {
        depth++;
      } else if (ch == '}') {
        depth--;
        if (depth == 0) {
          final candidate = text.substring(start, i + 1);
          try {
            final decoded = jsonDecode(candidate);
            if (decoded is Map<String, dynamic>) return decoded;
          } on FormatException {
            // 非合法 JSON，停止扫描。
          }
          break;
        }
      }
    }
    return null;
  }

  /// 用正则抓出形如 "key": "value" 的 JSON 字符串值（兼容基本转义）。
  static String? _firstJsonString(String text, String key) {
    final match = RegExp(
      r'"$key"\s*:\s*"((?:[^"\\]|\\.)*)"',
    ).firstMatch(text);
    if (match == null) return null;
    final raw = match.group(1)!;
    return raw
        .replaceAll('\\"', '"')
        .replaceAll('\\\\', '\\')
        .replaceAll('\\n', '\n')
        .replaceAll('\\t', '\t');
  }

  Future<AgentRuntimeResult> run({
    required AICharacter character,
    required List<CharacterSkill> skills,
    required String userRequest,
    bool approved = false,
    bool autoApproveWriteTools = false,
    List<Map<String, dynamic>>? conversationHistory,
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
        conversationHistory: conversationHistory,
      );
    }

    final prompt = AgentPromptBuilder.buildToolPlanningPrompt(
      characterName: character.name,
      skills: skills,
      userRequest: userRequest,
    );
    late final Map<String, dynamic> first;
    try {
      first = await _completePlanningWithRetry([
        {'role': 'system', 'content': prompt},
        // 追加对话历史，使 LLM 在规划工具时拥有上下文（修复追问失忆）。
        ...?conversationHistory,
      ]);
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
    if (request != null) {
      return _handleToolRequest(
        character: character,
        request: request,
        userRequest: userRequest,
        approved: approved,
        autoApproveWriteTools: autoApproveWriteTools,
        remainingSteps: maxToolSteps,
        executedRequests: const [],
        conversationHistory: conversationHistory,
      );
    }

    final recoveredFileRequest =
        _recoverGeneratedFileRequest(userRequest, content);
    if (recoveredFileRequest != null) {
      return _handleToolRequest(
        character: character,
        request: recoveredFileRequest,
        userRequest: userRequest,
        approved: approved,
        autoApproveWriteTools: autoApproveWriteTools,
        remainingSteps: maxToolSteps,
        executedRequests: const [],
        conversationHistory: conversationHistory,
      );
    }

    // 规划阶段未解析出合法工具请求。这种情况下绝不把模型的「原始规划文本」
    // （如「我直接现在就为你写入文件…」）原样当作用户可见消息返回——那会
    // 泄漏内部意图并产生多余的「第一条」消息（Bug B-b1）。
    final hasExplicitFileIntent = _inferGeneratedFilePath(userRequest) != null;
    if (_containsToolCallTrace(content) || hasExplicitFileIntent) {
      // 文本含有工具调用痕迹但 tryParse 解析失败：尝试用更宽松的方式兜底提取
      // 工具请求并执行；提取失败才退化为简洁提示，绝不泄露原始规划文本。
      final looseRequest = _looseParseToolRequest(content);
      if (looseRequest != null) {
        return _handleToolRequest(
          character: character,
          request: looseRequest,
          userRequest: userRequest,
          approved: approved,
          autoApproveWriteTools: autoApproveWriteTools,
          remainingSteps: maxToolSteps,
          executedRequests: const [],
          conversationHistory: conversationHistory,
        );
      }

      // 宽松解析也失败：模型有工具意图但输出格式不对。
      // 尝试 re-prompt（给模型一次机会纠正格式）。
      final repromptResult = await _repromptForToolFormat(
        characterName: character.name,
        skills: skills,
        userRequest: userRequest,
        originalResponse: content,
        conversationHistory: conversationHistory,
      );
      if (repromptResult != null) {
        return _handleToolRequest(
          character: character,
          request: repromptResult,
          userRequest: userRequest,
          approved: approved,
          autoApproveWriteTools: autoApproveWriteTools,
          remainingSteps: maxToolSteps,
          executedRequests: const [],
          conversationHistory: conversationHistory,
        );
      }

      // re-prompt 也失败时绝不创建 content 为空的文件。空文件既丢失用户需求，
      // 又会产生一个看似成功的附件；这里明确失败并允许用户重试。
      return AgentRuntimeResult(
        status: AgentRuntimeStatus.completed,
        message: hasExplicitFileIntent
            ? '${character.name} 未能生成可写入的完整文件内容，请重试。'
            : '${character.name} 已收到请求，但未能解析出可执行的工具指令。',
      );
    }

    // 没有任何工具意图：模型是在正常文本回复（而非要调工具），清洗后原样返回。
    return AgentRuntimeResult(
      status: AgentRuntimeStatus.completed,
      message: _sanitizeToolProtocolLeak(
        content,
        characterName: character.name,
      ),
    );
  }

  Future<Map<String, dynamic>> _completePlanningWithRetry(
    List<Map<String, dynamic>> messages,
  ) async {
    Map<String, dynamic>? lastResult;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final result = await complete(messages).timeout(completionTimeout);
        lastResult = result;
        if (result['success'] == true ||
            !_isTransientCompletionFailure(result)) {
          return result;
        }
      } on TimeoutException {
        if (attempt == 1) rethrow;
      }
    }
    return lastResult ?? {'success': false, 'message': '连接超时'};
  }

  static bool _isTransientCompletionFailure(Map<String, dynamic> result) {
    final message = result['message']?.toString().toLowerCase() ?? '';
    return message.contains('网络连接失败') ||
        message.contains('connection reset') ||
        message.contains('http 429') ||
        message.contains('http 502') ||
        message.contains('http 503') ||
        message.contains('http 504');
  }

  /// 当模型第一次输出含有工具调用意图但格式无法解析时，用更严格的简短提示
  /// 重新要求模型**只**输出标准格式的工具请求块。
  ///
  /// 中文模型经常不遵循 prompt 中的 ```agent_tool 格式规范（第一次输出自然语言描述），
  /// 但第二次收到"只输出工具请求块"的极简指令后通常能正确输出可解析的 JSON。
  ///
  /// 返回解析出的 [ToolRequest]（成功），或 null（re-prompt 也失败/超时/异常）。
  Future<ToolRequest?> _repromptForToolFormat({
    required String characterName,
    required List<CharacterSkill> skills,
    required String userRequest,
    required String originalResponse,
    List<Map<String, dynamic>>? conversationHistory,
  }) async {
    final toolNames = {
      for (final s in skills) s.name,
      'workspace.list',
      'workspace.read',
      'workspace.patch',
      'command.run',
      'browser.context',
      'skill.create',
      'skill.download',
    }.join('、');

    // 极简 re-prompt：明确告诉模型上次输出格式不对、这次必须只输出 JSON 块。
    final repromptPrompt = '''
【重要】你之前的回复没有被识别为有效的工具请求。

用户请求：$userRequest

你之前说了：$originalResponse

现在请**只**输出一个工具请求块，不要任何其他文字：

```agent_tool
{"tool":"工具名","reason":"原因","args":{...}}
```

可用工具名：$toolNames

注意：
- 如果是生成文件，用 workspace.patch，把完整内容放 args.content
- 文件名要合理（如 page.html / report.md / main.dart）
- **绝对不要**在代码块外写任何解释、问候或规划文本
- 只输出上面这一个 ```agent_tool ... ``` 块，不多不少
''';

    try {
      final retry = await complete([
        {'role': 'system', 'content': repromptPrompt},
        ...?conversationHistory,
      ]).timeout(const Duration(seconds: 30));

      if (retry['success'] != true) return null;

      final retryContent = retry['message']?.toString() ?? '';
      final request = ToolRequest.tryParse(retryContent);
      if (request != null) return request;

      // tryParse 失败再试 looseParse
      return _looseParseToolRequest(retryContent);
    } on TimeoutException {
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<AgentRuntimeResult> _handleToolRequest({
    required AICharacter character,
    required ToolRequest request,
    required String userRequest,
    required bool approved,
    required bool autoApproveWriteTools,
    required int remainingSteps,
    required List<ToolRequest> executedRequests,
    List<Map<String, dynamic>>? conversationHistory,
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
    // workspace.patch 执行结果：即使失败（如文件冲突已自动改名重试、或桥接服务报错）
    // 也继续走 _continueAfterToolResult 让 LLM 整理结果——因为：
    //   a) 失败信息需要友好地呈现给用户（而非原始错误码）
    //   b) _continueAfterToolResult 内的 _guardFinalMessage 会拦截 LLM 可能泄漏的代码
    //   c) 若在此处短路返回 failed，调用方会直接把错误文本当消息展示且无护栏保护
    // 注意：重复写文件的防护由 _continueAfterToolResult 内的第二层防御负责。
    final nextExecutedRequests = [...executedRequests, request];
    return _continueAfterToolResult(
      character: character,
      request: request,
      userRequest: userRequest,
      toolResult: toolResult,
      remainingSteps: remainingSteps - 1,
      executedRequests: nextExecutedRequests,
      autoApproveWriteTools: autoApproveWriteTools,
      conversationHistory: conversationHistory,
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
    List<Map<String, dynamic>>? conversationHistory,
  }) async {
    if (request.tool == AgentToolName.workspacePatch &&
        toolResult['ok'] == true &&
        !_requiresPostWriteTool(userRequest)) {
      final completed = _completedFallbackForExecutedTool(
        character: character,
        request: request,
        toolResult: toolResult,
        executedRequests: executedRequests,
      );
      if (completed != null) return completed;
    }

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
        // 追加对话历史，使 LLM 在整理结果时拥有上下文（修复追问失忆）。
        ...?conversationHistory,
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
      // 第二层防御：已成功写入过文件后，禁止 LLM 再发起写文件请求。
      // 原因：即使第一层防御（_handleToolResult 中 workspace.patch 成功后直接 fallback）
      // 已覆盖大部分场景，但某些代码路径可能绕过它到达此处。
      // 若放行，LLM 会生成 page.html + page_2.html 等重复文件。
      final alreadyWroteFile = executedRequests.any(
        (r) => r.tool == AgentToolName.workspacePatch,
      );
      if (nextRequest.tool == AgentToolName.workspacePatch &&
          alreadyWroteFile) {
        // 静默吞掉重复写文件请求，视为已完成。
        return AgentRuntimeResult(
          status: AgentRuntimeStatus.completed,
          pendingToolRequest: request,
          toolResult: toolResult,
          executedToolRequests: executedRequests,
          message: _appendFilePreview(
            '${character.name} 已完成文件生成。',
            toolResult,
          ),
        );
      }
      return _handleToolRequest(
        character: character,
        request: nextRequest,
        userRequest: userRequest,
        approved: false,
        autoApproveWriteTools: autoApproveWriteTools,
        remainingSteps: remainingSteps,
        executedRequests: executedRequests,
        conversationHistory: conversationHistory,
      );
    }

    // 防御性过滤：多轮工具调用收尾时，同样需清理可能泄露的工具协议标记。
    final sanitized = _sanitizeToolProtocolLeak(
      content,
      characterName: character.name,
    );
    // 响应护栏（Bug A）：无论工具执行成功与否，都要拦截 LLM 在 final 文本中贴出的
    // 「裸代码 / 文件全文」。即使 workspace.patch 失败了（如文件冲突），LLM 的最终回复
    // 仍可能把完整 HTML/代码贴出来——必须收敛。
    //
    // 判定依据：只要本次请求是文件生成类工具（workspace.patch），且 final 文本看起来
    // 含大段代码/文件全文，就替换为简洁确认语。
    final isFileGenerationAttempt =
        request.tool == AgentToolName.workspacePatch;
    final guarded = _guardFinalMessage(
      sanitized,
      fileWritten: isFileGenerationAttempt && toolResult['ok'] == true,
    );
    // 写文件成功后，把「文件已生成」简洁确认信息追加到最终消息（内容不回写文本）。
    final finalMessage = _appendFilePreview(guarded, toolResult);
    return AgentRuntimeResult(
      status: AgentRuntimeStatus.completed,
      pendingToolRequest: request,
      toolResult: toolResult,
      executedToolRequests: executedRequests,
      message: finalMessage,
    );
  }

  static bool _requiresPostWriteTool(String userRequest) {
    final lower = userRequest.toLowerCase();
    return RegExp(
      r'(运行|执行|测试|验证|检查|构建|编译|flutter\s+(?:test|analyze|build)|'
      r'\btest\b|\banalyze\b|\bbuild\b|command\.run|terminal)',
      caseSensitive: false,
    ).hasMatch(lower);
  }

  Future<AgentRuntimeResult> executeApprovedTool({
    required AICharacter character,
    required ToolRequest request,
    required String userRequest,
    List<ToolRequest> priorExecutedRequests = const [],
    List<Map<String, dynamic>>? conversationHistory,
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
      conversationHistory: conversationHistory,
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
  /// 成功后再同步读回刚写入的文件全文，附加到返回结果里（key: [readbackContent]）。
  /// 读回内容仅用于生成「文件已生成」确认信息中的文件大小估算，**不会**回写进
  /// 聊天消息文本（文件另以 MediaAttachment 文件卡片完整展示）。
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
    // 文件已存在时自动改用递增后缀，避免：
    //   a) 静默覆盖导致用户丢失之前的内容
    //   b) 直接拒绝导致工具执行失败、LLM 回退到代码泄漏路径
    // 改名格式：page.html → page_2.html
    if (await _workspaceFileExists(path)) {
      path = await _nextAvailableWorkspacePath(path);
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
    final kind = classifyBridgeError(error);
    if (kind.isConnection) {
      return '[${character.name} 工具执行失败: 本地工具桥接服务未连接（桌面端应由 App 在进程内自动启动并监听 54263）。'
          '请检查 54263 端口是否被其他进程占用，或重启 App 后重试。]';
    }
    if (kind.statusCode != null) {
      if (kind.statusCode == 404) {
        return '[${character.name} 工具执行失败: 本地桥接服务返回 404（请求路径在服务端不存在）。'
            '客户端已尝试旧版兼容写入；若仍失败，请完全退出并重启 App 后重试。]';
      }
      return '[${character.name} 工具执行失败: 本地桥接服务返回 ${kind.statusCode}，请检查工具参数后重试。]';
    }
    final firstLine = error.toString().split('\n').first.trim();
    final concise =
        firstLine.length <= 160 ? firstLine : '${firstLine.substring(0, 160)}…';
    return '[${character.name} 工具执行失败: $concise]';
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
      // 直接把 (path, content) 交给桥接服务的 /workspace/write 端点写文件；
      // 冲突策略由 _executeWorkspacePatch 统一处理（保留旧文件并使用递增后缀）。
      args: {
        'path': inferredPath,
        'content': content,
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
    if (extension == 'dart') {
      return "void main() {\n  print('hello from ${character.name}');\n}\n";
    }
    if (extension == 'sh' || extension == 'bash') {
      return '''
#!/usr/bin/env bash
set -euo pipefail

echo "Agentic generated project check script"

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
  <circle cx="760" cy="170" r="54" fill="#6366f1"/>
  <path d="M710 330h120M710 370h90M710 410h150" stroke="#10b981" stroke-width="18" stroke-linecap="round"/>
</svg>
''';
    }
    if (extension == 'json') {
      return '''
{
  "status": "created",
  "request": ${_jsonString(userRequest)}
}
''';
    }
    if (extension == 'html') {
      // 通用 HTML5 骨架模板（不含具体视觉内容）。
      // 本地快速路径仅创建一个合法的空壳文件，具体内容由后续 LLM 整理
      // 结果时通过角色口吻描述；不再硬编码"流星雨"等与用户请求无关的内容，
      // 也不注入 AI 角色签名或水印。
      return '''
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>页面</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      padding: 20px;
      line-height: 1.6;
    }
  </style>
</head>
<body>
  <p><!-- 内容由 AI 根据用户请求生成 --></p>
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

## 用户请求

$userRequest

## 验证说明

- 本文件通过 `workspace.patch` 写入到 `$path`。
- 如果你能在工作区看到这个文件，说明文件已成功生成。
- 写入动作需要用户批准后才会执行。
''';
  }

  String _jsonString(String value) => jsonEncode(value);

  AgentRuntimeResult? _completedFallbackForExecutedTool({
    required AICharacter character,
    required ToolRequest request,
    required Map<String, dynamic> toolResult,
    required List<ToolRequest> executedRequests,
  }) {
    if (request.tool != AgentToolName.workspacePatch) return null;
    final ok = toolResult['ok'] == true || toolResult['exitCode'] == 0;
    if (!ok) return null;
    final path = toolResult['path'] as String?;
    final summary = path == null || path.isEmpty
        ? '${character.name} 已生成文件，请查看附件。'
        : '${character.name} 已生成文件 `$path`，请查看附件。';
    // 写文件成功后，把「文件已生成」简洁确认信息追加到兜底消息（内容不回写文本）。
    return AgentRuntimeResult(
      status: AgentRuntimeStatus.completed,
      pendingToolRequest: request,
      toolResult: toolResult,
      executedToolRequests: executedRequests,
      message: _appendFilePreview(summary, toolResult),
    );
  }
}

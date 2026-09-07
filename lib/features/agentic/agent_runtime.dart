import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/character_skill.dart';
import 'package:chat_group/core/models/tool_permission.dart';
import 'package:chat_group/core/retry_handler.dart';
import 'package:chat_group/features/agentic/agent_prompt_builder.dart';
import 'package:chat_group/features/agentic/agent_runtime_components.dart';
import 'package:chat_group/features/agentic/context_window_manager.dart';
import 'package:chat_group/features/agentic/agent_progress_meta.dart';
import 'package:chat_group/features/agentic/file_validator.dart';
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

enum AgentRuntimeProgressStage {
  /// 工具待用户批准（既有）。
  waitingForApproval,

  /// 每步工具执行成功后的聚合上报（避免重复计数，既有）。
  toolCompleted,

  /// 规划中（run 进入分支前）。
  planning,

  /// 调用 LLM 思考 / 生成中。
  thinking,

  /// 读取文件。
  readingFile,

  /// 调用工具前（已获权限、非待批准）。
  callingTool,

  /// 写入文件（路径规范化后）。
  writingFile,

  /// 文件写入成功。
  fileCreated,

  /// 校验结果（读回内容后）。
  validating,

  /// 步骤失败（工具执行抛错）。
  stepFailed,

  /// 用户拒绝 / 取消。
  stepRejected,
}

class AgentRuntimeProgress {
  final AgentRuntimeProgressStage stage;
  final List<ToolRequest> executedRequests;
  final ToolRequest? pendingRequest;

  /// 当前进行中步骤的人类可读文案；为 null 时由 stage 兜底（stageLabelFallback）。
  final String? currentStepLabel;

  /// 仅用于公开执行动态的安全摘要；不得包含文件正文、命令或模型思维。
  final String? publicDetail;

  // —— P2 新增：运行时态、非持久化字段 ——
  /// run() 启动时刻（ms 时间戳），整段任务仅捕获一次，构造时默认 null 以兼容旧调用。
  final int? runStartedAtMs;

  /// 当前步起点（ms 时间戳），stage/label 切步时重置；P2 仅注入不展示。
  final int? currentStepStartedAtMs;

  const AgentRuntimeProgress({
    required this.stage,
    required this.executedRequests,
    this.pendingRequest,
    this.currentStepLabel,
    this.publicDetail,
    this.runStartedAtMs,
    this.currentStepStartedAtMs,
  });
}

typedef AgentProgressHandler = Future<void> Function(
  AgentRuntimeProgress progress,
);
typedef AgentContextSummaryHandler = Future<void> Function(
  AICharacter character,
  ContextSummary summary,
);
typedef AgentToolApprovalPolicy = bool Function(AgentToolName tool);
typedef AgentToolRequestApprovalPolicy = Future<bool> Function(
  ToolRequest request,
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

/// Legacy/ordinary agentic compatibility runtime.
///
/// Work mode is owned by `WorkAgentLoop` and is deliberately not dispatched
/// through this facade. The legacy protocol and limits below remain only for
/// ordinary agentic integrations that still depend on this API.
class AgentRuntime {
  /// Legacy ordinary-agentic budget for the compatibility protocol.
  static const int maxToolSteps = 12;
  static const int preferredMaxOutputTokens = 8192;
  static const int preferredSummaryOutputTokens = 2048;
  static const Duration completionTimeout = Duration(seconds: 120);
  static const Duration fileGenerationTimeout = Duration(minutes: 5);

  /// Legacy ordinary-agentic ceiling for one compatibility tool call,
  /// including any bridge I/O used by those callers.
  static const Duration toolExecutionTimeout = Duration(seconds: 40);

  final AgentCompletion complete;
  final WorkspaceFileTool? workspaceFileTool;
  final BrowserContextTool? browserContextTool;
  final SkillCreateHandler? skillCreateHandler;
  final SkillDownloadHandler? skillDownloadHandler;
  final bool enableLocalFilePlanner;
  final RetrySleep retrySleep;
  final int completionMaxRetries;
  final AgentProgressHandler? onProgress;
  final ContextWindowManager? contextWindowManager;
  final AgentContextSummaryHandler? onContextSummary;
  final bool contextIsDirectChat;
  final AgentToolApprovalPolicy approvalPolicy;
  final AgentToolRequestApprovalPolicy? requestApprovalPolicy;
  final Set<ToolPermission>? grantedPermissions;
  final bool Function()? shouldCancel;

  /// Optional task-level gate for the post-write command validator. A null
  /// value preserves the historical permission-only behaviour used by
  /// ordinary agentic chats; work-mode tasks set this explicitly so a
  /// lightweight validation is the default unless the user asked to test,
  /// build, or analyse the result.
  final bool? allowCommandValidation;

  /// Work-mode tasks can provide their durable action budget (normally 100);
  /// ordinary agentic chat retains the historical 12-step default.
  final int toolStepLimit;

  /// A follow-up coordinator may resolve an explicit revision target from its
  /// structured `lastArtifactPaths`. When present, this path wins over the
  /// legacy conversation-history heuristic.
  final String? revisionTargetPath;

  /// New-file follow-ups may choose an available sibling when the requested
  /// name is occupied. Revision follow-ups leave this false and overwrite the
  /// resolved original path instead.
  final bool autoRenameIfExists;

  /// 进度上报去抖状态：仅当 stage 或 currentStepLabel 变化时，才真正触发一次
  /// 气泡重写，避免续写循环等高频 thinking 上报导致的视觉抖动。
  AgentRuntimeProgressStage? _lastReportedStage;
  String? _lastReportedLabel;
  int? _lastReportedExecutedCount;

  /// P2：run() 起点捕获的整段任务启动时刻（ms 时间戳），透传给进度上报；
  /// 仅运行时态，不写入 Hive。
  int? _runStartedAtMs;

  AgentRuntime({
    required this.complete,
    this.workspaceFileTool,
    this.browserContextTool,
    this.skillCreateHandler,
    this.skillDownloadHandler,
    this.enableLocalFilePlanner = false,
    this.retrySleep = Future<void>.delayed,
    this.completionMaxRetries = RetryHandler.defaultMaxRetries,
    this.onProgress,
    this.contextWindowManager,
    this.onContextSummary,
    this.contextIsDirectChat = false,
    this.approvalPolicy = AgentRuntime.requiresApproval,
    this.requestApprovalPolicy,
    this.grantedPermissions,
    this.shouldCancel,
    this.allowCommandValidation,
    this.revisionTargetPath,
    this.autoRenameIfExists = false,
    int? toolStepLimit,
  }) : toolStepLimit = toolStepLimit ?? maxToolSteps;

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
    // Sensitive writes deliberately omit readbackContent. Keep this guard at
    // the presentation boundary too, so a future adapter cannot accidentally
    // turn an approved secret readback into a chat attachment or size preview.
    if (toolResult['ok'] != true ||
        toolResult['sensitive'] == true ||
        toolResult['redacted'] == true) {
      return message;
    }
    final content = toolResult['readbackContent'] as String?;
    // 没有读回内容时不追加任何信息（降级静默）。
    if (content == null || content.isEmpty) return message;
    final path = toolResult['path'] as String? ?? '';
    final sizeKB = (content.length / 1024).toStringAsFixed(1);
    final validation = toolResult['validation'];
    final validationMessage =
        validation is Map ? validation['message']?.toString().trim() ?? '' : '';
    final evidence =
        validationMessage.isEmpty ? '本地工具已写入并成功读回文件。' : validationMessage;
    final downgradedFrom = toolResult['downgradedFrom'] as String?;
    final downgradeNote = downgradedFrom == null
        ? ''
        : '\n注意：⚠️ 原请求为二进制文档 `$downgradedFrom`，当前环境仅支持文本写入，'
            '已自动降级为 Markdown 文本 `$path`。';
    return '结论：${message.trim()}\n\n'
        '交付物：✅ 文件已生成：`$path`（$sizeKB KB）— 点击附件查看完整内容\n'
        '验证：🔎 $evidence\n'
        '自检：已确认文件可读，且聊天正文未重复粘贴产物内容。'
        '$downgradeNote\n'
        '风险：无。';
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
      String userRequest, String modelOutput,
      [String? structuredArtifactPath]) {
    final path =
        _inferGeneratedFilePath(userRequest, null, structuredArtifactPath);
    if (path == null) return null;
    final content = _extractGeneratedFileContent(modelOutput);
    if (content == null || content.trim().isEmpty) return null;
    return ToolRequest(
      tool: AgentToolName.workspacePatch,
      reason: '模型已生成文件内容，自动恢复为文件写入请求',
      args: {'path': path, 'content': content},
    );
  }

  static String _requestBody(String request) =>
      request.split('\n\n【持续可用的附件上下文】').first;

  /// 推断用户请求中隐含的文件路径（如"生成一个 HTML 页面"→ `page.html`）。
  ///
  /// 优先从请求文本本身提取显式文件名/扩展名；其次匹配文件类型关键词；
  /// 最后回退到 [conversationHistory] 中最近一个附件或 `workspace.patch` 路径，
  /// 以覆盖"修改上次生成的文件"这类无显式文件名的请求。
  static String? _inferGeneratedFilePath(
    String request, [
    List<Map<String, dynamic>>? conversationHistory,
    String? structuredArtifactPath,
  ]) {
    final requestText = _requestBody(request);
    final lower = requestText.toLowerCase();
    final structured = structuredArtifactPath?.trim();
    if (structured != null &&
        structured.isNotEmpty &&
        !RegExp(r'[\u0000-\u001f\u007f]').hasMatch(structured) &&
        !structured.split(RegExp(r'[/\\]+')).contains('..')) {
      // The coordinator already proved this path against the task's durable
      // artifact list and authorization boundary. Do not guess another file
      // from unrelated messages in the conversation.
      return structured.replaceAll('\\', '/');
    }
    String? previousArtifactPath;
    if (conversationHistory != null) {
      for (final message in conversationHistory.reversed) {
        // 用户后续上传的截图不是待修改产物；历史回退只考虑 AI/工具输出。
        if (message['role'] == 'user') continue;
        final content = message['content']?.toString() ?? '';
        final attachment = RegExp(
          r'^\s*-\s+([^\s；;\r\n]+\.(?:html?|md|markdown|dart|java|txt|'
          r'json|yaml|yml|svg|css|js|ts|py|sh|bash|c|cc|cpp|h|hpp|pdf|'
          r'doc|docx|xlsx?|pptx?|csv|sql|log|png|jpe?g|zip))'
          r'(?=\s*(?:[；;]|$))',
          caseSensitive: false,
          multiLine: true,
        ).firstMatch(content);
        final toolPath = RegExp(
          r'"tool"\s*:\s*"workspace\.patch"[\s\S]*?"path"\s*:\s*"([^"]+)"',
        ).firstMatch(content);
        final path =
            (attachment?.group(1) ?? toolPath?.group(1))?.replaceAll('\\', '/');
        if (path != null && WorkspacePathGuard.isSafeRelativePath(path)) {
          previousArtifactPath = path;
          break;
        }
      }
    }
    final explicitCreateVerb = RegExp(
      r'(生成|创建|写|设计|制作|做一个|做个|实现|开发|输出|导出|修改|改写|'
      r'create|write|build|make|generate|modify|edit|revise|update|change)',
      caseSensitive: false,
    ).hasMatch(lower);
    // 没有显式创建动词时，把“我要一份… + 文件制品关键词”也视为生成意图
    // （例如“我要一份工资报表excel文件”）。必须排除读取/查看/分析等请求，
    // 否则会误把“读一下这个excel文件”当成要生成文件，造成回退写文件的回归。
    final fileArtifactKeyword = RegExp(
      r'(excel|xlsx?|word|pdf|html|页面|网页|表格|电子表格|文档|报告|简历|'
      r'代码|脚本|文件|模版|模板|'
      // 以下为补全的常见文件类型中英文关键词（doc/docx/ppt/csv/txt/json/sql 等）。
      r'doc|docx|ppt|pptx|幻灯片|演示文稿|powerpoint|csv|文本|纯文本|txt|'
      r'json|数据|配置|yaml|yml|sql|数据库|日志|log|ts|typescript|'
      r'图片|照片|png|jpg|jpeg|压缩包|归档|zip)',
      caseSensitive: false,
    ).hasMatch(lower);
    final readModifyVerb = RegExp(
      r'(读|查看|看|打开|检查|分析|改一下|修改成|改成|更新|解析|预览|展示|'
      r'analyze|read|open|check|view|preview|modify|edit|revise|update|change)',
      caseSensitive: false,
    ).hasMatch(lower);
    // “一份 / 一个文件” 等量词表明用户想要“一份全新的制品”，而非指代已有文件。
    // 补充“来个”（口语“给我一个”）以覆盖“来个json配置”这类生成请求。
    final wishNewFile = RegExp(
      r'(一份|来一份|来个|来份|一份文件|一份excel|一份表格|一份文档|一份报告|'
      r'一个文件|一个excel|一个文档|一个报告|一个页面|一个网页|'
      r'做一份|写一份|生成一份|创建一份)',
      caseSensitive: false,
    ).hasMatch(lower);
    final hasCreateIntent = explicitCreateVerb ||
        (fileArtifactKeyword && wishNewFile && !readModifyVerb) ||
        (_isArtifactRevisionRequest(lower) && previousArtifactPath != null);
    if (!hasCreateIntent) return null;

    final explicit = RegExp(
      r'(?<![\w./\\-])([\w][\w./\\-]*\.(?:html?|md|markdown|dart|java|txt|json|'
      // 补全扩展名白名单：ppt/pptx/csv/sql/log/png/jpg/jpeg/zip。
      r'yaml|yml|svg|css|js|ts|py|sh|bash|c|cc|cpp|h|hpp|pdf|doc|docx|xlsx?|'
      r'ppt|pptx|csv|sql|log|png|jpe?g|zip))(?![\w./\\-])',
      caseSensitive: false,
    ).firstMatch(requestText);
    final explicitPath = explicit?.group(1)?.replaceAll('\\', '/');
    if (explicitPath != null &&
        WorkspacePathGuard.isSafeRelativePath(explicitPath)) {
      return explicitPath;
    }

    // PDF / 二进制文档：识别后走“直接生成文件”路径，由运行时把二进制 PDF
    // 优雅降级为 .md 写出真实文件（用户拿到的是真实附件），而不是落入规划路径
    // 让 LLM 用 skill.create 等非写入工具“空口声称已作为附件发送”（虚假附件 Bug 主因）。
    if (RegExp(r'(pdf|\.pdf\b)').hasMatch(lower)) return 'report.pdf';
    // Word / 文档：doc/docx/word 文档统一导向 docx，且必须在 md 分支之前。
    // 注意：仅匹配带 doc 前缀的“doc文档”这类词；裸“文档”（如“技术文档”）
    // 不在此命中，留给 md 分支（report.md），以免回归“技术文档→report.md”
    // 的既有行为（见 skill.create 回归测试）。
    if (RegExp(r'(docx?|word\s*文档|word文档|doc\s*文档)').hasMatch(lower)) {
      return 'report.docx';
    }
    // PPT / 演示文稿：识别为 pptx 二进制，后续由运行时降级为 .md 真实写出。
    if (RegExp(r'(ppt|pptx|幻灯片|演示文稿|课件|powerpoint)').hasMatch(lower)) {
      return 'slides.pptx';
    }
    // CSV / 表格数据：必须放在 Excel 分支之前，因为“表格数据”含“表格”，
    // 先匹配显式的 csv 关键词可避免被 excel 分支误判为 xlsx。
    if (RegExp(r'(csv|表格数据)').hasMatch(lower)) return 'data.csv';
    // 电子表格 / Excel：识别后应走“直接生成文件”路径，由运行时把二进制 .xlsx
    // 优雅降级为 .md 写出真实文件（用户拿到的是真实附件），而不是落入规划路径
    // 让 LLM 用 skill.create 等非写入工具“空口声称已作为附件发送”（虚假附件 Bug 主因）。
    if (RegExp(r'(excel|xlsx?|\.xlsx?\b|电子表格|表格)').hasMatch(lower)) {
      return 'report.xlsx';
    }
    if (RegExp(r'(html?|首页|主页|个人页|介绍页|页面|网页|网站|落地页|landing)').hasMatch(lower)) {
      return 'page.html';
    }
    // 纯文本：txt / 文本 / 纯文本 / 记事本。
    if (RegExp(r'(txt|文本|纯文本|记事本)').hasMatch(lower)) return 'note.txt';
    // Markdown：匹配 md / 文档 / 笔记 / 纪要 / 报告 / 简历。
    // 「文档」在此匹配（裸"技术文档"等需走 md），doc/word 前缀的文档仍走 docx 分支。
    if (RegExp(r'(markdown|\bmd\b|文档|报告|简历|笔记|纪要)').hasMatch(lower)) {
      return 'report.md';
    }
    if (RegExp(r'(json|数据文件|json数据)').hasMatch(lower)) return 'data.json';
    if (RegExp(r'(yaml|yml|配置)').hasMatch(lower)) return 'config.yaml';
    if (RegExp(r'(sql|数据库脚本|建表)').hasMatch(lower)) return 'script.sql';
    if (RegExp(r'(log|日志)').hasMatch(lower)) return 'app.log';
    if (RegExp(r'(ts|typescript)').hasMatch(lower)) return 'app.ts';
    // 图片二进制：png/jpg/jpeg 走降级为 .md 机制（与 doc/ppt 一致），不生成真实二进制。
    if (RegExp(r'(png|jpg|jpeg|图片|照片|图像)').hasMatch(lower)) {
      return 'image.png';
    }
    // 压缩包二进制：zip 走降级为 .md 机制。
    if (RegExp(r'(zip|压缩包|归档)').hasMatch(lower)) return 'archive.zip';
    if (RegExp(r'(c\+\+|cpp|\bcxx\b|c/c\+\+)').hasMatch(lower)) {
      if (RegExp(r'(系统信息|系统的?信息|cpu|内存|memory|system)').hasMatch(lower)) {
        return 'system_resource_monitor.cpp';
      }
      return 'main.cpp';
    }
    if (RegExp(r'(^|[^a-z])c\s*语言').hasMatch(lower)) return 'main.c';
    if (RegExp(r'\bjava\b').hasMatch(lower)) return 'Main.java';
    if (RegExp(r'(dart|flutter|应用|app|程序)').hasMatch(lower)) {
      return 'main.dart';
    }
    if (RegExp(r'(python|\bpy\b)').hasMatch(lower)) return 'script.py';
    if (RegExp(r'(javascript|\bjs\b)').hasMatch(lower)) return 'app.js';

    return _isArtifactRevisionRequest(lower) ? previousArtifactPath : null;
  }

  static bool _isArtifactRevisionRequest(String request) {
    final body = _requestBody(request).toLowerCase();
    final editVerb = RegExp(
      r'(修改|修复|改写|改成|改|调整|优化|完善|'
      r'fix|modify|edit|revise|update|change)',
      caseSensitive: false,
    ).hasMatch(body);
    final artifactReference = RegExp(
      r'(它|这个(?:页面|文件|代码)|该(?:页面|文件|代码)|附件|上一个|上次|'
      r'刚才|之前|现有|当前|同一(?:个)?文件|相同(?:的)?(?:个)?文件|'
      r'\bsame\b|\bthis\b|\bthat\b|\bprevious\b|\blast\b|'
      r'\bexisting\b|\bcurrent\b|\battachment\b)',
      caseSensitive: false,
    ).hasMatch(body);
    return editVerb && artifactReference;
  }

  String? _generatedFilePath(
    String request, [
    List<Map<String, dynamic>>? conversationHistory,
  ]) =>
      _inferGeneratedFilePath(
        request,
        conversationHistory,
        revisionTargetPath,
      );

  static ToolRequest _normalizeRevisionPatch(
    ToolRequest request,
    String userRequest, {
    bool forceRevision = false,
    String? revisionTargetPath,
  }) {
    if (request.tool != AgentToolName.workspacePatch ||
        (!forceRevision && !_isArtifactRevisionRequest(userRequest))) {
      return request;
    }
    final args = <String, dynamic>{...request.args};
    if (forceRevision && revisionTargetPath != null) {
      // The coordinator resolved this path from durable lastArtifactPaths. A
      // model-provided replacement path must not turn a revision into a new
      // file or escape the original approval scope.
      args['path'] = revisionTargetPath;
    }
    if (args['overwrite'] == true &&
        (!forceRevision || args['path'] == request.args['path'])) {
      return forceRevision && args['path'] != request.args['path']
          ? ToolRequest(tool: request.tool, reason: request.reason, args: args)
          : request;
    }
    return ToolRequest(
      tool: request.tool,
      reason: request.reason,
      args: {...args, 'overwrite': true},
    );
  }

  static String? _extractGeneratedFileContent(String output) {
    final fenced = RegExp(
      r'```(?:html?|md|markdown|dart|java|txt|json|ya?ml|svg|css|js|ts|python|py|sh|bash|c|cc|cpp)?\s*\n([\s\S]*?)\n?```',
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

  static String? _extractGeneratedFileContentForPath(
    String output,
    String path,
  ) {
    final parsed = _extractGeneratedFileContent(output);
    if (parsed != null && parsed.trim().isNotEmpty) return parsed;

    final unclosedFence = RegExp(
      r'```(?:html?|md|markdown|dart|java|txt|json|ya?ml|svg|css|js|ts|python|py|sh|bash|c|cc|cpp)?\s*\n([\s\S]*)$',
      caseSensitive: false,
    ).firstMatch(output.trim());
    if (unclosedFence != null) {
      final content = unclosedFence.group(1)?.trim();
      if (content != null && content.isNotEmpty) return content;
    }

    final content = output.trim();
    if (content.isEmpty || _looksLikeNarrationInsteadOfFile(content)) {
      return null;
    }

    final ext = path.split('.').last.toLowerCase();
    if (ext == 'md' || ext == 'markdown' || ext == 'txt') return content;
    // CSV / SQL / 日志均为纯文本，直接返回模型输出（与 txt 同逻辑），
    // 避免“直接生成”路径因抽取不到内容而回落到规划路径。
    if (ext == 'csv' || ext == 'sql' || ext == 'log') return content;
    if (ext == 'html' || ext == 'htm') {
      return RegExp(r'^(<!doctype|<html)\b', caseSensitive: false)
              .hasMatch(content)
          ? content
          : null;
    }
    if (ext == 'svg') {
      return RegExp(r'^<svg\b', caseSensitive: false).hasMatch(content)
          ? content
          : null;
    }
    if (ext == 'json') {
      return content.startsWith('{') || content.startsWith('[')
          ? content
          : null;
    }
    if (ext == 'yaml' || ext == 'yml') {
      return RegExp(r'^[\w.-]+\s*:', multiLine: true).hasMatch(content)
          ? content
          : null;
    }
    if (const {'c', 'cc', 'cpp', 'h', 'hpp'}.contains(ext)) {
      return RegExp(
                  r'(#include\s*[<"]|int\s+main\s*\(|class\s+\w+|namespace\s+\w+)')
              .hasMatch(content)
          ? content
          : null;
    }
    if (ext == 'dart') {
      return RegExp(r"(import\s+'package:|void\s+main\s*\(|class\s+\w+)")
              .hasMatch(content)
          ? content
          : null;
    }
    if (ext == 'java') {
      return RegExp(r'(public\s+(?:final\s+)?class\s+\w+|class\s+\w+|'
                  r'interface\s+\w+|record\s+\w+|static\s+void\s+main\s*\(|'
                  r'import\s+java\.)')
              .hasMatch(content)
          ? content
          : null;
    }
    if (ext == 'js' || ext == 'ts') {
      return RegExp(
                  r'(function\s+\w+|const\s+\w+\s*=|let\s+\w+\s*=|document\.)')
              .hasMatch(content)
          ? content
          : null;
    }
    if (ext == 'py') {
      return RegExp(r'(def\s+\w+\s*\(|import\s+\w+|if\s+__name__)')
              .hasMatch(content)
          ? content
          : null;
    }
    if (ext == 'sh' || ext == 'bash') {
      return content.startsWith('#!') || content.contains('\nset -')
          ? content
          : null;
    }
    if (ext == 'css') {
      return RegExp(r'[\w.#:-]+\s*\{[\s\S]*\}').hasMatch(content)
          ? content
          : null;
    }
    return null;
  }

  static bool _looksLikeNarrationInsteadOfFile(String content) {
    final lower = content.toLowerCase();
    if (RegExp(r'^(好的|抱歉|对不起|以下是|这是|我已经|我可以|无法|不能)').hasMatch(content)) {
      return true;
    }
    return lower.contains('复制保存为') ||
        lower.contains('save as') ||
        lower.contains('```');
  }

  Future<AgentRuntimeResult> run({
    required AICharacter character,
    required List<CharacterSkill> skills,
    required String userRequest,
    bool approved = false,
    List<Map<String, dynamic>>? conversationHistory,
    bool forceSkillCreation = false,
    List<ToolRequest> priorExecutedRequests = const [],
    String workModeContext = '',
  }) async {
    if (shouldCancel?.call() == true) {
      return const AgentRuntimeResult(
        status: AgentRuntimeStatus.failed,
        message: '工作模式已关闭，任务已安全中止。',
      );
    }
    // P2：捕获整段任务启动时刻，仅一次，后续进度上报通过 _reportProgress 透传。
    _runStartedAtMs = DateTime.now().millisecondsSinceEpoch;
    // 进入分支前先上报「规划中」，驱动进度气泡从首行开始生长。
    await _reportProgress(AgentRuntimeProgress(
      stage: AgentRuntimeProgressStage.planning,
      executedRequests: priorExecutedRequests,
    ));
    if (forceSkillCreation) {
      return _handleToolRequest(
        character: character,
        request: _skillCreationRequest(character, userRequest),
        userRequest: userRequest,
        approved: approved,
        remainingSteps: toolStepLimit,
        executedRequests: priorExecutedRequests,
        conversationHistory: conversationHistory,
      );
    }
    final localRequest = enableLocalFilePlanner
        ? _localFileGenerationRequest(character, userRequest)
        : null;
    if (localRequest != null) {
      return _handleToolRequest(
        character: character,
        request: localRequest,
        userRequest: userRequest,
        approved: approved,
        remainingSteps: toolStepLimit,
        executedRequests: priorExecutedRequests,
        conversationHistory: conversationHistory,
      );
    }

    // 明确的新建文件请求已经能在本地安全推断出路径，不需要再让模型
    // 先生成一份“包含完整文件内容的工具计划 JSON”。对大型 HTML 来说，
    // JSON 转义会放大输出并在 120 秒总时限处被截断。直接请求文件正文，
    // 然后由运行时本地包装成 workspace.patch，可以避免冗余规划与误报超时。
    if (_canGenerateNewFileDirectly(
        userRequest, conversationHistory, revisionTargetPath)) {
      try {
        final directFileRequest = await _generateFileContentRequest(
          character: character,
          userRequest: userRequest,
          path: _generatedFilePath(userRequest, conversationHistory)!,
          conversationHistory: conversationHistory,
          executedRequests: priorExecutedRequests,
          throwOnFailure: true,
        );
        if (directFileRequest != null) {
          return _handleToolRequest(
            character: character,
            request: directFileRequest,
            userRequest: userRequest,
            approved: approved,
            remainingSteps: toolStepLimit,
            executedRequests: priorExecutedRequests,
            conversationHistory: conversationHistory,
          );
        }
      } on TimeoutException {
        final fallbackRequest =
            _safeLocalFallbackFileRequest(character, userRequest);
        if (fallbackRequest != null) {
          return _handleToolRequest(
            character: character,
            request: fallbackRequest,
            userRequest: userRequest,
            approved: approved,
            remainingSteps: toolStepLimit,
            executedRequests: priorExecutedRequests,
            conversationHistory: conversationHistory,
          );
        }
        return AgentRuntimeResult(
          status: AgentRuntimeStatus.failed,
          message:
              '[${character.name} 工具任务失败: 模型在 ${fileGenerationTimeout.inSeconds} 秒内没有生成完整文件内容。请重试，或检查模型/网络配置。]',
        );
      } catch (error) {
        final fallbackRequest =
            _safeLocalFallbackFileRequest(character, userRequest);
        if (fallbackRequest != null) {
          return _handleToolRequest(
            character: character,
            request: fallbackRequest,
            userRequest: userRequest,
            approved: approved,
            remainingSteps: toolStepLimit,
            executedRequests: priorExecutedRequests,
            conversationHistory: conversationHistory,
          );
        }
        return AgentRuntimeResult(
          status: AgentRuntimeStatus.failed,
          message: '[${character.name} 工具任务失败: $error]',
        );
      }
    }

    final prompt = AgentPromptBuilder.buildToolPlanningPrompt(
      rolePlaySystemPrompt: character.rolePlaySystemPrompt,
      skills: skills,
      userRequest: userRequest,
      workModeContext: workModeContext,
    );
    // 规划 LLM 调用前上报「思考中」，携带截至当前的完整已执行列表。
    await _reportProgress(AgentRuntimeProgress(
      stage: AgentRuntimeProgressStage.thinking,
      executedRequests: priorExecutedRequests,
      currentStepLabel: thinkingLabel('规划任务步骤'),
    ));
    late final Map<String, dynamic> first;
    try {
      first = await _completePlanningWithRetry(character, [
        {'role': 'system', 'content': prompt},
        // 追加对话历史，使 LLM 在规划工具时拥有上下文（修复追问失忆）。
        ...?conversationHistory,
      ]);
    } on TimeoutException {
      final fallbackRequest = await _fallbackFileRequestAfterPlanningFailure(
        character: character,
        userRequest: userRequest,
        conversationHistory: conversationHistory,
        executedRequests: priorExecutedRequests,
      );
      if (fallbackRequest != null) {
        return _handleToolRequest(
          character: character,
          request: fallbackRequest,
          userRequest: userRequest,
          approved: approved,
          remainingSteps: toolStepLimit,
          executedRequests: priorExecutedRequests,
          conversationHistory: conversationHistory,
        );
      }
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
    if (shouldCancel?.call() == true) {
      return const AgentRuntimeResult(
        status: AgentRuntimeStatus.failed,
        message: '工作模式已关闭，任务已安全中止。',
      );
    }
    if (first['success'] != true) {
      final localRequest =
          _safeLocalFallbackFileRequest(character, userRequest);
      if (localRequest != null) {
        return _handleToolRequest(
          character: character,
          request: localRequest,
          userRequest: userRequest,
          approved: approved,
          remainingSteps: toolStepLimit,
          executedRequests: priorExecutedRequests,
          conversationHistory: conversationHistory,
        );
      }
      return AgentRuntimeResult(
        status: AgentRuntimeStatus.failed,
        message: '[${character.name} 工具任务失败: ${first['message'] ?? '未知错误'}]',
      );
    }

    final content = first['message']?.toString() ?? '';
    final request = AgentProtocolParser.parseStrict(content);
    if (request != null) {
      return _handleToolRequest(
        character: character,
        request: request,
        userRequest: userRequest,
        approved: approved,
        remainingSteps: toolStepLimit,
        executedRequests: priorExecutedRequests,
        conversationHistory: conversationHistory,
      );
    }

    final recoveredFileRequest = _recoverGeneratedFileRequest(
      userRequest,
      content,
      revisionTargetPath,
    );
    if (recoveredFileRequest != null) {
      return _handleToolRequest(
        character: character,
        request: recoveredFileRequest,
        userRequest: userRequest,
        approved: approved,
        remainingSteps: toolStepLimit,
        executedRequests: priorExecutedRequests,
        conversationHistory: conversationHistory,
      );
    }

    // 规划阶段未解析出合法工具请求。这种情况下绝不把模型的「原始规划文本」
    // （如「我直接现在就为你写入文件…」）原样当作用户可见消息返回——那会
    // 泄漏内部意图并产生多余的「第一条」消息（Bug B-b1）。
    final hasExplicitFileIntent =
        _generatedFilePath(userRequest, conversationHistory) != null;
    if (_containsToolCallTrace(content) || hasExplicitFileIntent) {
      // 文本含有工具调用痕迹但 tryParse 解析失败：尝试用更宽松的方式兜底提取
      // 工具请求并执行；提取失败才退化为简洁提示，绝不泄露原始规划文本。
      final looseRequest = AgentProtocolParser.parseLoose(content);
      if (looseRequest != null) {
        return _handleToolRequest(
          character: character,
          request: looseRequest,
          userRequest: userRequest,
          approved: approved,
          remainingSteps: toolStepLimit,
          executedRequests: priorExecutedRequests,
          conversationHistory: conversationHistory,
        );
      }

      // 宽松解析也失败：模型有工具意图但输出格式不对。
      // 尝试 re-prompt（给模型一次机会纠正格式）。
      // re-prompt LLM 调用前上报「思考中（纠正格式）」。
      await _reportProgress(AgentRuntimeProgress(
        stage: AgentRuntimeProgressStage.thinking,
        executedRequests: priorExecutedRequests,
        currentStepLabel: thinkingLabel('纠正工具调用格式'),
      ));
      final repromptResult = await _repromptForToolFormat(
        character: character,
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
          remainingSteps: toolStepLimit,
          executedRequests: priorExecutedRequests,
          conversationHistory: conversationHistory,
        );
      }

      final fallbackRequest = await _fallbackFileRequestAfterPlanningFailure(
        character: character,
        userRequest: userRequest,
        conversationHistory: conversationHistory,
        executedRequests: priorExecutedRequests,
      );
      if (fallbackRequest != null) {
        return _handleToolRequest(
          character: character,
          request: fallbackRequest,
          userRequest: userRequest,
          approved: approved,
          remainingSteps: toolStepLimit,
          executedRequests: priorExecutedRequests,
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

  ToolRequest _skillCreationRequest(
    AICharacter character,
    String userRequest,
  ) {
    final compact = userRequest.trim().replaceAll(RegExp(r'\s+'), ' ');
    final shortName =
        compact.length <= 20 ? compact : '${compact.substring(0, 20)}…';
    final permissions = character.toolPermissions
        .where((permission) =>
            permission != ToolPermission.skillCreate &&
            permission != ToolPermission.skillDownload)
        .map((permission) => permission.name)
        .toList();
    return ToolRequest(
      tool: AgentToolName.skillCreate,
      reason: '没有已安装或内置技能匹配当前意图，先创建可复用技能',
      args: {
        'name': '$shortName 工作流',
        'domain': 'custom',
        'description': '为请求“$compact”创建的角色专业技能。',
        'instructions': const [
          '确认目标、输入、约束和可观察的完成标准。',
          '读取或收集完成任务所需的最小上下文。',
          '按顺序执行任务步骤，并保留关键决策与产物。',
          '验证结果，说明证据、风险和后续可复用方式。',
        ],
        'permissions': permissions,
      },
    );
  }

  Future<Map<String, dynamic>> _completePlanningWithRetry(
    AICharacter character,
    List<Map<String, dynamic>> messages,
  ) =>
      _completeWithRetry(
        character,
        messages,
        allowContextCompaction: false,
      );

  Future<Map<String, dynamic>> _completeWithRetry(
    AICharacter character,
    List<Map<String, dynamic>> messages, {
    Duration timeout = completionTimeout,
    bool allowContextCompaction = true,
  }) async {
    final prepared = allowContextCompaction
        ? await _prepareCompletionMessages(character, messages)
        : messages;
    return RetryHandler.executeWithRetry<Map<String, dynamic>>(
      operation: (_) => complete(prepared).timeout(timeout),
      shouldRetryResult: RetryHandler.isTransientResult,
      sleep: retrySleep,
      maxRetries: completionMaxRetries,
    );
  }

  Future<List<Map<String, dynamic>>> _prepareCompletionMessages(
    AICharacter character,
    List<Map<String, dynamic>> messages,
  ) async {
    final manager = contextWindowManager;
    if (manager == null || !manager.shouldSummarize(messages)) return messages;
    try {
      final summary = await manager.summarize(
        messages,
        isDirectChat: contextIsDirectChat,
      );
      final handler = onContextSummary;
      if (handler != null) await handler(character, summary);
      return manager.compact(messages, summary);
    } catch (_) {
      return messages;
    }
  }

  Future<ToolRequest?> _fallbackFileRequestAfterPlanningFailure({
    required AICharacter character,
    required String userRequest,
    List<Map<String, dynamic>>? conversationHistory,
    List<ToolRequest> executedRequests = const [],
  }) async {
    if (!_canGenerateNewFileDirectly(
        userRequest, conversationHistory, revisionTargetPath)) {
      return null;
    }
    final path = _generatedFilePath(userRequest, conversationHistory);
    if (path == null) return null;

    final modelRequest = await _generateFileContentRequest(
      character: character,
      userRequest: userRequest,
      path: path,
      conversationHistory: conversationHistory,
      executedRequests: executedRequests,
    );
    if (modelRequest != null) return modelRequest;

    final localRequest = _safeLocalFallbackFileRequest(character, userRequest);
    if (localRequest != null) return localRequest;
    return null;
  }

  /// 判断用户请求是否可以直接推断出文件路径并走"直接生成文件"路径
  ///（跳过 LLM 规划，直接让模型输出完整文件内容）。
  ///
  /// "读取/查看/分析"类动词仍然排除：这些请求是要读取现有内容而非生成新内容。
  /// "修改"类动词不再排除——如果对话历史包含 workspace.patch 路径，LLM 已能看到
  /// 原文件内容，可以直接生成修改后的完整内容（覆盖"把背景改成红色"这类场景）。
  static bool _canGenerateNewFileDirectly(
    String userRequest, [
    List<Map<String, dynamic>>? conversationHistory,
    String? structuredArtifactPath,
  ]) {
    final lower = userRequest.toLowerCase();
    if (RegExp(
      r'(读取|读一下|检查|分析|查看|看|打开|'
      r'analyze|read|open|check|view|preview)',
      caseSensitive: false,
    ).hasMatch(lower)) {
      return false;
    }
    return _inferGeneratedFilePath(
          userRequest,
          conversationHistory,
          structuredArtifactPath,
        ) !=
        null;
  }

  Future<ToolRequest?> _generateFileContentRequest({
    required AICharacter character,
    required String userRequest,
    required String path,
    List<Map<String, dynamic>>? conversationHistory,
    bool throwOnFailure = false,
    List<ToolRequest> executedRequests = const [],
  }) async {
    final prompt = '''
${character.rolePlaySystemPrompt}

用户要你生成一个文件。

文件路径：$path
用户请求：$userRequest

请直接输出这个文件的完整内容。
系统会在收到正文后本地包装为 workspace.patch；你不要输出 agent_tool 或工具 JSON。
规则：
- 不要输出 ``` 代码围栏。
- 不要解释，不要说“复制保存为文件”，不要贴任何聊天寒暄。
- 不要添加作者签名、水印、generated by、AI 身份标识。
- 输出必须从文件第一行开始，到文件最后一行结束。
- 优先保证文件完整可运行，控制在 6500 token 内；必要时减少重复样式或次要特效。
''';

    try {
      final generationMessages = <Map<String, dynamic>>[
        {'role': 'system', 'content': prompt},
        ...?conversationHistory,
        // 当前请求已从历史中去重，必须作为最后一个 user turn 补回。
        // 否则历史以 assistant 结尾时，兼容模型可能续写上一份附件内容。
        {
          'role': 'user',
          'content': '当前文件生成请求（只执行这一条）：$userRequest',
        },
      ];
      // 首轮文件内容生成 LLM 调用前上报「思考中（生成文件内容）」。
      await _reportProgress(AgentRuntimeProgress(
        stage: AgentRuntimeProgressStage.thinking,
        executedRequests: executedRequests,
        currentStepLabel: thinkingLabel('生成文件内容：$path'),
      ));
      var result = await _completeWithRetry(
        character,
        generationMessages,
        timeout: fileGenerationTimeout,
      );
      if (result['success'] != true) {
        if (throwOnFailure) {
          throw StateError(result['message']?.toString() ?? '未知错误');
        }
        return null;
      }
      var output = result['message']?.toString() ?? '';
      final parsed = AgentProtocolParser.parse(output);
      if (parsed != null && parsed.tool == AgentToolName.workspacePatch) {
        return parsed;
      }
      for (var continuation = 0;
          continuation < 2 && !_isGeneratedFileComplete(path, output);
          continuation++) {
        // 续写轮次 LLM 调用前同样上报「思考中」；去抖层会忽略与首轮相同的上报。
        await _reportProgress(AgentRuntimeProgress(
          stage: AgentRuntimeProgressStage.thinking,
          executedRequests: executedRequests,
          currentStepLabel: thinkingLabel('生成文件内容：$path'),
        ));
        result = await _completeWithRetry(
          character,
          [
            ...generationMessages,
            {'role': 'assistant', 'content': output},
            {
              'role': 'user',
              'content': '上一条因输出长度上限而截断。'
                  '请从上一条末尾的下一个字符开始，只输出剩余文件内容。'
                  '不要重复已有内容，不要代码围栏，不要解释。',
            },
          ],
          timeout: fileGenerationTimeout,
        );
        if (result['success'] != true) {
          if (throwOnFailure) {
            throw StateError(result['message']?.toString() ?? '文件续写失败');
          }
          return null;
        }
        output = _mergeGeneratedFileContinuation(
          output,
          result['message']?.toString() ?? '',
        );
      }
      if (!_isGeneratedFileComplete(path, output)) {
        if (throwOnFailure) {
          throw StateError('模型输出达到长度上限，续写后文件仍不完整');
        }
        return null;
      }
      final content = _extractGeneratedFileContentForPath(output, path);
      if (content == null || content.trim().isEmpty) return null;
      return ToolRequest(
        tool: AgentToolName.workspacePatch,
        reason: '模型未返回工具计划，已直接生成 $path 的完整内容并恢复为文件写入请求',
        args: {'path': path, 'content': content},
      );
    } on TimeoutException {
      if (throwOnFailure) rethrow;
      return null;
    } catch (_) {
      if (throwOnFailure) rethrow;
      return null;
    }
  }

  static bool _isGeneratedFileComplete(String path, String output) {
    final extension = path.split('.').last.toLowerCase();
    if (extension != 'html' && extension != 'htm') return true;
    final lower = output.toLowerCase();
    final startsAsHtml = RegExp(r'<!doctype\s+html|<html\b').hasMatch(lower);
    if (!startsAsHtml) return true;
    return lower.contains('</body>') && lower.contains('</html>');
  }

  static String _mergeGeneratedFileContinuation(
    String existing,
    String continuation,
  ) {
    var next = continuation;
    next = next.replaceFirst(
      RegExp(r'^```(?:html?|\w+)?\s*\n?', caseSensitive: false),
      '',
    );
    next = next.replaceFirst(RegExp(r'\n?```\s*$'), '');
    if (next.trim().isEmpty) return existing;
    if (RegExp(r'^(<!doctype\s+html|<html\b)', caseSensitive: false)
            .hasMatch(next) &&
        _isGeneratedFileComplete('page.html', next)) {
      return next;
    }
    final overlapLimit =
        existing.length < next.length ? existing.length : next.length;
    final maxOverlap = overlapLimit < 4096 ? overlapLimit : 4096;
    for (var length = maxOverlap; length > 0; length--) {
      if (existing.endsWith(next.substring(0, length))) {
        return existing + next.substring(length);
      }
    }
    return existing + next;
  }

  /// 当模型第一次输出含有工具调用意图但格式无法解析时，用更严格的简短提示
  /// 重新要求模型**只**输出标准格式的工具请求块。
  ///
  /// 中文模型经常不遵循 prompt 中的 ```agent_tool 格式规范（第一次输出自然语言描述），
  /// 但第二次收到"只输出工具请求块"的极简指令后通常能正确输出可解析的 JSON。
  ///
  /// 返回解析出的 [ToolRequest]（成功），或 null（re-prompt 也失败/超时/异常）。
  Future<ToolRequest?> _repromptForToolFormat({
    required AICharacter character,
    required List<CharacterSkill> skills,
    required String userRequest,
    required String originalResponse,
    List<Map<String, dynamic>>? conversationHistory,
  }) async {
    final toolNames = {
      for (final s in skills) s.name,
      'workspace.list',
      'workspace.read',
      'workspace.search',
      'workspace.patch',
      'workspace.rename',
      'workspace.delete',
      'command.run',
      'browser.context',
      'skill.create',
      'skill.download',
    }.join('、');

    // 极简 re-prompt：明确告诉模型上次输出格式不对、这次必须只输出 JSON 块。
    final originalFilePath =
        _generatedFilePath(userRequest, conversationHistory);
    final pathHint = originalFilePath != null
        ? '注意：用户要求修改的文件是 `$originalFilePath`，不要创建新文件，直接对已有文件发起 workspace.patch 写入修改后的完整内容。\n'
        : '';
    final repromptPrompt = '''
${character.rolePlaySystemPrompt}

【重要】你之前的回复没有被识别为有效的工具请求。

用户请求：$userRequest

你之前说了：$originalResponse

$pathHint现在请**只**输出一个工具请求块，不要任何其他文字：

```agent_tool
{"tool":"工具名","reason":"原因","args":{...}}
```

可用工具名：$toolNames

注意：
- 如果是修改已有文件，用 workspace.patch，args.path 用已有文件路径，args.content 放修改后的**完整**文件内容
- **绝对不要**在代码块外写任何解释、问候或规划文本
- 只输出上面这一个 ```agent_tool ... ``` 块，不多不少
''';

    for (var correction = 0; correction < 3; correction++) {
      try {
        final retry = await _completeWithRetry(
            character,
            [
              {'role': 'system', 'content': repromptPrompt},
              ...?conversationHistory,
            ],
            timeout: const Duration(seconds: 30));
        if (retry['success'] != true) return null;
        final retryContent = retry['message']?.toString() ?? '';
        final request = AgentProtocolParser.parse(retryContent);
        if (request != null) return request;
      } on TimeoutException {
        return null;
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  Future<AgentRuntimeResult> _handleToolRequest({
    required AICharacter character,
    required ToolRequest request,
    required String userRequest,
    required bool approved,
    required int remainingSteps,
    required List<ToolRequest> executedRequests,
    List<Map<String, dynamic>>? conversationHistory,
  }) async {
    if (shouldCancel?.call() == true) {
      return AgentRuntimeResult(
        status: AgentRuntimeStatus.failed,
        pendingToolRequest: request,
        executedToolRequests: executedRequests,
        message: '工作模式已关闭，任务已安全中止。',
      );
    }
    request = _normalizeRevisionPatch(
      request,
      userRequest,
      forceRevision: revisionTargetPath != null,
      revisionTargetPath: revisionTargetPath,
    );
    if (remainingSteps <= 0) {
      return AgentRuntimeResult(
        status: AgentRuntimeStatus.failed,
        pendingToolRequest: request,
        executedToolRequests: executedRequests,
        message: '[${character.name} 工具任务失败: 工具调用次数超过上限]',
      );
    }

    final permission = permissionForTool(request.tool);
    if (!_hasPermission(character, permission)) {
      return AgentRuntimeResult(
        status: AgentRuntimeStatus.permissionMissing,
        pendingToolRequest: request,
        executedToolRequests: executedRequests,
        message:
            '${character.name} 需要权限「${permission.name}」才能继续：${request.reason}',
      );
    }

    final requiresApproval = requestApprovalPolicy == null
        ? approvalPolicy(request.tool)
        : await requestApprovalPolicy!(request);
    if (requiresApproval && !approved) {
      await _reportProgress(AgentRuntimeProgress(
        stage: AgentRuntimeProgressStage.waitingForApproval,
        executedRequests: executedRequests,
        pendingRequest: request,
        currentStepLabel: waitingApprovalLabel(
            request.tool.wireName, request.args['path']?.toString()),
      ));
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
      // 权限通过且非待批准：调 _execute 前上报「调用工具中」。
      await _reportProgress(AgentRuntimeProgress(
        stage: AgentRuntimeProgressStage.callingTool,
        executedRequests: executedRequests,
        currentStepLabel: callingToolLabel(request.tool.wireName),
      ));
      toolResult = await _execute(
        request,
        character,
        allowSensitiveRead: approved,
        executedRequests: executedRequests,
      ).timeout(toolExecutionTimeout);
    } catch (e) {
      // 工具执行抛错：上报「步骤失败」，reason 取异常首行（简短中文/英文）。
      await _reportProgress(AgentRuntimeProgress(
        stage: AgentRuntimeProgressStage.stepFailed,
        executedRequests: executedRequests,
        currentStepLabel: stepFailedLabel(e.toString().split('\n').first),
      ));
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
    await _reportProgress(AgentRuntimeProgress(
      stage: AgentRuntimeProgressStage.toolCompleted,
      executedRequests: nextExecutedRequests,
      publicDetail: _toolResultPublicDetail(toolResult),
    ));
    if (shouldCancel?.call() == true) {
      return AgentRuntimeResult(
        status: AgentRuntimeStatus.failed,
        pendingToolRequest: request,
        toolResult: toolResult,
        executedToolRequests: nextExecutedRequests,
        message: '工作模式已关闭，任务已在当前工具完成后安全中止。',
      );
    }
    // A path grant or sensitive-read checkpoint is a distinct user boundary.
    // Keep the original request pending so the coordinator can resume it with
    // the same conversation context after the user completes that boundary.
    if (toolResult['requiresApproval'] == true ||
        toolResult['requiresFolderGrant'] == true) {
      await _reportProgress(AgentRuntimeProgress(
        stage: AgentRuntimeProgressStage.waitingForApproval,
        executedRequests: executedRequests,
        pendingRequest: request,
        currentStepLabel: waitingApprovalLabel(
          request.tool.wireName,
          request.args['path']?.toString(),
        ),
      ));
      return AgentRuntimeResult(
        status: AgentRuntimeStatus.waitingForApproval,
        pendingToolRequest: request,
        toolResult: toolResult,
        executedToolRequests: executedRequests,
        message: toolResult['requiresFolderGrant'] == true
            ? '需要先授权请求的工作目录，授权后将继续当前步骤。'
            : '该读取涉及敏感文件，需要你批准后继续。',
      );
    }
    return _continueAfterToolResult(
      character: character,
      request: request,
      userRequest: userRequest,
      toolResult: toolResult,
      remainingSteps: remainingSteps - 1,
      executedRequests: nextExecutedRequests,
      conversationHistory: conversationHistory,
    );
  }

  Future<void> _reportProgress(AgentRuntimeProgress progress) async {
    if (shouldCancel?.call() == true) return;
    // 去抖：连续同 stage 且同 label 的上报只保留一次气泡重写，
    // 避免生成文件续写循环等高频 thinking 上报引发的视觉抖动。
    final sameAsLast = _lastReportedStage == progress.stage &&
        _lastReportedLabel == progress.currentStepLabel &&
        _lastReportedExecutedCount == progress.executedRequests.length;
    _lastReportedStage = progress.stage;
    _lastReportedLabel = progress.currentStepLabel;
    _lastReportedExecutedCount = progress.executedRequests.length;
    if (sameAsLast) return;

    // P2：仅在步切换（stage/label 变化）时，为本次上报注入时间戳，
    // 不改动约 18 处 _reportProgress(...) 调用点，降低回归风险。
    // runStartedAtMs 由实例字段统一透传（所有上报都携带），
    // currentStepStartedAtMs 每次切步重置（P2 仅注入、不展示）。
    final augmented = AgentRuntimeProgress(
      stage: progress.stage,
      executedRequests: progress.executedRequests,
      pendingRequest: progress.pendingRequest,
      currentStepLabel: progress.currentStepLabel,
      publicDetail: progress.publicDetail,
      runStartedAtMs: _runStartedAtMs,
      currentStepStartedAtMs: DateTime.now().millisecondsSinceEpoch,
    );

    final handler = onProgress;
    if (handler == null) return;
    try {
      await handler(augmented);
    } catch (_) {
      // 检查点失败不能抹掉已经完成的本地工具结果。
    }
  }

  String? _toolResultPublicDetail(Map<String, dynamic> result) {
    final path = result['path'];
    final pathText = path is String ? path.trim() : '';
    if (result['ok'] == true) {
      if (pathText.isNotEmpty) return '工具已完成：${_shortToolPath(pathText)}';
      final validation = result['validation'];
      if (validation is Map && validation['valid'] == true) {
        return '工具已完成，校验通过。';
      }
      return '工具已完成。';
    }
    final exitCode = result['exitCode'];
    if (exitCode is num) return '工具返回退出码 ${exitCode.toInt()}。';
    final errorCode = result['error']?.toString().trim();
    if (errorCode != null && errorCode.isNotEmpty) {
      return '工具未完成：${errorCode.length <= 120 ? errorCode : '${errorCode.substring(0, 119)}…'}';
    }
    return null;
  }

  String _shortToolPath(String path) {
    final normalized = path.replaceAll('\\', '/');
    if (normalized.startsWith('/') ||
        RegExp(r'^[A-Za-z]:/').hasMatch(normalized)) {
      return normalized.split('/').last;
    }
    return normalized;
  }

  Future<AgentRuntimeResult> _continueAfterToolResult({
    required AICharacter character,
    required ToolRequest request,
    required String userRequest,
    required Map<String, dynamic> toolResult,
    required int remainingSteps,
    required List<ToolRequest> executedRequests,
    List<Map<String, dynamic>>? conversationHistory,
  }) async {
    if (shouldCancel?.call() == true) {
      return AgentRuntimeResult(
        status: AgentRuntimeStatus.failed,
        pendingToolRequest: request,
        toolResult: toolResult,
        executedToolRequests: executedRequests,
        message: '工作模式已关闭，任务已安全中止。',
      );
    }
    // 用户拒绝（skipRejectedTool 注入 skipped:true）时上报「已取消」。
    if (toolResult['skipped'] == true) {
      await _reportProgress(AgentRuntimeProgress(
        stage: AgentRuntimeProgressStage.stepRejected,
        executedRequests: executedRequests,
        currentStepLabel: stepRejectedLabel(request.tool.wireName),
      ));
    }
    if (request.tool == AgentToolName.workspacePatch &&
        toolResult['ok'] == true &&
        _toolResultValidated(toolResult) &&
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
      rolePlaySystemPrompt: character.rolePlaySystemPrompt,
      userRequest: userRequest,
      toolName: request.tool.wireName,
      toolResult: toolResult,
    );
    late final Map<String, dynamic> finalResponse;
    try {
      // 整理工具结果 LLM 调用前上报「思考中（整理工具结果）」。
      await _reportProgress(AgentRuntimeProgress(
        stage: AgentRuntimeProgressStage.thinking,
        executedRequests: executedRequests,
        currentStepLabel: thinkingLabel('整理工具结果'),
      ));
      finalResponse = await _completeWithRetry(character, [
        {'role': 'system', 'content': finalPrompt},
        // 追加对话历史，使 LLM 在整理结果时拥有上下文（修复追问失忆）。
        ...?conversationHistory,
      ]);
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

    if (shouldCancel?.call() == true) {
      return AgentRuntimeResult(
        status: AgentRuntimeStatus.failed,
        pendingToolRequest: request,
        toolResult: toolResult,
        executedToolRequests: executedRequests,
        message: '工作模式已关闭，任务已安全中止。',
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
    // The legacy bridge reports command-style exitCode=0 for full-file writes,
    // but Stage 02 rename/delete responses are authoritative only through
    // their boolean `ok` field. Never let a contradictory exitCode mask a
    // failed destructive mutation.
    final currentMutationSucceeded =
        request.tool == AgentToolName.workspacePatch
            ? toolResult['ok'] == true || toolResult['exitCode'] == 0
            : toolResult['ok'] == true;
    if (_isWorkspaceMutationTool(request.tool) &&
        !currentMutationSucceeded &&
        // 用户明确拒绝（skipped）不算写失败。
        toolResult['skipped'] != true) {
      final detail = toolResult['message']?.toString().trim().isNotEmpty == true
          ? toolResult['message'].toString().trim()
          : toolResult['error']?.toString().trim().isNotEmpty == true
              ? toolResult['error'].toString().trim()
              : '本地写入工具未返回成功状态';
      return AgentRuntimeResult(
        status: AgentRuntimeStatus.failed,
        pendingToolRequest: request,
        toolResult: toolResult,
        executedToolRequests: executedRequests,
        message: '${character.name} 文件变更未成功：$detail。'
            '工具写入未成功，因此没有可交付附件。',
      );
    }
    // 多步骤任务（例如先 skill.create，再生成页面）也可能在后续回复里直接
    // 吐出裸 HTML/代码。与首轮规划保持同一恢复策略，把现成内容继续转换为
    // workspace.patch，不能只用“请查看附件”护栏吞掉正文却没有真正创建文件。
    final nextRequest = AgentProtocolParser.parse(content) ??
        _recoverGeneratedFileRequest(userRequest, content, revisionTargetPath);
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
        remainingSteps: remainingSteps,
        executedRequests: executedRequests,
        conversationHistory: conversationHistory,
      );
    }

    // 生成文件的任务必须以真实 workspace.patch 作为完成门禁。
    // 典型反例：skill.create 成功后，模型直接说“页面已生成，
    // 请查看附件”，但实际从未写文件。此时尝试恢复出真实写入
    // 请求；无法恢复时明确失败，绝不用口头承诺冒充交付。
    final expectedFilePath = _generatedFilePath(userRequest);
    final hasExecutedFileWrite = executedRequests.any(
      (executed) => executed.tool == AgentToolName.workspacePatch,
    );
    if (expectedFilePath != null &&
        !hasExecutedFileWrite &&
        // 用户明确拒绝写文件后，不再强制恢复出真实写入请求，避免"拒绝后又被
        // 强制再写一次"或与 skip 契约（拒绝后可继续完成安全剩余工作）冲突。
        toolResult['skipped'] != true) {
      final fallbackRequest = await _fallbackFileRequestAfterPlanningFailure(
        character: character,
        userRequest: userRequest,
        conversationHistory: conversationHistory,
        executedRequests: executedRequests,
      );
      if (fallbackRequest != null) {
        return _handleToolRequest(
          character: character,
          request: fallbackRequest,
          userRequest: userRequest,
          approved: false,
          remainingSteps: remainingSteps,
          executedRequests: executedRequests,
          conversationHistory: conversationHistory,
        );
      }
      return AgentRuntimeResult(
        status: AgentRuntimeStatus.failed,
        pendingToolRequest: request,
        toolResult: toolResult,
        executedToolRequests: executedRequests,
        message: '${character.name} 未能写入用户要求的文件 '
            '`$expectedFilePath`；当前只完成了 ${request.tool.wireName}，'
            '因此没有可交付附件。请重试。',
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
      toolResult: toolResult,
      executedToolRequests: executedRequests,
      message: finalMessage,
    );
  }

  bool _isWorkspaceMutationTool(AgentToolName tool) =>
      tool == AgentToolName.workspacePatch ||
      tool == AgentToolName.workspaceRename ||
      tool == AgentToolName.workspaceDelete;

  static bool _requiresPostWriteTool(String userRequest) {
    final lower = userRequest.toLowerCase();
    final hasValidationIntent = RegExp(
      r'(运行|执行|测试|验证|检查|构建|编译|flutter\s+(?:test|analyze|build)|'
      r'\btest\b|\banalyze\b|\bbuild\b|command\.run|terminal)',
      caseSensitive: false,
    ).hasMatch(lower);
    if (!hasValidationIntent) return false;
    return !RegExp(
      r'(?:不要|无需|不需要|不用|不必|不运行|不执行|不做|先不)\s*'
      r'(?:再|去|进行|执行|跑|运行)?\s*(?:flutter\s+)?'
      r'(?:test|build|analyze|compile|测试|构建|编译|检查|验证)',
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
    if (!_hasPermission(character, permission)) {
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
      remainingSteps: toolStepLimit,
      executedRequests: priorExecutedRequests,
      conversationHistory: conversationHistory,
    );
  }

  /// Replays a tool that was paused only because its requested folder was not
  /// authorized. Folder consent is narrower than ordinary tool approval, so
  /// the request re-enters the normal approval policy: non-sensitive reads can
  /// continue immediately, while sensitive reads and mutations still pause.
  Future<AgentRuntimeResult> resumeAfterFolderGrant({
    required AICharacter character,
    required ToolRequest request,
    required String userRequest,
    List<ToolRequest> priorExecutedRequests = const [],
    List<Map<String, dynamic>>? conversationHistory,
  }) {
    return _handleToolRequest(
      character: character,
      request: request,
      userRequest: userRequest,
      approved: false,
      remainingSteps: toolStepLimit,
      executedRequests: priorExecutedRequests,
      conversationHistory: conversationHistory,
    );
  }

  /// Continues planning after the user explicitly declines one sensitive
  /// operation. The rejected request is not executed and does not count as a
  /// completed operation, but the model receives a structured skip result so
  /// it can finish any safe remaining work.
  Future<AgentRuntimeResult> skipRejectedTool({
    required AICharacter character,
    required ToolRequest request,
    required String userRequest,
    List<ToolRequest> priorExecutedRequests = const [],
    List<Map<String, dynamic>>? conversationHistory,
  }) =>
      _continueAfterToolResult(
        character: character,
        request: request,
        userRequest: userRequest,
        toolResult: {
          'ok': false,
          'skipped': true,
          'reason': '用户拒绝了该敏感操作',
        },
        remainingSteps: toolStepLimit - 1,
        executedRequests: priorExecutedRequests,
        conversationHistory: conversationHistory,
      );

  static ToolPermission permissionForTool(AgentToolName tool) {
    return switch (tool) {
      AgentToolName.workspaceList => ToolPermission.workspaceRead,
      AgentToolName.workspaceRead => ToolPermission.workspaceRead,
      AgentToolName.workspaceSearch => ToolPermission.workspaceRead,
      AgentToolName.workspaceDocument => ToolPermission.workspaceRead,
      AgentToolName.workspacePatch => ToolPermission.workspacePatch,
      AgentToolName.workspaceRename => ToolPermission.workspacePatch,
      AgentToolName.workspaceDelete => ToolPermission.workspacePatch,
      AgentToolName.commandRun => ToolPermission.commandRun,
      AgentToolName.browserContext => ToolPermission.browserContext,
      AgentToolName.skillCreate => ToolPermission.skillCreate,
      AgentToolName.skillDownload => ToolPermission.skillDownload,
    };
  }

  bool _hasPermission(AICharacter character, ToolPermission permission) =>
      grantedPermissions?.contains(permission) ??
      character.toolPermissions.contains(permission);

  static bool requiresApproval(AgentToolName tool) {
    return switch (tool) {
      AgentToolName.workspaceList => false,
      AgentToolName.workspaceRead => false,
      AgentToolName.workspaceSearch => false,
      AgentToolName.workspaceDocument => false,
      AgentToolName.workspacePatch => true,
      AgentToolName.workspaceRename => true,
      AgentToolName.workspaceDelete => true,
      AgentToolName.commandRun => true,
      AgentToolName.browserContext => true,
      AgentToolName.skillCreate => true,
      AgentToolName.skillDownload => true,
    };
  }

  Future<Map<String, dynamic>> _execute(
    ToolRequest request,
    AICharacter character, {
    bool allowSensitiveRead = false,
    List<ToolRequest> executedRequests = const [],
  }) async {
    final executor = AgentToolExecutor(
      workspace: workspaceFileTool,
      browser: browserContextTool,
      createSkill: skillCreateHandler,
      downloadSkill: skillDownloadHandler,
    );
    return executor.execute(
      request,
      allowSensitiveRead: allowSensitiveRead,
      patchWorkspace: () => _executeWorkspacePatch(
        request,
        allowCommandValidation: (allowCommandValidation ?? true) &&
            _hasPermission(character, ToolPermission.commandRun),
        executedRequests: executedRequests,
      ),
      onReadStarted: (path) async {
        await _reportProgress(AgentRuntimeProgress(
          stage: AgentRuntimeProgressStage.readingFile,
          executedRequests: executedRequests,
          currentStepLabel: readingFileLabel(path),
        ));
      },
    );
  }

  /// 执行 workspace.patch（写文件）：先调用桥接服务 `/workspace/write` 落盘，
  /// 成功后再同步读回刚写入的文件全文，附加到返回结果里（key: [readbackContent]）。
  /// 读回内容仅用于生成「文件已生成」确认信息中的文件大小估算，**不会**回写进
  /// 聊天消息文本（文件另以 MediaAttachment 文件卡片完整展示）。
  ///
  /// 写成功但读回失败时降级处理：仅返回写结果、不附加预览，也不把异常暴露给用户
  /// —— 写文件这一核心动作已成功，不应因读回失败而被判定为整次工具执行失败。
  Future<Map<String, dynamic>> _executeWorkspacePatch(
    ToolRequest request, {
    required bool allowCommandValidation,
    List<ToolRequest> executedRequests = const [],
  }) async {
    final rawPath = request.args['path'] as String? ?? '';
    var path = _normalizeWorkspaceWritePath(rawPath);
    if (path.isEmpty) {
      return {'ok': false, 'error': 'empty_path', 'message': '缺少有效的文件路径'};
    }
    final hasPatchField = request.args['expectedSha256'] != null ||
        request.args['expectedFragment'] != null ||
        request.args['replacement'] != null;
    final isExactPatch = request.args['expectedSha256'] is String &&
        request.args['expectedFragment'] is String &&
        request.args['replacement'] is String;
    if (hasPatchField && !isExactPatch) {
      return {
        'ok': false,
        'error': 'invalid_patch',
        'message': '补丁请求缺少原 SHA-256、原文片段或替换文本。',
      };
    }
    String? binaryDowngradedFrom;
    if (!isExactPatch && _requiresBinaryArtifactWriter(path)) {
      // 系统只能写文本文件，无法直接生成 PDF/Word 等二进制文档。
      // 优雅降级：把二进制扩展名改写为 .md 继续落盘（内容以 Markdown 文本保存），
      // 避免「用户要一份 PDF 报告」的任务整体 failed。改写后仍是一次成功的文本
      // 写入，文件交付门禁得以正常通过，并会在交付信息里标注降级来源。
      final mdPath = _rewriteBinaryPathToMarkdown(
        path,
        allowAbsolutePath: workspaceFileTool?.acceptsAbsolutePaths == true,
      );
      if (mdPath == null) {
        return {
          'ok': false,
          'error': 'binary_artifact_not_supported',
          'message': '当前 workspace.patch 只能写入文本文件，'
              '不能生成 PDF/Word 等二进制文档。'
              '请改为 Markdown/HTML，或先配置专用的二进制导出工具',
        };
      }
      binaryDowngradedFrom = path;
      path = mdPath;
    }
    // 旧桥接器以及明确的新建追问在文件冲突时自动改用递增后缀；
    // 普通 Stage 02 修订则必须保留精确路径，让批准的 create/modify
    // 计划决定结果。
    //   a) 静默覆盖导致用户丢失之前的内容
    //   b) 直接拒绝导致工具执行失败、LLM 回退到代码泄漏路径
    // 改名格式：page.html → page_2.html
    final stage02FileTool = workspaceFileTool?.acceptsAbsolutePaths == true;
    final modelRequestedOverwrite = request.args['overwrite'] == true;
    if (!isExactPatch &&
        (!stage02FileTool || autoRenameIfExists) &&
        (!modelRequestedOverwrite || autoRenameIfExists) &&
        await _workspaceFileExists(path)) {
      // A new-file follow-up owns the collision policy; a model cannot turn
      // that explicit request into a silent overwrite by setting overwrite.
      path = await _nextAvailableWorkspacePath(path);
    }
    if (path.isEmpty) {
      return {
        'ok': false,
        'error': 'no_available_path',
        'message': '目标文件名冲突过多，未找到可用的新文件名',
      };
    }
    // 路径规范化后、写之前上报「写入文件中」。
    await _reportProgress(AgentRuntimeProgress(
      stage: AgentRuntimeProgressStage.writingFile,
      executedRequests: executedRequests,
      currentStepLabel: writingFileLabel(path),
    ));
    final writeResult = isExactPatch
        ? await _workspaceFileTool.applyPatch(
            jsonEncode({
              'path': path,
              'expectedSha256': request.args['expectedSha256'],
              'expectedFragment': request.args['expectedFragment'],
              'replacement': request.args['replacement'],
            }),
          )
        : await _writeWorkspaceContent(request, path);
    if (writeResult['ok'] != true) return writeResult;
    // 写成功后上报「已创建文件」。
    await _reportProgress(AgentRuntimeProgress(
      stage: AgentRuntimeProgressStage.fileCreated,
      executedRequests: executedRequests,
      currentStepLabel: fileCreatedLabel(path),
    ));
    try {
      final persistedPath = writeResult['path'] is String &&
              (writeResult['path'] as String).trim().isNotEmpty
          ? (writeResult['path'] as String).trim()
          : path;
      // A successful write to a sensitive filename must not be echoed back to
      // the cloud model during the normal readback/validation pass. The
      // mutation itself is already covered by the write approval; reporting a
      // local success marker preserves delivery evidence without disclosing
      // the file body or creating an automatic chat attachment.
      final sensitiveWrite = writeResult['sensitive'] == true ||
          workspaceFileTool?.isSensitivePath(persistedPath) == true;
      if (sensitiveWrite) {
        await _reportProgress(AgentRuntimeProgress(
          stage: AgentRuntimeProgressStage.validating,
          executedRequests: executedRequests,
          currentStepLabel: validatingLabel(persistedPath),
        ));
        // FR-03 still requires a post-write check for sensitive files. Read
        // the file only inside the local adapter and discard the body before
        // constructing the tool result, so the cloud model never receives a
        // secret while the app still has concrete delivery evidence.
        final readbackVerified = await _verifySensitiveWrite(persistedPath);
        if (!readbackVerified) {
          return {
            ...writeResult,
            'ok': false,
            'sensitive': true,
            'readbackVerified': false,
            'error': 'readback_unverified',
            'validation': {
              'valid': false,
              'message': '敏感文件已写入，但无法在本地重新读取验证。',
            },
            'message': '敏感文件已写入，但无法在本地重新读取验证；任务不会静默标记完成。',
          };
        }
        return {
          ...writeResult,
          'sensitive': true,
          'readbackVerified': true,
          'validation': {
            'valid': true,
            'message': '敏感文件已写入并完成本地回读校验；正文未回传模型。',
          },
        };
      }
      // 读回刚写入的文件前，先上报「读取文件中」阶段，避免用户看到
      // fileCreated → validating 的跳变。该 stage 与 fileCreated 不同，去抖不会吞掉。
      await _reportProgress(AgentRuntimeProgress(
        stage: AgentRuntimeProgressStage.readingFile,
        executedRequests: executedRequests,
        currentStepLabel: readingFileLabel(path),
      ));
      final readResult = await _workspaceFileTool.readWithOptions(
        path,
        allowSensitive: true,
      );
      final content = readResult['content'] as String?;
      if (content == null) {
        if (!stage02FileTool) {
          return {...writeResult, 'readbackVerified': false};
        }
        return {
          ...writeResult,
          'ok': false,
          'error': 'readback_unverified',
          'message': '文件已写入，但无法读回验证；任务不会静默标记完成。',
        };
      }
      final enriched = Map<String, dynamic>.from(writeResult);
      enriched['readbackContent'] = content;
      if (binaryDowngradedFrom != null) {
        enriched['downgradedFrom'] = binaryDowngradedFrom;
      }
      // 读回内容后、校验前上报「校验结果中」。
      await _reportProgress(AgentRuntimeProgress(
        stage: AgentRuntimeProgressStage.validating,
        executedRequests: executedRequests,
        currentStepLabel: validatingLabel(path),
      ));
      final validation = await FileValidator.validate(
        path,
        content,
        commandRunner:
            allowCommandValidation ? _workspaceFileTool.runCommand : null,
      );
      enriched['validation'] = validation.toJson();
      if (!validation.isValid) {
        enriched['ok'] = false;
        enriched['error'] = 'validation_failed';
        enriched['message'] = validation.message;
      }
      return enriched;
    } catch (error) {
      if (!stage02FileTool) {
        return {...writeResult, 'readbackVerified': false};
      }
      return {
        ...writeResult,
        'ok': false,
        'error': 'readback_unverified',
        'message': '文件已写入，但读取或校验失败：${error.toString().split('\n').first}',
      };
    }
  }

  Future<Map<String, dynamic>> _writeWorkspaceContent(
    ToolRequest request,
    String path,
  ) async {
    final content = request.args['content'];
    if (content is! String) {
      return {
        'ok': false,
        'error': 'missing_content',
        'message': '写文件请求缺少完整内容，未执行写入。',
      };
    }
    return _workspaceFileTool.write(path, content);
  }

  Future<bool> _verifySensitiveWrite(String path) async {
    try {
      final readback = await _workspaceFileTool.readWithOptions(
        path,
        allowSensitive: true,
      );
      if (readback['ok'] == false) return false;
      return readback['ok'] == true || readback['content'] is String;
    } on Object {
      return false;
    }
  }

  bool _toolResultValidated(Map<String, dynamic> result) {
    final validation = result['validation'];
    if (validation is Map) return validation['valid'] == true;
    // Compatibility responses from the localhost bridge predate structured
    // validation. Stage 02 always includes validation and therefore never
    // reaches this fallback.
    return workspaceFileTool?.acceptsAbsolutePaths != true;
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
      // The legacy bridge accepts only workspace-relative paths, while the
      // Stage 02 in-process adapter deliberately preserves an explicitly
      // authorized absolute path. Do not reject a safe sibling candidate just
      // because the compatibility guard cannot classify absolute paths.
      final acceptsAbsolute = workspaceFileTool?.acceptsAbsolutePaths == true;
      if (!acceptsAbsolute &&
          !WorkspacePathGuard.isSafeRelativePath(candidate)) {
        return '';
      }
      if (!await _workspaceFileExists(candidate)) return candidate;
    }
    return '';
  }

  String _normalizeWorkspaceWritePath(String rawPath) {
    final tool = workspaceFileTool;
    if (tool?.acceptsAbsolutePaths == true) {
      // Stage 02 performs the final lexical, symlink and grant checks. Keep an
      // explicitly supplied absolute path intact so the model cannot be
      // redirected to a same-named file at the conversation root merely by
      // crossing the legacy bridge compatibility boundary.
      return rawPath.trim().replaceAll('\\', '/');
    }
    return WorkspacePathGuard.normalizeToRelative(rawPath);
  }

  static bool _requiresBinaryArtifactWriter(String path) {
    final extension = path.split('.').last.toLowerCase();
    return const {
      'pdf',
      'doc',
      'docx',
      'xls',
      'xlsx',
      'ppt',
      'pptx',
      'zip',
      'png',
      'jpg',
      'jpeg',
    }.contains(extension);
  }

  /// 把二进制文档路径改写为等效的 Markdown 文本路径（优雅降级用）。
  /// 例：`report.pdf` → `report.md`、`docs/summary.docx` → `docs/summary.md`。
  /// 改写结果仍须是安全相对路径，否则返回 null（交由上层按不支持处理）。
  static String? _rewriteBinaryPathToMarkdown(
    String path, {
    bool allowAbsolutePath = false,
  }) {
    final slashIndex = path.lastIndexOf('/');
    final dir = slashIndex >= 0 ? path.substring(0, slashIndex + 1) : '';
    final fileName = slashIndex >= 0 ? path.substring(slashIndex + 1) : path;
    final dotIndex = fileName.lastIndexOf('.');
    final base = dotIndex > 0 ? fileName.substring(0, dotIndex) : fileName;
    final md = '$dir$base.md';
    return allowAbsolutePath || WorkspacePathGuard.isSafeRelativePath(md)
        ? md
        : null;
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

  ToolRequest? _safeLocalFallbackFileRequest(
    AICharacter character,
    String userRequest,
  ) {
    final request = _localFileGenerationRequest(character, userRequest);
    if (request == null) return null;
    final path = request.args['path'] as String? ?? '';
    final ext = path.split('.').last.toLowerCase();
    final isTechnicalMarkdown = (ext == 'md' || ext == 'markdown') &&
        RegExp(r'(技术文档|项目|工程|报告|总结|readme)', caseSensitive: false)
            .hasMatch(userRequest);
    // 只保留确实有可运行/可解析本地模板的类型。其余扩展名以前会写入
    // “Agentic Live Test”说明页，造成非空但不可运行的伪代码附件。
    const deterministicTemplateExtensions = {
      'dart',
      'java',
      'sh',
      'bash',
      'c',
      'cc',
      'cpp',
      'h',
      'hpp',
      'json',
    };
    return isTechnicalMarkdown || deterministicTemplateExtensions.contains(ext)
        ? request
        : null;
  }

  /// 模糊推断文件名：当关键词命中但用户未给出具体文件名时，
  /// 从消息中提取文件类型提示词（如“html 文件”“一个 md”“json 文件”），
  /// 并结合内容语义生成一个安全的相对文件名（如 `star_scene.html`、`report.md`）。
  ///
  /// 返回 null 表示未识别出任何文件生成意图（不应触发工具请求）。
  String? _inferWorkspaceFilePath(String text) {
    const supported =
        r'html|html5|md|markdown|dart|java|txt|text|json|yaml|yml|svg|css|js|ts|py|sh|bash|c|cpp|cc|h|hpp|pdf|doc|docx|ppt|pptx|csv|sql|log|png|jpe?g|zip';
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
        r'(?:一个?)?\s*(html|html5|md|markdown|dart|java|txt|json|yaml|yml|svg|css|js|ts|py|sh|bash|pdf|doc|docx|ppt|pptx|csv|sql|log|png|jpe?g|zip)(?![a-zA-Z0-9_])',
        caseSensitive: false,
      ).firstMatch(text);
      ext = bare == null ? null : _normalizeExt(bare.group(1)!);
      if (ext == null && (lowerContainsScript(text))) {
        ext = 'sh';
      }
      if (ext == null &&
          RegExp(r'(c\+\+|cpp|\bcxx\b|c/c\+\+)').hasMatch(text.toLowerCase())) {
        ext = 'cpp';
      }
      if (ext == null &&
          RegExp(r'(^|[^a-z])c\s*语言').hasMatch(text.toLowerCase())) {
        ext = 'c';
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
    } else if (ext == 'java') {
      name = 'Main';
    } else if (ext == 'sh') {
      if (lower.contains('检查') ||
          lower.contains('验证') ||
          lower.contains('test') ||
          lower.contains('check')) {
        name = 'run_checks';
      } else {
        name = 'script';
      }
    } else if (const {'c', 'cc', 'cpp', 'h', 'hpp'}.contains(ext)) {
      if (lower.contains('系统信息') ||
          lower.contains('系统的信息') ||
          lower.contains('cpu') ||
          lower.contains('内存') ||
          lower.contains('memory')) {
        name = 'system_resource_monitor';
      } else {
        name = 'main';
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
      r'(?<![\w./\\-])([\w][\w./\\-]*\.(?:md|markdown|dart|java|txt|json|yaml|yml|svg|html|css|js|ts|py|sh|bash|c|cc|cpp|h|hpp|pdf|doc|docx))(?![\w./\\-])',
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
    if (extension == 'java') {
      return '''
public class Main {
  public static void main(String[] args) {
    System.out.println("Hello");
  }
}
''';
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
2. 用户显式开启工作模式后进入工具链路。
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
    final ok = (toolResult['ok'] == true || toolResult['exitCode'] == 0) &&
        _toolResultValidated(toolResult);
    if (!ok) return null;
    final path = toolResult['path'] as String?;
    final summary = path == null || path.isEmpty
        ? '${character.name} 已生成文件，请查看附件。'
        : '${character.name} 已生成文件 `$path`，请查看附件。';
    // 写文件成功后，把「文件已生成」简洁确认信息追加到兜底消息（内容不回写文本）。
    return AgentRuntimeResult(
      status: AgentRuntimeStatus.completed,
      toolResult: toolResult,
      executedToolRequests: executedRequests,
      message: _appendFilePreview(summary, toolResult),
    );
  }
}

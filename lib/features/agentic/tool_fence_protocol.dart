import 'dart:convert';

import 'tool_request.dart';

/// 一条围栏块在协议上的分类。
enum ToolFenceKind {
  /// 普通代码 / 数据块：按聊天正文渲染。
  code,

  /// 声明了工具调用且 payload 可用：执行它，绝不打印。
  request,

  /// 声明了工具调用但 payload 不可用：隐藏并报协议错误。
  malformedTool,
}

/// 围栏块分类结果。
class ToolFenceVerdict {
  const ToolFenceVerdict.code()
      : kind = ToolFenceKind.code,
        request = null,
        repairableJson = false;

  const ToolFenceVerdict.malformedTool({this.repairableJson = false})
      : kind = ToolFenceKind.malformedTool,
        request = null;

  const ToolFenceVerdict.request(this.request)
      : kind = ToolFenceKind.request,
        repairableJson = false;

  final ToolFenceKind kind;
  final ToolRequest? request;
  final bool repairableJson;
}

/// 「这段围栏内容是不是工具调用协议」的唯一判据。
///
/// 这里曾经有两份实现：流式扫描器（`network_reply_scanner.dart`）判"能不能
/// 执行"，提交层清洗（`agentic_reply_utils.dart`）判"要不要隐藏"。两份都从
/// label 和 payload 猜同一件事，结论却会漂移——最典型的是 `function_call`
/// 标签：提交层认得它是工具调用、会隐藏，流式侧不认，于是同一段内容在流式
/// 通道里被当代码块贴出来，在非流式通道里被隐藏。判据只有这一份，两条流程
/// 各自保留（流式要边扫边吐，提交层要一次性清洗全文）。
class ToolFenceProtocol {
  const ToolFenceProtocol._();

  /// 声明工具调用的标签前缀。`agent`/`tool`/`function` 开头即视为声明——
  /// 模型会把标签写成 `tool_calls`、`tools`、`agent_tool` 等多种形态。
  static const List<String> labelPrefixes = ['agent', 'tool', 'function'];

  /// payload 里出现这些键即视为"在点名某个工具"。
  static const List<String> toolKeys = [
    'tool',
    'tool_name',
    'toolName',
    'toolname',
  ];

  static const Set<String> _envelopeKeys = {
    'tool',
    'tool_name',
    'toolName',
    'toolname',
    'name',
    'reason',
    'why',
    'args',
    'arguments',
    'parameters',
    'input',
  };

  /// 分类一个围栏块的内容（不含 ``` 标记）。
  static ToolFenceVerdict parse(String inner) {
    final trimmed = inner.trim();
    if (trimmed.isEmpty) return const ToolFenceVerdict.code();
    // A newline immediately after the opening fence denotes an unlabeled
    // code block. Its first identifier must never be interpreted as a label.
    if (RegExp(r'^[ \t]*\r?\n').hasMatch(inner) && !trimmed.startsWith('{')) {
      return const ToolFenceVerdict.code();
    }
    // Preserve the full label so protocol variants agree across both callers.
    var label = '';
    var body = trimmed;
    final match =
        RegExp(r'^([A-Za-z_][A-Za-z0-9_-]*)(?=\s|\{|$)').firstMatch(trimmed);
    if (match != null) {
      label = match.group(1)!.toLowerCase();
      body = trimmed.substring(match.end).trim();
    }
    final declaresTool = declaresToolLabel(label);
    // Only unlabeled JSON and json fences support implicit tool envelopes.
    if (label.isNotEmpty && label != 'json' && !declaresTool) {
      return const ToolFenceVerdict.code();
    }

    if (!body.startsWith('{')) {
      // 协议标签后面跟散文：不是代码示例，但也说不清本意，按坏请求处理。
      return declaresTool
          ? const ToolFenceVerdict.malformedTool()
          : const ToolFenceVerdict.code();
    }

    final decoded = decodeJsonObject(body);
    if (decoded == null) {
      // 解析不了的 body：带协议标签、或 payload 自己点名工具的，属于协议失败；
      // 其余当作（可能被截断的）代码示例。
      final toolish = declaresTool || body.contains('"tool"');
      return toolish
          ? const ToolFenceVerdict.malformedTool(repairableJson: true)
          : const ToolFenceVerdict.code();
    }
    final hasToolKey = toolKeys.any(decoded.containsKey);
    if (!hasToolKey && !declaresTool) {
      // 普通 JSON 示例（配置、API 载荷…）：保持可见。
      return const ToolFenceVerdict.code();
    }
    return buildRequest(decoded);
  }

  /// 标签本身是否声明了工具调用。
  static bool declaresToolLabel(String label) {
    final value = label.trim().toLowerCase();
    if (value.isEmpty) return false;
    return labelPrefixes.any(value.startsWith);
  }

  /// 文本里是否出现任何工具协议标记。
  static bool containsProtocolMarker(String text) {
    final lower = text.toLowerCase();
    return lower.contains('agent_tool') ||
        lower.contains('tool_call') ||
        lower.contains('function_call') ||
        lower.contains('"tool"');
  }

  /// 从已解码的 payload 构造请求，容忍模型实际写出的几种形状：
  /// `web_search`、`web.search`、`args` 与扁平参数。
  ///
  /// 只有已经看起来像工具调用的 payload 才会走到这里，所以构造失败一律是协议
  /// 失败——绝不能成为"把 payload 当正文打印"的理由。
  static ToolFenceVerdict buildRequest(Map<String, dynamic> json) {
    final rawName = (json['tool'] ??
            json['tool_name'] ??
            json['toolName'] ??
            json['toolname'] ??
            json['name'] ??
            '')
        .toString();
    final tool = resolveToolName(rawName);
    if (tool == null) {
      return const ToolFenceVerdict.malformedTool();
    }
    final rawArgs = json['args'] ??
        json['arguments'] ??
        json['parameters'] ??
        json['input'];
    final args = rawArgs is Map
        ? Map<String, dynamic>.from(rawArgs)
        // 没有信封：剩下的顶层键就是参数（`{"tool":"web_search","query":"…"}`
        // 是真实回复的形态）。
        : <String, dynamic>{
            for (final entry in json.entries)
              if (!_envelopeKeys.contains(entry.key)) entry.key: entry.value,
          };
    normalizeArgs(tool, args);
    if (!hasRequiredArgs(tool, args)) {
      return const ToolFenceVerdict.malformedTool();
    }
    return ToolFenceVerdict.request(ToolRequest(
      tool: tool,
      reason: (json['reason'] ?? json['why'] ?? '').toString(),
      args: args,
    ));
  }

  /// 把模型漂移出来的写法映射到标准 wire 名。
  static AgentToolName? resolveToolName(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return null;
    // `web_search` / `web-search` / `web search` → `web.search`
    final dotted = value.replaceAll(RegExp(r'[\s_-]+'), '.');
    for (final candidate in [value, dotted]) {
      final direct = AgentToolName.fromWire(candidate.toLowerCase());
      if (direct != null) return direct;
    }
    switch (value.toLowerCase().replaceAll(RegExp(r'[\s_.\-]+'), '')) {
      case 'websearch':
      case 'search':
      case 'searchengine':
      case 'googlesearch':
      case 'bingsearch':
        return AgentToolName.webSearch;
      case 'webread':
      case 'webfetch':
      case 'fetchpage':
        return AgentToolName.webRead;
      case 'webdownload':
        return AgentToolName.webDownload;
    }
    return null;
  }

  /// 用模型常用的别名补齐标准参数名。
  static void normalizeArgs(AgentToolName tool, Map<String, dynamic> args) {
    if (tool == AgentToolName.webSearch && args['query'] == null) {
      for (final alias in const ['q', 'keyword', 'keywords', 'searchQuery']) {
        final value = args.remove(alias);
        if (value is String && value.trim().isNotEmpty) {
          args['query'] = value;
          break;
        }
      }
    }
    if (tool == AgentToolName.webRead && args['sourceId'] == null) {
      final alias = args.remove('source_id') ?? args.remove('id');
      if (alias != null) args['sourceId'] = alias;
    }
    if (tool == AgentToolName.webRead && args['startSection'] is String) {
      final index = int.tryParse((args['startSection'] as String).trim());
      if (index != null) args['startSection'] = index;
    }
  }

  /// 缺必需参数的请求执行时会抛异常，按坏请求处理，不能当正文。
  static bool hasRequiredArgs(AgentToolName tool, Map<String, dynamic> args) {
    switch (tool) {
      case AgentToolName.webSearch:
        final query = args['query'];
        return query is String && query.trim().isNotEmpty;
      case AgentToolName.webRead:
        final sourceId = args['sourceId'];
        final section = args['startSection'];
        return sourceId is String &&
            sourceId.trim().isNotEmpty &&
            (section == null || section is int && section >= 0);
      case AgentToolName.webDownload:
        final sourceId = args['sourceId'];
        return sourceId is String && sourceId.trim().isNotEmpty;
      default:
        return true;
    }
  }

  /// 解析 JSON object，容忍前后噪音。
  ///
  /// 用括号配对而不是直接 `jsonDecode`：尾部多一句话、或少一个闭合括号，都不该
  /// 让整个对象变成"无法解析"。
  static Map<String, dynamic>? decodeJsonObject(String raw) {
    final text = raw.trim();
    if (!text.startsWith('{')) return null;
    var depth = 0;
    var inString = false;
    var escape = false;
    for (var index = 0; index < text.length; index++) {
      final char = text[index];
      if (inString) {
        if (escape) {
          escape = false;
        } else if (char == r'\') {
          escape = true;
        } else if (char == '"') {
          inString = false;
        }
        continue;
      }
      if (char == '"') {
        inString = true;
      } else if (char == '{') {
        depth++;
      } else if (char == '}') {
        depth--;
        if (depth == 0) {
          try {
            final decoded = jsonDecode(text.substring(0, index + 1));
            return decoded is Map<String, dynamic> ? decoded : null;
          } on FormatException {
            return null;
          }
        }
      }
    }
    return null;
  }
}

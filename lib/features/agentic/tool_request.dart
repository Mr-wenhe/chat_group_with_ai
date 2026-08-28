import 'dart:convert';

import 'package:chat_group/features/web_search/security/search_secret_scanner.dart';

enum AgentToolName {
  workspaceList('workspace.list'),
  workspaceRead('workspace.read'),
  workspacePatch('workspace.patch'),
  commandRun('command.run'),
  browserContext('browser.context'),
  skillCreate('skill.create'),
  skillDownload('skill.download');

  final String wireName;
  const AgentToolName(this.wireName);

  static AgentToolName? fromWire(String value) {
    for (final name in values) {
      if (name.wireName == value) return name;
    }
    return null;
  }
}

class ToolRequest {
  final AgentToolName tool;
  final String reason;
  final Map<String, dynamic> args;

  const ToolRequest({
    required this.tool,
    required this.reason,
    required this.args,
  });

  Map<String, dynamic> toJson() => {
        'tool': tool.wireName,
        'reason': reason,
        'args': args,
      };

  String toJsonString() => jsonEncode(toJson());

  static ToolRequest? fromJsonString(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final tool = AgentToolName.fromWire(decoded['tool']?.toString() ?? '');
      final args = decoded['args'];
      if (tool == null || args is! Map<String, dynamic>) return null;
      return ToolRequest(
        tool: tool,
        reason: decoded['reason']?.toString() ?? '',
        args: args,
      );
    } on FormatException {
      return null;
    }
  }

  static ToolRequest? tryParse(String content) {
    // 原有：```agent_tool ... ``` 围栏格式（prompt 推荐格式）
    var match = RegExp(
      r'```agent_tool\s*([\s\S]*?)\s*```',
    ).firstMatch(content);

    String? rawJson;
    if (match != null) {
      rawJson = match.group(1);
    } else {
      // 新增 fallback：<tool_call agent_tool ... </tool_call> / </agent_tool> XML 格式
      // 部分非原生 function-calling 模型会“自选”这种标签格式输出工具请求，
      // 若不兼容会导致工具请求既不被执行、又被原样泄露到聊天 UI。
      // 注：模型实际闭合标签为 </tool_call>，但也防御性兼容 </agent_tool> 变体。
      match = RegExp(
        r'<tool_call\s+agent_tool\s*([\s\S]*?)\s*(?:</agent_tool>|</tool_call>)',
      ).firstMatch(content);
      rawJson = match?.group(1);
    }

    // Bug 3 修复：兼容“<tool_call> ... {"tool":...} ... </tool_call>”变体——
    // 部分模型不把 agent_tool 放在开标签内，而是把 JSON 直接放在标签体内。
    // 该变体在上一轮修复后仍无法被 tryParse 识别，会被 sanitize 兜底隐藏、
    // 工具请求永不执行。这里补上对应匹配。
    //
    // 关键：开标签之后**不一定有字面 `>`**——真实模型常输出
    // `<tool_call {"tool":...}} </tool_call>`（空白后直接是 JSON）。
    // 因此开标签匹配需同时允许两种写法：
    //   - `<tool_call>`：走 `\s*>` 分支；
    //   - `<tool_call {"tool":...}`：走 `\s+` 分支，group1 正确捕获 JSON。
    // 由于本分支在 `<tool_call agent_tool ...>`（b 分支）之后才执行，二者不冲突。
    if (rawJson == null) {
      match = RegExp(
        r'<tool_call(?:\s*>|\s+)([\s\S]*?)(?:</agent_tool>|</tool_call>)',
      ).firstMatch(content);
      rawJson = match?.group(1);
    }

    if (rawJson == null) {
      final xmlish = _decodeFunctionCallParameters(content);
      if (xmlish != null) return xmlish;
      return null;
    }

    // 兼容格式变体：JSON 可能包裹在空白/前后噪声文本中，
    // 先整体解析，失败再提取第一个 {...} 块，提升对残缺格式的容忍度。
    final decoded = _decodeJsonObject(rawJson);
    if (decoded == null) {
      return _decodeFunctionCallParameters(rawJson) ??
          _decodeFunctionCallParameters(content);
    }

    final tool = AgentToolName.fromWire(decoded['tool'] as String? ?? '');
    final args = decoded['args'];
    if (tool == null || args is! Map<String, dynamic>) return null;
    return ToolRequest(
      tool: tool,
      reason: decoded['reason'] as String? ?? '',
      args: args,
    );
  }

  /// 兼容部分模型输出的非 JSON 工具协议：
  ///
  /// ```text
  /// <tool_call>
  /// <function_calls>
  /// <parameter name="path">foo.html</parameter>
  /// <parameter name="content"><!DOCTYPE html>...</parameter>
  /// ```
  ///
  /// 这类内容没有 `tool` 字段，但 path + content 语义明确等价于写文件。
  static ToolRequest? _decodeFunctionCallParameters(String raw) {
    final hasToolEnvelope = RegExp(
      r'<(?:function_calls|tool_call)\b',
      caseSensitive: false,
    ).hasMatch(raw);
    if (!hasToolEnvelope) {
      return null;
    }
    final params = <String, String>{};
    // 兼容两种参数写法：
    //   - <parameter name="path">...</parameter>（标准 XML 属性）
    //   - <parameter=path>...</parameter>（部分模型输出的等号简写）
    final pattern = RegExp(
      r'''<parameter(?:\s+name=["']([^"']+)["']|\s*=\s*([^>\s]+))\s*>([\s\S]*?)</parameter>''',
      caseSensitive: false,
    );
    for (final match in pattern.allMatches(raw)) {
      final name = (match.group(1) ?? match.group(2))?.trim();
      final value = match.group(3);
      if (name == null || name.isEmpty || value == null) continue;
      params[name] = _decodeXmlEntities(value.trim());
    }
    final path = params['path'];
    final content = params['content'];
    if (path == null || path.trim().isEmpty || content == null) return null;
    return ToolRequest(
      tool: AgentToolName.workspacePatch,
      reason: '模型请求写入文件 $path',
      args: {'path': path, 'content': content},
    );
  }

  static String _decodeXmlEntities(String value) {
    return value
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&amp;', '&');
  }

  /// 从工具调用原始文本中解析出 JSON 对象。
  ///
  /// 先尝试整体解析；若失败（例如 JSON 前后夹带说明文字），
  /// 再用括号配对提取第一个完整的 `{...}` 块解析（兼容嵌套结构，
  /// 不能用惰性的 `\{...?\}` 否则会在第一个 `}` 处提前截断）。
  /// 都不是合法 Map 则返回 null。
  static Map<String, dynamic>? _decodeJsonObject(String raw) {
    try {
      final direct = jsonDecode(raw.trim());
      if (direct is Map<String, dynamic>) return direct;
    } on FormatException {
      // 忽略，进入下面的兜底提取。
    }

    final start = raw.indexOf('{');
    if (start < 0) return null;
    var depth = 0;
    var inString = false;
    var escape = false;
    for (var i = start; i < raw.length; i++) {
      final ch = raw[i];
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
          final candidate = raw.substring(start, i + 1);
          try {
            final decoded = jsonDecode(candidate);
            if (decoded is Map<String, dynamic>) return decoded;
          } on FormatException {
            // 不是合法 JSON，停止扫描。
          }
          break;
        }
      }
    }
    return null;
  }
}

/// Returns a durable checkpoint that describes a tool operation without
/// persisting private file contents, shell commands, or other opaque payloads.
///
/// The full [ToolRequest] remains in memory while an approval dialog is open;
/// this representation is intended only for Hive, backup files, and recovery.
String safeToolRequestCheckpoint(ToolRequest request) {
  return jsonEncode(<String, dynamic>{
    'tool': request.tool.wireName,
    'reason': _safeCheckpointReason(request),
    'args': _safeCheckpointArgs(request.args),
  });
}

/// Sanitizes a legacy/raw JSON checkpoint before it crosses a durable
/// persistence boundary. Invalid input becomes an empty checkpoint.
String safeToolRequestCheckpointJson(String raw) {
  if (raw.trim().isEmpty) return '';
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return '';
    final tool = AgentToolName.fromWire(decoded['tool']?.toString() ?? '');
    if (tool == null) return '';
    final args = decoded['args'];
    return jsonEncode(<String, dynamic>{
      'tool': tool.wireName,
      'reason': _safeCheckpointReasonFromArgs(tool, args),
      'args': _safeCheckpointArgs(
        args is Map ? Map<String, dynamic>.from(args) : const {},
      ),
    });
  } on Object {
    return '';
  }
}

String _safeCheckpointReason(ToolRequest request) =>
    _safeCheckpointReasonFromArgs(request.tool, request.args);

String _safeCheckpointReasonFromArgs(
  AgentToolName tool,
  Object? rawArgs,
) {
  final args = rawArgs is Map ? Map<String, dynamic>.from(rawArgs) : const {};
  final path = args['path'];
  if (path is String && path.trim().isNotEmpty) {
    return '需要批准 ${tool.wireName}：${_safeCheckpointPath(path)}';
  }
  return '需要批准 ${tool.wireName}';
}

Map<String, dynamic> _safeCheckpointArgs(Map<String, dynamic> args) {
  final safe = <String, dynamic>{};
  final path = args['path'];
  if (path is String && path.trim().isNotEmpty) {
    safe['path'] = _safeCheckpointPath(path);
  }
  final overwrite = args['overwrite'];
  if (overwrite is bool) safe['overwrite'] = overwrite;
  for (final key in <String>['templateId', 'id', 'name', 'domain']) {
    final value = args[key];
    if (value is String && value.trim().isNotEmpty) {
      safe[key] = _safeCheckpointText(value);
    }
  }
  final content = args['content'];
  if (content is String) safe['contentLength'] = content.length;
  final command = args['command'];
  if (command is String && command.trim().isNotEmpty) {
    safe['commandPresent'] = true;
  }
  final permissions = args['permissions'];
  if (permissions is List) {
    safe['permissionCount'] = permissions.length;
  }
  if (args['url'] is String) safe['urlPresent'] = true;
  return safe;
}

String _safeCheckpointPath(String raw) {
  final normalized = raw.trim().replaceAll('\\', '/');
  if (normalized.startsWith('/') ||
      RegExp(r'^[A-Za-z]:/').hasMatch(normalized)) {
    final segments = normalized.split('/').where((item) => item.isNotEmpty);
    return segments.isEmpty ? '' : segments.last;
  }
  return normalized.contains('..') ? normalized.split('/').last : normalized;
}

String _safeCheckpointText(String raw) {
  var value = const SearchSecretScanner().redact(
    raw.trim(),
    includeOpaqueTokens: true,
  );
  value = value.replaceAll(RegExp(r'https?://[^\s,;）)]+'), '[外部地址]');
  value = value.replaceAll(
    RegExp(
      r'(?:(?:[A-Za-z]:[\\/])|/(?:Users|home|Volumes|private|tmp)/)[^\s,;）)]*',
    ),
    '[本地路径]',
  );
  return value.length <= 512 ? value : '${value.substring(0, 511)}…';
}

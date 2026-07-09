import 'dart:convert';

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

  static ToolRequest? tryParse(String content) {
    // 原有：```agent_tool ... ``` 围栏格式（prompt 推荐格式）
    var match = RegExp(
      r'```agent_tool\s*([\s\S]*?)\s*```',
    ).firstMatch(content);

    // 新增 fallback：<tool_call agent_tool ... </agent_tool> XML 格式
    // 部分非原生 function-calling 模型会“自选”这种标签格式输出工具请求，
    // 若不兼容会导致工具请求既不被执行、又被原样泄露到聊天 UI。
    match ??= RegExp(
      r'<tool_call\s+agent_tool\s*([\s\S]*?)\s*</agent_tool>',
    ).firstMatch(content);

    if (match == null) return null;

    try {
      final decoded = jsonDecode(match.group(1)!);
      if (decoded is! Map<String, dynamic>) return null;
      final tool = AgentToolName.fromWire(decoded['tool'] as String? ?? '');
      final args = decoded['args'];
      if (tool == null || args is! Map<String, dynamic>) return null;
      return ToolRequest(
        tool: tool,
        reason: decoded['reason'] as String? ?? '',
        args: args,
      );
    } on FormatException {
      return null;
    }
  }
}

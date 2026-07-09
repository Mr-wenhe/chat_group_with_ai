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
    final match = RegExp(
      r'```agent_tool\s*([\s\S]*?)\s*```',
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

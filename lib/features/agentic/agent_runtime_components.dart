import 'dart:convert';

import 'package:chat_group/features/agentic/tool_request.dart';
import 'package:chat_group/features/agentic/tools/browser_context_tool.dart';
import 'package:chat_group/features/agentic/tools/workspace_file_tool.dart';

class AgentProtocolParser {
  static ToolRequest? parse(String content) =>
      parseStrict(content) ?? parseLoose(content);

  static ToolRequest? parseStrict(String content) =>
      ToolRequest.tryParse(content);

  static ToolRequest? parseLoose(String content) {
    final function = RegExp(
      r'<function\s*=\s*([\w.\-]+)\s*>([\s\S]*?)</function>',
      caseSensitive: false,
    ).firstMatch(content);
    if (function != null) {
      final toolName = function.group(1)!;
      final tool = AgentToolName.fromWire(toolName);
      final args = _extractArgs(function.group(2)!);
      if (tool != null && args != null) {
        return ToolRequest(
          tool: tool,
          reason: args['reason'] as String? ?? '模型请求执行 $toolName',
          args: args,
        );
      }
    }
    if (content.contains('workspace.patch') ||
        content.contains('workspace.write')) {
      final args = _extractArgs(content);
      if (args?['path'] is String && args?['content'] is String) {
        return ToolRequest(
          tool: AgentToolName.workspacePatch,
          reason: args?['reason'] as String? ?? '模型请求写入文件',
          args: args!,
        );
      }
    }
    return null;
  }

  static Map<String, dynamic>? _extractArgs(String text) {
    final balanced = _firstBalancedJsonObject(text);
    if (balanced != null) {
      final args = balanced['args'];
      if (args is Map<String, dynamic>) return args;
      if (balanced['path'] is String) return balanced;
    }
    final path = _firstJsonString(text, 'path');
    final content = _firstJsonString(text, 'content');
    if (path == null || content == null) return null;
    final reason = _firstJsonString(text, 'reason');
    return {
      'path': path,
      'content': content,
      if (reason != null) 'reason': reason,
    };
  }

  static Map<String, dynamic>? _firstBalancedJsonObject(String text) {
    final start = text.indexOf('{');
    if (start < 0) return null;
    var depth = 0;
    var inString = false;
    var escape = false;
    for (var index = start; index < text.length; index++) {
      final character = text[index];
      if (inString) {
        if (escape) {
          escape = false;
        } else if (character == '\\') {
          escape = true;
        } else if (character == '"') {
          inString = false;
        }
        continue;
      }
      if (character == '"') {
        inString = true;
      } else if (character == '{') {
        depth++;
      } else if (character == '}' && --depth == 0) {
        try {
          final decoded = jsonDecode(text.substring(start, index + 1));
          return decoded is Map<String, dynamic> ? decoded : null;
        } on FormatException {
          return null;
        }
      }
    }
    return null;
  }

  static String? _firstJsonString(String text, String key) {
    final match = RegExp(
      '"$key"\\s*:\\s*"((?:[^"\\\\]|\\\\.)*)"',
    ).firstMatch(text);
    final raw = match?.group(1);
    if (raw == null) return null;
    return raw
        .replaceAll('\\"', '"')
        .replaceAll('\\\\', '\\')
        .replaceAll('\\n', '\n')
        .replaceAll('\\t', '\t');
  }
}

typedef AgentWorkspacePatchHandler = Future<Map<String, dynamic>> Function();
typedef AgentReadStartedHandler = Future<void> Function(String path);
typedef AgentSkillHandler = Future<Map<String, dynamic>> Function(
  Map<String, dynamic> args,
);

/// Executes already-authorized tools. Planning and permission checks remain in
/// the thin [AgentRuntime] facade.
class AgentToolExecutor {
  final WorkspaceFileTool? workspace;
  final BrowserContextTool? browser;
  final AgentSkillHandler? createSkill;
  final AgentSkillHandler? downloadSkill;

  const AgentToolExecutor({
    this.workspace,
    this.browser,
    this.createSkill,
    this.downloadSkill,
  });

  Future<Map<String, dynamic>> execute(
    ToolRequest request, {
    required AgentWorkspacePatchHandler patchWorkspace,
    required AgentReadStartedHandler onReadStarted,
  }) async {
    return switch (request.tool) {
      AgentToolName.workspaceList =>
        _workspace.list(path: request.args['path'] as String? ?? '.'),
      AgentToolName.workspaceRead => await () async {
          final path = request.args['path'] as String? ?? '';
          await onReadStarted(path);
          return _workspace.read(path);
        }(),
      AgentToolName.workspacePatch => patchWorkspace(),
      AgentToolName.commandRun =>
        _workspace.runCommand(request.args['command'] as String? ?? ''),
      AgentToolName.browserContext =>
        _browserSnapshotToJson(await _browser.currentTab()),
      AgentToolName.skillCreate => _createSkill(request.args),
      AgentToolName.skillDownload => _downloadSkill(request.args),
    };
  }

  WorkspaceFileTool get _workspace =>
      workspace ?? (throw StateError('Workspace file tool is not configured.'));

  BrowserContextTool get _browser =>
      browser ?? (throw StateError('Browser context tool is not configured.'));

  AgentSkillHandler get _createSkill =>
      createSkill ??
      (throw StateError('Skill create handler is not configured.'));

  AgentSkillHandler get _downloadSkill =>
      downloadSkill ??
      (throw StateError('Skill download handler is not configured.'));

  static Map<String, dynamic> _browserSnapshotToJson(
    BrowserContextSnapshot snapshot,
  ) =>
      {
        'url': snapshot.url,
        'title': snapshot.title,
        'selectedText': snapshot.selectedText,
        'pageText': snapshot.safePageText,
        'capturedAt': snapshot.capturedAt.toIso8601String(),
      };
}

/// Pure utility functions for non-agentic file recovery and reply sanitization.
///
/// Extracted from `chat_room_page.dart` so they can be unit-tested without
/// Flutter widget dependencies.
library;

import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/features/agentic/tools/workspace_file_tool.dart';

// ---------------------------------------------------------------------------
// Non-agentic file recovery
// ---------------------------------------------------------------------------

/// Infers a recoverable file path from a user request string.
///
/// Returns `null` when the request does not express a clear file-creation
/// intent. When it does, the function tries (in order):
/// 1. An explicit filename with a known extension in the request text.
/// 2. A heuristic mapping from topic keywords (html, markdown, C++, etc.)
///    to a default filename.
String? inferRecoverableFilePath(String request) {
  final lower = request.toLowerCase();
  final hasCreateIntent = RegExp(
    r'(生成|创建|写|设计|制作|做一个|做个|实现|开发|输出|导出|修改|改写|'
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

  if (RegExp(
    r'(html?|首页|主页|个人页|介绍页|页面|网页|网站|落地页|landing)',
    caseSensitive: false,
  ).hasMatch(lower)) {
    return 'page.html';
  }
  if (RegExp(r'(markdown|\bmd\b|文档|报告|简历)', caseSensitive: false)
      .hasMatch(lower)) {
    return 'report.md';
  }
  if (RegExp(r'(c\+\+|cpp|\bcxx\b|c/c\+\+|c语言|c 语言)', caseSensitive: false)
      .hasMatch(lower)) {
    return 'main.cpp';
  }
  if (RegExp(r'(dart|flutter|应用|app|程序)', caseSensitive: false)
      .hasMatch(lower)) {
    return 'main.dart';
  }
  if (RegExp(r'(python|\bpy\b)', caseSensitive: false).hasMatch(lower)) {
    return 'script.py';
  }
  if (RegExp(r'(javascript|\bjs\b)', caseSensitive: false).hasMatch(lower)) {
    return 'app.js';
  }
  return null;
}

/// Extracts recoverable file content from an LLM reply.
///
/// Tries (in order):
/// 1. A fenced code block with a known language tag.
/// 2. An HTML document starting with `<!doctype` or `<html`.
/// 3. The full trimmed text, validated against the file extension.
///
/// Returns `null` when no valid file content can be identified.
String? extractRecoverableFileContent(String output, String path) {
  final fenced = RegExp(
    r'```(?:html?|md|markdown|dart|txt|json|ya?ml|svg|css|js|ts|python|py|sh|bash|c|cc|cpp)?\s*\n([\s\S]*?)\n?```',
    caseSensitive: false,
  ).firstMatch(output);
  if (fenced != null) {
    final content = fenced.group(1)?.trim();
    if (content != null && content.isNotEmpty) return content;
  }

  final htmlStart = RegExp(r'<!doctype\s+html|<html\b', caseSensitive: false)
      .firstMatch(output)
      ?.start;
  if (htmlStart != null) {
    final tail = output.substring(htmlStart).trim();
    if (tail.isNotEmpty) return tail;
  }

  final trimmed = output.trim();
  if (trimmed.isEmpty) return null;
  if (looksLikeNarrationInsteadOfFile(trimmed)) return null;

  final ext = path.split('.').last.toLowerCase();
  if (ext == 'md' || ext == 'markdown' || ext == 'txt') return trimmed;
  if (ext == 'html' || ext == 'htm') {
    return RegExp(r'^(<!doctype|<html)\b', caseSensitive: false)
            .hasMatch(trimmed)
        ? trimmed
        : null;
  }
  if (ext == 'svg') {
    return RegExp(r'^<svg\b', caseSensitive: false).hasMatch(trimmed)
        ? trimmed
        : null;
  }
  if (ext == 'json') {
    return trimmed.startsWith('{') || trimmed.startsWith('[') ? trimmed : null;
  }
  if (ext == 'dart') {
    return RegExp(r"(import\s+'package:|void\s+main\s*\(|class\s+\w+)")
            .hasMatch(trimmed)
        ? trimmed
        : null;
  }
  if (ext == 'js' || ext == 'ts') {
    return RegExp(
      r'(function\s+\w+|const\s+\w+\s*=|let\s+\w+\s*=|document\.)',
    ).hasMatch(trimmed)
        ? trimmed
        : null;
  }
  if (const {'c', 'cc', 'cpp', 'h', 'hpp'}.contains(ext)) {
    return RegExp(
      r'(#include\s*[<"]|int\s+main\s*\(|class\s+\w+|namespace\s+\w+)',
    ).hasMatch(trimmed)
        ? trimmed
        : null;
  }
  return null;
}

/// Returns `true` when [content] looks like a conversational narration
/// (e.g. "好的，我已经帮你生成了…") rather than actual file content.
bool looksLikeNarrationInsteadOfFile(String content) {
  final lower = content.toLowerCase();
  if (RegExp(r'^(好的|抱歉|对不起|以下是|这是|我已经|我可以|无法|不能)').hasMatch(content)) {
    return true;
  }
  return lower.contains('复制保存为') ||
      lower.contains('save as') ||
      lower.contains('```');
}

// ---------------------------------------------------------------------------
// Agentic character selection
// ---------------------------------------------------------------------------

/// Selects a single agentic character for file/tool tasks.
///
/// When the current request is an explicit agentic task (e.g. "生成文件"),
/// and we are in a group chat (not a direct chat), converge to a single
/// character to avoid duplicate answers and artifacts.
///
/// - Direct chats: returns all candidates (no convergence).
/// - Not an explicit agentic task: returns all candidates unchanged.
/// - Mentioned characters: returns the first mentioned character who is in
///   the candidate list, or an empty list if none found.
/// - Otherwise: returns the first candidate only.
List<AICharacter> selectAgenticCharactersForRound({
  required bool isDirectChat,
  required bool isExplicitAgenticTask,
  required List<AICharacter> candidates,
  required List<String>? mentionedIds,
}) {
  if (isDirectChat || !isExplicitAgenticTask) return candidates;
  if (mentionedIds != null && mentionedIds.isNotEmpty) {
    for (final mentionedId in mentionedIds) {
      final character =
          candidates.where((item) => item.id == mentionedId).firstOrNull;
      if (character != null) return [character];
    }
    return const [];
  }
  final single = candidates.isNotEmpty ? candidates.first : null;
  return single == null ? const [] : [single];
}

// ---------------------------------------------------------------------------
// Non-agentic reply sanitization
// ---------------------------------------------------------------------------

/// Strips tool-call protocol leaks from a non-agentic LLM reply.
///
/// The non-agentic path uses a plain chat completion; it should never contain
/// `<tool_call>` / `<agent_tool>` tags. However, LLMs (especially those whose
/// system prompts still carry agentic tool descriptions) may spontaneously
/// emit such tags. This function removes **obvious** protocol leaks and
/// replaces oversized code blocks (>500 chars) with a placeholder, while
/// preserving normal chat content.
///
/// This is more conservative than `AgentRuntime._guardFinalMessage` because
/// the agentic path has its own dedicated guard.
String sanitizeNonAgenticReply(String text) {
  var result = text;

  // 1. Remove ```agent_tool ... ``` fenced blocks (including fences).
  result = result.replaceAll(
    RegExp(r'```agent_tool\s*[\s\S]*?\s*```'),
    '',
  );

  // 2. Remove <tool_call ... /tool_call> or <tool_call ... /agent_tool>
  //    complete XML blocks (most common LLM output format).
  result = result.replaceAll(
    RegExp(
      r'<tool_call\s*[\s\S]*?\s*(?:/agent_tool\s*>|/tool_call\s*>)',
      caseSensitive: false,
    ),
    '',
  );

  // 3. Remove <tool_call...</tool_call> paired XML blocks.
  result = result.replaceAll(
    RegExp(r'<tool_call[^>]*>[\s\S]*?</tool_call\s*>', dotAll: true),
    '',
  );

  // 4. Remove <function_call ... </function_call> XML blocks.
  result = result.replaceAll(
    RegExp(r'<function_call[^>]*>[\s\S]*?</function_call\s*>', dotAll: true),
    '',
  );

  // 5. Remove <agent_tool ... </agent_tool> standalone XML blocks.
  result = result.replaceAll(
    RegExp(r'<agent_tool[^>]*>[\s\S]*?</agent_tool\s*>', dotAll: true),
    '',
  );

  // 6. Remove trailing/partial opening tags without a closing tag.
  //    LLMs sometimes emit an opening tag at the end of a reply without
  //    ever closing it — the JSON inside would leak as chat text.
  //    Covers <tool_call, <agent_tool, <function_call, <function, <parameter.
  result = result.replaceAll(
    RegExp(
      r'<(tool_call|agent_tool|function_call|function|parameter)\b[\s\S]*$',
      caseSensitive: false,
    ),
    '',
  );

  // 7. Remove orphaned closing tags and the multi-line JSON content that
  //    precedes them. When only a closing tag exists (no matching opener),
  //    the preceding lines are almost certainly leaked tool-call JSON that
  //    should not appear in chat. Remove the closing tag + preceding
  //    lines that look like JSON (start with {, }, [, ], ") up to a blank
  //    line or non-JSON line. Limit to 20 lines to avoid over-matching.
  result = result.replaceAll(
    RegExp(
      r'(?:^[ \t]*[{}\[\]"].*\n){0,20}^[ \t]*[{}\[\]"][^\n]*\n\s*</(tool_call|agent_tool|function_call|function|parameter)\s*>\s*$\n?',
      multiLine: true,
      caseSensitive: false,
    ),
    '',
  );

  // 7b. Remove same-line orphaned closing tags with preceding JSON.
  //    e.g. '{"name":"exec","arguments":{}}</agent_tool>'
  result = result.replaceAll(
    RegExp(
      r'[^\n<]*?</(tool_call|agent_tool|function_call|function|parameter)\s*>',
      caseSensitive: false,
    ),
    '',
  );

  // 8. Remove any residual standalone tags (open/close, with extra whitespace).
  result = result.replaceAll(
    RegExp(r'</?\s*(tool_call|function_call|agent_tool|function|parameter)[^>]*>'),
    '',
  );

  // 9. Remove stray closing slash-tags that were not caught above.
  result = result.replaceAll(
    RegExp(r'/tool_call\s*>', caseSensitive: false),
    '',
  );

  // 10. Collapse 3+ consecutive blank lines into at most 2.
  result = result.replaceAll(RegExp(r'\n{3,}'), '\n\n');

  // 11. If the remaining text is dominated by a single oversized code block
  //     (>500 chars), replace it with a placeholder.
  final codeBlockMatch = RegExp(r'```[\s\S]{500,}```').firstMatch(result);
  if (codeBlockMatch != null) {
    result =
        result.replaceAll(codeBlockMatch.group(0)!, '📎 [代码内容已省略，请查看附件]');
  }
  return result.trim();
}

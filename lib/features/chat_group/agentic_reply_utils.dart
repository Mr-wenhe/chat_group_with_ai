/// Pure utility functions for normal-chat reply sanitization.
library;

import '../agentic/tool_fence_protocol.dart';

/// Strips tool-call protocol leaks from a non-agentic LLM reply.
///
/// The non-agentic path uses a plain chat completion; it should never contain
/// `<tool_call>` / `<agent_tool>` tags. However, LLMs (especially those whose
/// system prompts still carry agentic tool descriptions) may spontaneously
/// emit such tags. This function removes **obvious** protocol leaks and
/// replaces oversized code blocks (>500 chars) with a placeholder, while
/// preserving normal chat content.
///
/// Deliberately conservative: only obvious leaks are stripped, so ambiguous
/// content is never mangled for a false positive.
String sanitizeNonAgenticReply(String text) {
  var result = text;

  // Classify complete and truncated fences through the streaming predicate.
  result = _stripToolFences(result);

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
    RegExp(
        r'</?\s*(tool_call|function_call|agent_tool|function|parameter)[^>]*>'),
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
    result = result.replaceAll(codeBlockMatch.group(0)!, '📎 [代码内容已省略，请查看附件]');
  }
  final cleaned = result.trim();
  // A reply that consisted only of a tool request must not become an empty
  // bubble; say what happened instead of showing either JSON or nothing.
  if (cleaned.isEmpty && _containsToolProtocol(text)) {
    return '（这条回复原本要调用联网工具，但请求格式无效，已忽略。）';
  }
  return cleaned;
}

/// Fence label → payload pairs. ` ```json\n{...}\n``` ` and
/// ` ```agent_tool {...}``` ` both match.
final RegExp _fencePattern = RegExp(r'```([\s\S]*?)```');

String _stripToolFences(String text) {
  final out = StringBuffer();
  var cursor = 0;
  for (final match in _fencePattern.allMatches(text)) {
    out.write(text.substring(cursor, match.start));
    if (ToolFenceProtocol.parse(match.group(1)!).kind == ToolFenceKind.code) {
      out.write(match.group(0));
    }
    cursor = match.end;
  }
  final tail = text.substring(cursor);
  final start = tail.indexOf('```');
  if (start < 0 ||
      ToolFenceProtocol.parse(tail.substring(start + 3)).kind ==
          ToolFenceKind.code) {
    out.write(tail);
  } else {
    out.write(tail.substring(0, start));
  }
  return out.toString();
}

/// True when the raw reply mentions any tool-call protocol marker.
bool _containsToolProtocol(String text) =>
    ToolFenceProtocol.containsProtocolMarker(text);

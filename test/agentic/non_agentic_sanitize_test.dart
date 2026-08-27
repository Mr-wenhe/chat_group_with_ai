import 'package:chat_group/features/chat_group/agentic_reply_utils.dart';
import 'package:flutter_test/flutter_test.dart';

/// Non-agentic path tool_call leak prevention validation.
///
/// Now tests [sanitizeNonAgenticReply] directly from
/// `agentic_reply_utils.dart` instead of a copy-pasted duplicate.

void main() {
  group('non-agentic sanitize: tool_call / agent_tool leaks', () {
    test('removes standard tool_call blocks', () {
      const input = 'OK, let me help.\n'
          '<tool_call>\n'
          '{"name":"write_file","arguments":{"path":"a.html","content":"x"}}\n'
          '</tool_call>\n'
          'Done!';
      final result = sanitizeNonAgenticReply(input);
      expect(result, isNot(contains('<tool_call>')));
      expect(result, isNot(contains('</tool_call>')));
      expect(result, isNot(contains('write_file')));
      expect(result, contains('OK, let me help.'));
      expect(result, contains('Done!'));
    });

    test('removes agent_tool blocks', () {
      const input = 'Here you go.\n'
          '<agent_tool>\n'
          '{"name":"read_file","arguments":{"path":"b.txt"}}\n'
          '</agent_tool>\n'
          'Let me know if you need more.';
      final result = sanitizeNonAgenticReply(input);
      expect(result, isNot(contains('<agent_tool>')));
      expect(result, isNot(contains('</agent_tool>')));
      expect(result, isNot(contains('read_file')));
      expect(result, contains('Here you go.'));
      expect(result, contains('Let me know if you need more.'));
    });

    test('removes multiple interleaved blocks', () {
      const input = 'Start\n'
          '<tool_call>\n'
          '{"name":"write_file","arguments":{"path":"x.py","content":"print(1)"}}\n'
          '</tool_call>\n'
          'Middle text\n'
          '<agent_tool>\n'
          '{"name":"read_file","arguments":{"path":"y.py"}}\n'
          '</agent_tool>\n'
          'End';
      final result = sanitizeNonAgenticReply(input);
      expect(result, isNot(contains('<tool_call>')));
      expect(result, isNot(contains('</tool_call>')));
      expect(result, isNot(contains('<agent_tool>')));
      expect(result, isNot(contains('</agent_tool>')));
      expect(result, isNot(contains('write_file')));
      expect(result, isNot(contains('read_file')));
      expect(result, contains('Start'));
      expect(result, contains('Middle text'));
      expect(result, contains('End'));
    });

    test('returns clean text unchanged', () {
      const input = 'Hello! This is a normal reply with no tool calls.';
      final result = sanitizeNonAgenticReply(input);
      expect(result, equals(input));
    });

    test('handles empty string', () {
      final result = sanitizeNonAgenticReply('');
      expect(result, equals(''));
    });

    test('removes partial tool_call tags (opening only)', () {
      const input = 'Some text\n<tool_call>\n{"name":"search","arguments":{}}';
      final result = sanitizeNonAgenticReply(input);
      expect(result, isNot(contains('<tool_call>')));
      expect(result, isNot(contains('search')));
      expect(result, contains('Some text'));
    });

    test('removes partial agent_tool tags (closing only)', () {
      const input =
          '{"name":"exec","arguments":{"cmd":"ls"}}\n</agent_tool>\nAfter';
      final result = sanitizeNonAgenticReply(input);
      expect(result, isNot(contains('</agent_tool>')));
      expect(result, isNot(contains('exec')));
      expect(result, contains('After'));
    });

    test('collapses excessive blank lines left after removal', () {
      const input =
          'Before\n\n\n\n<tool_call>\n{"name":"write_file","arguments":{}}\n'
          '</tool_call>\n\n\n\nAfter';
      final result = sanitizeNonAgenticReply(input);
      expect(result, isNot(contains('\n\n\n')));
      expect(result, contains('Before'));
      expect(result, contains('After'));
    });

    test('handles nested-looking JSON inside tool_call', () {
      const input = 'Let me check.\n'
          '<tool_call>\n'
          '{"name":"write_file","arguments":{"path":"z.html","content":"<div>hello</div>"}}\n'
          '</tool_call>\n'
          'Done.';
      final result = sanitizeNonAgenticReply(input);
      expect(result, isNot(contains('<tool_call>')));
      expect(result, isNot(contains('</tool_call>')));
      expect(result, isNot(contains('write_file')));
      expect(result, contains('Let me check.'));
      expect(result, contains('Done.'));
    });

    test('does not strip content that merely looks like a tag name', () {
      const input = 'I used the tool_call pattern in my explanation, '
          'but this is just text about agent_tool usage.';
      final result = sanitizeNonAgenticReply(input);
      expect(result, contains('tool_call'));
      expect(result, contains('agent_tool'));
    });

    // --- P1: Unclosed opening tag edge cases ---

    test('removes unclosed <agent_tool> opening tag at end of reply', () {
      const input = 'Let me do that.\n'
          '<agent_tool>\n'
          '{"name":"create_file","arguments":{"path":"out.md","content":"# Hi"}}';
      final result = sanitizeNonAgenticReply(input);
      expect(result, isNot(contains('<agent_tool>')));
      expect(result, isNot(contains('create_file')));
      expect(result, contains('Let me do that.'));
    });

    test('removes unclosed <function_call> opening tag at end of reply', () {
      const input = 'Processing...\n'
          '<function_call>\n'
          '{"name":"exec","arguments":{"cmd":"ls -la"}}';
      final result = sanitizeNonAgenticReply(input);
      expect(result, isNot(contains('<function_call>')));
      expect(result, isNot(contains('exec')));
      expect(result, contains('Processing...'));
    });

    // --- P1: Multi-line JSON before orphaned closing tag ---

    test('removes multi-line JSON before orphaned closing tag', () {
      const input = 'Before\n'
          '{\n'
          '  "name": "write_file",\n'
          '  "arguments": {\n'
          '    "path": "big.md",\n'
          '    "content": "lots of text"\n'
          '  }\n'
          '}\n'
          '</tool_call>\n'
          'After';
      final result = sanitizeNonAgenticReply(input);
      expect(result, isNot(contains('</tool_call>')));
      expect(result, isNot(contains('write_file')));
      expect(result, isNot(contains('big.md')));
      expect(result, contains('Before'));
      expect(result, contains('After'));
    });

    // --- P1: Same-line closing tag with preceding JSON ---

    test('removes same-line closing tag with preceding JSON', () {
      const input = 'OK\n'
          '{"name":"exec","arguments":{"cmd":"rm -rf /"}}</agent_tool>\n'
          'Done';
      final result = sanitizeNonAgenticReply(input);
      expect(result, isNot(contains('</agent_tool>')));
      expect(result, isNot(contains('exec')));
      expect(result, isNot(contains('rm -rf')));
      expect(result, contains('OK'));
      expect(result, contains('Done'));
    });

    // --- P1: XML block formats ---

    test('removes <tool_call ... /tool_call> XML block format', () {
      const input = 'Starting\n'
          '<tool_call>\n'
          '{"name":"write_file","arguments":{"path":"a.md","content":"# Hello"}}\n'
          '/tool_call>\n'
          'Finished';
      final result = sanitizeNonAgenticReply(input);
      expect(result, isNot(contains('<tool_call>')));
      expect(result, isNot(contains('/tool_call>')));
      expect(result, isNot(contains('write_file')));
      expect(result, contains('Starting'));
      expect(result, contains('Finished'));
    });

    test('removes <tool_call ... /agent_tool> cross-tag block format', () {
      const input = 'Begin\n'
          '<tool_call>\n'
          '{"name":"read_file","arguments":{"path":"b.txt"}}\n'
          '/agent_tool>\n'
          'End';
      final result = sanitizeNonAgenticReply(input);
      expect(result, isNot(contains('<tool_call>')));
      expect(result, isNot(contains('/agent_tool>')));
      expect(result, isNot(contains('read_file')));
      expect(result, contains('Begin'));
      expect(result, contains('End'));
    });

    // --- P2: Code block size boundary tests ---

    test('replaces oversized code block (>500 chars) with placeholder', () {
      final bigCode = '```dart\n${'// line\n' * 80}```'; // ~640 chars of code
      final input = 'Here is the code:\n$bigCode\nLet me know!';
      final result = sanitizeNonAgenticReply(input);
      expect(
          result,
          contains(
              '\u{1F4CE} [\u4EE3\u7801\u5185\u5BB9\u5DF2\u7701\u7565\uFF0C\u8BF7\u67E5\u770B\u9644\u4EF6]'));
      expect(result, isNot(contains('```dart')));
      expect(result, contains('Here is the code:'));
      expect(result, contains('Let me know!'));
    });

    test('preserves small code blocks (<500 chars)', () {
      const input = 'Here is a snippet:\n'
          '```dart\n'
          'void main() { print("hi"); }\n'
          '```\n'
          'That was short.';
      final result = sanitizeNonAgenticReply(input);
      expect(result, contains('```dart'));
      expect(result, contains('void main()'));
      expect(result, contains('That was short.'));
      expect(result, isNot(contains('\u{1F4CE}')));
    });
  });
}

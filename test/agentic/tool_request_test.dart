import 'package:chat_group/features/agentic/tool_request.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses fenced tool request json', () {
    final parsed = ToolRequest.tryParse('''
我需要读文件。
```agent_tool
{"tool":"workspace.read","reason":"检查入口文件","args":{"path":"lib/main.dart"}}
```
''');

    expect(parsed, isNotNull);
    expect(parsed!.tool, AgentToolName.workspaceRead);
    expect(parsed.args['path'], 'lib/main.dart');
  });

  test('rejects unknown tool names', () {
    expect(
      ToolRequest.tryParse('```agent_tool\n{"tool":"shell.rm","args":{}}\n```'),
      isNull,
    );
  });

  test('parses skill download request', () {
    final parsed = ToolRequest.tryParse('''
```agent_tool
{"tool":"skill.download","reason":"安装职业专家能力","args":{"templateId":"coding.flutter-reviewer"}}
```
''');

    expect(parsed, isNotNull);
    expect(parsed!.tool, AgentToolName.skillDownload);
    expect(parsed.args['templateId'], 'coding.flutter-reviewer');
  });

  test('parses fenced tool request with empty args map', () {
    final parsed = ToolRequest.tryParse('''
```agent_tool
{"tool":"workspace.list","reason":"r","args":{}}
```
''');

    expect(parsed, isNotNull);
    expect(parsed!.tool, AgentToolName.workspaceList);
    expect(parsed.args, isEmpty);
  });

  // 本次修复核心：模型（非原生 function-calling）可能直接输出
  // <tool_call agent_tool ... </tool_call> XML 标签格式，旧正则只认
  // ``` 围栏，导致既不被执行又被原样泄露到聊天 UI。
  test('parses XML tool_call format (regression: previously leaked)', () {
    final parsed = ToolRequest.tryParse(
      '<tool_call agent_tool {"tool":"workspace.list","reason":"r","args":{}} </tool_call>',
    );

    expect(parsed, isNotNull);
    expect(parsed!.tool, AgentToolName.workspaceList);
    expect(parsed.args, isEmpty);
  });

  test('parses XML tool_call even when wrapped in normal text', () {
    final parsed = ToolRequest.tryParse(
      '稍等，我查一下工作区。\n'
      '<tool_call agent_tool {"tool":"workspace.list","reason":"r","args":{}} </tool_call>',
    );

    expect(parsed, isNotNull);
    expect(parsed!.tool, AgentToolName.workspaceList);
    expect(parsed.args, isEmpty);
  });

  test('returns null for stray closing tool tag without opener', () {
    expect(
      ToolRequest.tryParse('这是正常文本。</agent_tool>'),
      isNull,
    );
  });

  test('returns null for unrelated plain text', () {
    expect(
      ToolRequest.tryParse('今天天气真好，我们聊点别的吧。'),
      isNull,
    );
  });
}

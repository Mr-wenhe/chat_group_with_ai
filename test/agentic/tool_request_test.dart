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
}

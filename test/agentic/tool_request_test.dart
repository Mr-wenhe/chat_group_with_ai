import 'package:chat_group/features/agentic/tool_request.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('tool request JSON round-trips for persisted task recovery', () {
    const original = ToolRequest(
      tool: AgentToolName.workspacePatch,
      reason: '写入文件',
      args: {'path': 'page.html', 'content': '<html></html>'},
    );

    final restored = ToolRequest.fromJsonString(original.toJsonString());

    expect(restored, isNotNull);
    expect(restored!.tool, AgentToolName.workspacePatch);
    expect(restored.reason, '写入文件');
    expect(restored.args['path'], 'page.html');
  });

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

  // 防御性：部分模型用 </agent_tool> 作为闭合标签（与 </tool_call> 并存）。
  // 两种闭合都应被识别，否则该格式仍会被泄露。
  test('parses XML tool_call with </agent_tool> closing variant', () {
    final parsed = ToolRequest.tryParse(
      '<tool_call agent_tool {"tool":"workspace.list","reason":"r","args":{}} </agent_tool>',
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

  // Bug 3 修复：兼容 <tool_call {"tool":...}} </tool_call> 变体
  // （开标签后**没有字面 `>`**，JSON 直接跟在 <tool_call 后面）。
  // 这是 QA 回归中抓到的真实模型输出，必须用此格式卡住回归。
  test('parses tool_call directly followed by json (no closing `>` in opener)',
      () {
    final parsed = ToolRequest.tryParse(
      '<tool_call {"tool":"workspace.list","args":{"nested":{"a":1}}} </tool_call>',
    );

    expect(parsed, isNotNull);
    expect(parsed!.tool, AgentToolName.workspaceList);
    expect(parsed.args['nested'], isA<Map>());
  });

  // 同上变体，含嵌套 JSON 的真实工具请求（qa_real_tool_request_check.dart 复现用例）。
  // 注意：用合法工具名 workspace.list；若用非法名（如 "x"）会被 fromWire 拒掉、返回 null。
  test('parses tool_call with nested json and no `>` in opener', () {
    final parsed = ToolRequest.tryParse(
      '<tool_call {"tool":"workspace.list","args":{"a":{"b":1}}} </tool_call>',
    );

    expect(parsed, isNotNull);
    expect(parsed!.args['a'], isA<Map>());
  });

  // 兼容性：<tool_call> 带字面 `>`（JSON 放在标签体内、独占一行）仍可解析。
  test('parses tool_call wrapper with `>` opener and json on its own line', () {
    final parsed = ToolRequest.tryParse(
      '稍等，我来生成文件。\n'
      '<tool_call>\n'
      '{"tool":"workspace.patch","reason":"生成 HTML","args":{"path":"star.html","content":"<html></html>"}}\n'
      '</tool_call>',
    );

    expect(parsed, isNotNull);
    expect(parsed!.tool, AgentToolName.workspacePatch);
    expect(parsed.args['path'], 'star.html');
  });

  // Bug 3 修复：JSON 前后夹带说明文字时仍能提取出合法工具请求。
  test('parses tool_call with surrounding prose around json', () {
    final parsed = ToolRequest.tryParse(
      '<tool_call agent_tool 请执行 {"tool":"workspace.read","reason":"r","args":{"path":"lib/main.dart"}} 完毕 </tool_call>',
    );

    expect(parsed, isNotNull);
    expect(parsed!.tool, AgentToolName.workspaceRead);
    expect(parsed.args['path'], 'lib/main.dart');
  });

  test('parses function_calls parameter format as workspace patch', () {
    final parsed = ToolRequest.tryParse('''
<tool_call>
<function_calls>
<parameter name="path">/Users/me/data/ai_files/task_1/meteor_rain.html</parameter>
<parameter name="content">&lt;!DOCTYPE html&gt;
<html lang="zh-CN">
<head><title>流星雨</title></head>
</html></parameter>
</function_calls>
</tool_call>
''');

    expect(parsed, isNotNull);
    expect(parsed!.tool, AgentToolName.workspacePatch);
    expect(parsed.args['path'], endsWith('meteor_rain.html'));
    expect(parsed.args['content'], contains('<!DOCTYPE html>'));
    expect(parsed.args['content'], contains('流星雨'));
  });

  test('ignores parameter tags outside tool envelopes', () {
    final parsed = ToolRequest.tryParse('''
这是普通协议说明，不是工具调用：
<parameter name="path">technical_documentation.md</parameter>
<parameter name="content">hello</parameter>
''');

    expect(parsed, isNull);
  });
}

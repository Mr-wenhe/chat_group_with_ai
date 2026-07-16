// 独立回归验证（QA Edward）：直接驱动真实 AgentRuntime.run() 路径，
// 验证 _inferGeneratedFilePath / _inferWorkspaceFilePath 等中英文类型识别补全。
// 本文件与工程师既有测试相互独立，用于独立确认映射正确性，不依赖其断言。
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/character_skill.dart';
import 'package:chat_group/core/models/tool_permission.dart';
import 'package:chat_group/features/agentic/agent_runtime.dart';
import 'package:chat_group/features/agentic/tools/local_agent_bridge_client.dart';
import 'package:chat_group/features/agentic/tools/workspace_file_tool.dart';
import 'package:flutter_test/flutter_test.dart';

AICharacter _character({
  String name = '代码大神',
  required List<ToolPermission> toolPermissions,
}) {
  return AICharacter(
    name: name,
    avatar: 'x',
    age: 30,
    role: '工程师',
    personalityTags: const ['代码'],
    systemPrompt: '写代码',
    apiKey: 'k',
    apiProvider: 'deepseek',
    toolPermissions: toolPermissions,
  )..agenticEnabled = true;
}

class _FakeWorkspaceFileTool extends WorkspaceFileTool {
  final Map<String, dynamic> patchResult;
  String? lastWritePath;
  String? lastWriteContent;

  _FakeWorkspaceFileTool({this.patchResult = const {}})
      : super(LocalAgentBridgeClient());

  @override
  Future<Map<String, dynamic>> read(String path) async => const {};

  @override
  Future<Map<String, dynamic>> applyPatch(String patch) async => patchResult;

  @override
  Future<Map<String, dynamic>> write(String path, String content) async {
    lastWritePath = path;
    lastWriteContent = content;
    return patchResult;
  }

  @override
  Future<Map<String, dynamic>> runCommand(String command) async => const {};

  @override
  Future<Map<String, dynamic>> list({String path = '.'}) async => const {};
}

CharacterSkill _skill() {
  return CharacterSkill(
    characterId: 'c1',
    name: 'Code Review',
    domain: 'coding',
    description: 'Review code.',
    instructions: const ['Read files'],
    requiredPermissions: const [ToolPermission.workspaceRead],
  );
}

void main() {
  test('[QA] ppt演示文稿 → slides.pptx（且降级为 .md 真实写入）', () async {
    final fakeTool = _FakeWorkspaceFileTool(
      patchResult: {'ok': true, 'path': 'slides.md', 'bytes': 20},
    );
    String? firstSystemPrompt;
    final runtime = AgentRuntime(
      complete: (messages) async {
        firstSystemPrompt ??=
            messages.isNotEmpty ? messages.first['content'] as String? : null;
        return {
          'success': true,
          'message': '''
```agent_tool
{"tool":"workspace.patch","reason":"生成演示文稿","args":{"path":"slides.pptx","content":"# 演示文稿\\n\\n幻灯片内容"}}
```
''',
        };
      },
      workspaceFileTool: fakeTool,
    );
    final result = await runtime.run(
      character: _character(
        toolPermissions: const [ToolPermission.workspacePatch],
      ),
      skills: [_skill()],
      userRequest: '我要一份ppt演示文稿',
      approved: true,
    );
    expect(result.status, AgentRuntimeStatus.completed);
    expect(firstSystemPrompt, contains('slides.pptx'));
    expect(fakeTool.lastWritePath, 'slides.md');
  });

  test('[QA] csv表格数据 → data.csv（必须命中 csv 而非 excel 的 xlsx）', () async {
    final fakeTool = _FakeWorkspaceFileTool(
      patchResult: {'ok': true, 'path': 'data.csv', 'bytes': 20},
    );
    String? firstSystemPrompt;
    final runtime = AgentRuntime(
      complete: (messages) async {
        firstSystemPrompt ??=
            messages.isNotEmpty ? messages.first['content'] as String? : null;
        return {
          'success': true,
          'message': '''
```agent_tool
{"tool":"workspace.patch","reason":"生成表格","args":{"path":"data.csv","content":"name,score\\nAlice,90"}}
```
''',
        };
      },
      workspaceFileTool: fakeTool,
    );
    final result = await runtime.run(
      character: _character(
        toolPermissions: const [ToolPermission.workspacePatch],
      ),
      skills: [_skill()],
      userRequest: '生成csv表格数据',
      approved: true,
    );
    expect(result.status, AgentRuntimeStatus.completed);
    expect(firstSystemPrompt, contains('data.csv'));
    // 关键：绝不能误判成 xlsx（csv 分支在 excel 分支之前）。
    expect(firstSystemPrompt, isNot(contains('report.xlsx')));
    expect(fakeTool.lastWritePath, 'data.csv');
  });

  test('[QA] txt文本 → note.txt', () async {
    final fakeTool = _FakeWorkspaceFileTool(
      patchResult: {'ok': true, 'path': 'note.txt', 'bytes': 12},
    );
    String? firstSystemPrompt;
    final runtime = AgentRuntime(
      complete: (messages) async {
        firstSystemPrompt ??=
            messages.isNotEmpty ? messages.first['content'] as String? : null;
        return {
          'success': true,
          'message': '''
```agent_tool
{"tool":"workspace.patch","reason":"生成文本","args":{"path":"note.txt","content":"一些纯文本内容"}}
```
''',
        };
      },
      workspaceFileTool: fakeTool,
    );
    final result = await runtime.run(
      character: _character(
        toolPermissions: const [ToolPermission.workspacePatch],
      ),
      skills: [_skill()],
      userRequest: '写个txt文本',
      approved: true,
    );
    expect(result.status, AgentRuntimeStatus.completed);
    expect(firstSystemPrompt, contains('note.txt'));
    expect(fakeTool.lastWritePath, 'note.txt');
  });

  test('[QA] json配置 → data.json', () async {
    final fakeTool = _FakeWorkspaceFileTool(
      patchResult: {'ok': true, 'path': 'data.json', 'bytes': 24},
    );
    String? firstSystemPrompt;
    final runtime = AgentRuntime(
      complete: (messages) async {
        firstSystemPrompt ??=
            messages.isNotEmpty ? messages.first['content'] as String? : null;
        return {
          'success': true,
          'message': '''
```agent_tool
{"tool":"workspace.patch","reason":"生成配置","args":{"path":"data.json","content":"{\\"name\\":\\"demo\\"}"}}
```
''',
        };
      },
      workspaceFileTool: fakeTool,
    );
    final result = await runtime.run(
      character: _character(
        toolPermissions: const [ToolPermission.workspacePatch],
      ),
      skills: [_skill()],
      userRequest: '来个json配置',
      approved: true,
    );
    expect(result.status, AgentRuntimeStatus.completed);
    expect(firstSystemPrompt, contains('data.json'));
    // json 分支必须在 yaml/yml 配置分支之前。
    expect(firstSystemPrompt, isNot(contains('config.yaml')));
    expect(fakeTool.lastWritePath, 'data.json');
  });

  test('[QA] doc文档 → report.docx（而非被 md 分支抢走）', () async {
    final fakeTool = _FakeWorkspaceFileTool(
      patchResult: {'ok': true, 'path': 'report.md', 'bytes': 16},
    );
    String? firstSystemPrompt;
    final runtime = AgentRuntime(
      complete: (messages) async {
        firstSystemPrompt ??=
            messages.isNotEmpty ? messages.first['content'] as String? : null;
        return {
          'success': true,
          'message': '''
```agent_tool
{"tool":"workspace.patch","reason":"生成文档","args":{"path":"report.docx","content":"# 文档\\n\\n正文"}}
```
''',
        };
      },
      workspaceFileTool: fakeTool,
    );
    final result = await runtime.run(
      character: _character(
        toolPermissions: const [ToolPermission.workspacePatch],
      ),
      skills: [_skill()],
      userRequest: '我要一份doc文档',
      approved: true,
    );
    expect(result.status, AgentRuntimeStatus.completed);
    // docx 分支必须在 md 分支之前。
    expect(firstSystemPrompt, contains('report.docx'));
    expect(firstSystemPrompt, isNot(contains('report.md')));
    expect(fakeTool.lastWritePath, 'report.md');
  });

  test('[QA] 读取意图（读一下这个ppt文件）→ 不误判为文件生成 (null)', () async {
    String? firstSystemPrompt;
    final runtime = AgentRuntime(
      complete: (messages) async {
        firstSystemPrompt ??=
            messages.isNotEmpty ? messages.first['content'] as String? : null;
        return {
          'success': true,
          'message': '这是该 PPT 文件的内容概要，我并没有新建文件。',
        };
      },
    );
    final result = await runtime.run(
      character: _character(toolPermissions: const []),
      skills: [_skill()],
      userRequest: '读一下这个ppt文件',
    );
    expect(result.status, AgentRuntimeStatus.completed);
    expect(result.pendingToolRequest, isNull);
    // 系统提示中不应出现 slides.pptx，说明 _inferGeneratedFilePath 返回了 null。
    expect(firstSystemPrompt, isNot(contains('slides.pptx')));
  });

  test('[QA] Excel 回归：工资报表excel文件 → report.xlsx（无回归）', () async {
    final fakeTool = _FakeWorkspaceFileTool(
      patchResult: {'ok': true, 'path': 'report.md', 'bytes': 30},
    );
    String? firstSystemPrompt;
    final runtime = AgentRuntime(
      complete: (messages) async {
        firstSystemPrompt ??=
            messages.isNotEmpty ? messages.first['content'] as String? : null;
        return {
          'success': true,
          'message': '''
```agent_tool
{"tool":"workspace.patch","reason":"生成工资报表","args":{"path":"report.xlsx","content":"# 工资报表\\n\\n| 姓名 | 工资 |\\n| --- | --- |\\n| 张三 | 8000 |"}}
```
''',
        };
      },
      workspaceFileTool: fakeTool,
    );
    final result = await runtime.run(
      character: _character(
        toolPermissions: const [ToolPermission.workspacePatch],
      ),
      skills: [_skill()],
      userRequest: '我要一份工资报表excel文件',
      approved: true,
    );
    expect(result.status, AgentRuntimeStatus.completed);
    expect(firstSystemPrompt, contains('report.xlsx'));
    expect(fakeTool.lastWritePath, 'report.md');
  });
}

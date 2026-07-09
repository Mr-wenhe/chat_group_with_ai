import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/character_skill.dart';
import 'package:chat_group/core/models/tool_permission.dart';
import 'package:chat_group/features/agentic/agent_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

/// 工具协议泄露防护回归测试。
///
/// `_sanitizeToolProtocolLeak` 是 `agent_runtime.dart` 内的私有（库隔离）方法，
/// Dart 的 `_` 前缀使其在单独的测试库中不可见，因此这里通过公开的 [AgentRuntime.run]
/// 包装来验证其行为——这也恰好是用户最终会看到的 UI 路径：当模型输出未被
/// [ToolRequest.tryParse] 识别（残缺/畸形/未知工具）的工具标记时，`run()` 必须
/// 清理掉裸协议标签，绝不直接把 `<tool_call ...>` 或 ```agent_tool 发回聊天界面。
void main() {
  group('AgentRuntime.run sanitizes leaked tool protocol', () {
    // 故意不给任何工具权限，确保任何合法工具请求都停在 permissionMissing，
    // 不会真的去执行（避免依赖真实桥接），从而干净地验证「协议不被泄露」。
    final character = AICharacter(
      name: '范晓萌',
      avatar: '',
      age: 18,
      role: '',
      personalityTags: const [],
      systemPrompt: '',
      apiKey: '',
      apiProvider: 'deepseek',
      toolPermissions: const [],
    )..agenticEnabled = true;

    Future<AgentRuntimeResult> runWith(String message) {
      final runtime = AgentRuntime(
        // 关闭本地文件规划器，避免走到 _localFileGenerationRequest 分支。
        enableLocalFilePlanner: false,
        complete: (_) async => {'success': true, 'message': message},
      );
      return runtime.run(
        character: character,
        skills: const [],
        userRequest: '随便聊聊',
      );
    }

    test('正常文本原样返回，不触发泄露过滤', () async {
      final result = await runWith('这是正常的聊天回复。');
      expect(result.status, AgentRuntimeStatus.completed);
      expect(result.message, '这是正常的聊天回复。');
    });

    test('含 XML 工具标记（未知工具）的文本被整块移除，仅留正常文本', () async {
      final result = await runWith(
        '请稍候。<tool_call agent_tool {"tool":"unknown.tool"} </tool_call>好的。',
      );
      expect(result.status, AgentRuntimeStatus.completed);
      expect(result.message, '请稍候。好的。');
      expect(result.message, isNot(contains('<tool_call')));
    });

    test('含 fence 工具标记（未知工具）的文本被整块移除，仅留正常文本', () async {
      final result = await runWith(
        '请稍候。```agent_tool {"tool":"unknown.tool"} ```好的。',
      );
      expect(result.status, AgentRuntimeStatus.completed);
      expect(result.message, '请稍候。好的。');
      expect(result.message, isNot(contains('agent_tool')));
    });

    test('纯工具标记无正常文本 → 兜底文案含角色名', () async {
      final result = await runWith(
        '```agent_tool {"tool":"unknown.tool","args":{}} ```',
      );
      expect(result.status, AgentRuntimeStatus.completed);
      expect(result.message, contains('范晓萌'));
      expect(result.message, contains('已为你隐藏内部工具协议'));
      expect(result.message, isNot(contains('agent_tool')));
    });

    test('合法 XML 工具请求被解析而非作为裸协议泄露', () async {
      // 核心回归：模型输出 <tool_call agent_tool ...> 时，旧代码会原样
      // 泄露到聊天 UI；新代码应识别为工具请求并进入权限/执行分支。
      final result = await runWith(
        '<tool_call agent_tool {"tool":"workspace.list","reason":"列出工作区","args":{}} </tool_call>',
      );
      expect(result.message, isNot(contains('<tool_call')));
    });
  });
}

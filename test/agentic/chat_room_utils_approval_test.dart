import 'package:chat_group/features/agentic/agent_runtime.dart';
import 'package:chat_group/features/agentic/tool_request.dart';
import 'package:chat_group/features/chat_group/chat_room_utils.dart';
import 'package:flutter_test/flutter_test.dart';

/// P2 批准态标记（content 层）测试。
///
/// 验证 agentProgressMessageContent 在 ✅ 行尾依据工具类型追加
/// 「需批准」/「自动」文案，且 requiresApproval 映射由 AgentRuntime 静态方法承载。
void main() {
  // 需批准类工具 → 行尾「需批准」：workspacePatch / commandRun / browserContext /
  // skillCreate / skillDownload。
  group('approval-required tools append 「需批准」', () {
    test('workspacePatch → 需批准', () {
      final content = agentProgressMessageContent(
        characterName: '小智',
        progress: const AgentRuntimeProgress(
          stage: AgentRuntimeProgressStage.toolCompleted,
          executedRequests: [
            ToolRequest(
              tool: AgentToolName.workspacePatch,
              reason: '写',
              args: {'path': 'page.html'},
            ),
          ],
        ),
      );
      expect(content, contains('✅ 已创建文件：page.html · 需批准'));
    });

    test('commandRun → 需批准', () {
      final content = agentProgressMessageContent(
        characterName: '小智',
        progress: const AgentRuntimeProgress(
          stage: AgentRuntimeProgressStage.toolCompleted,
          executedRequests: [
            ToolRequest(
              tool: AgentToolName.commandRun,
              reason: '跑',
              args: {'command': 'ls -la'},
            ),
          ],
        ),
      );
      expect(content, contains('✅ 执行命令：ls -la · 需批准'));
    });

    test('browserContext / skillCreate / skillDownload → 需批准', () {
      final content = agentProgressMessageContent(
        characterName: '小智',
        progress: const AgentRuntimeProgress(
          stage: AgentRuntimeProgressStage.toolCompleted,
          executedRequests: [
            ToolRequest(
                tool: AgentToolName.browserContext, reason: '抓', args: {}),
            ToolRequest(
              tool: AgentToolName.skillCreate,
              reason: '建',
              args: {'name': 'foo'},
            ),
            ToolRequest(
              tool: AgentToolName.skillDownload,
              reason: '下',
              args: {'name': 'bar'},
            ),
          ],
        ),
      );
      expect(content, contains('✅ 抓取浏览器上下文 · 需批准'));
      expect(content, contains('✅ 创建技能：skill.create · 需批准'));
      expect(content, contains('✅ 下载技能：skill.download · 需批准'));
    });
  });

  // 自动类工具 → 行尾「自动」：workspaceRead / workspaceList。
  group('auto tools append 「自动」', () {
    test('workspaceRead → 自动', () {
      final content = agentProgressMessageContent(
        characterName: '小智',
        progress: const AgentRuntimeProgress(
          stage: AgentRuntimeProgressStage.toolCompleted,
          executedRequests: [
            ToolRequest(
              tool: AgentToolName.workspaceRead,
              reason: '读',
              args: {'path': 'x.txt'},
            ),
          ],
        ),
      );
      expect(content, contains('✅ 读取文件：x.txt · 自动'));
    });

    test('workspaceList → 自动', () {
      final content = agentProgressMessageContent(
        characterName: '小智',
        progress: const AgentRuntimeProgress(
          stage: AgentRuntimeProgressStage.toolCompleted,
          executedRequests: [
            ToolRequest(
              tool: AgentToolName.workspaceList,
              reason: '列',
              args: {'path': '.'},
            ),
          ],
        ),
      );
      expect(content, contains('✅ 列出工作区：. · 自动'));
    });
  });

  // 混合多步：需批准与自动步骤共存，各自追加正确文案。
  test('mixed steps preserve per-step approval tags', () {
    final content = agentProgressMessageContent(
      characterName: '小智',
      progress: const AgentRuntimeProgress(
        stage: AgentRuntimeProgressStage.toolCompleted,
        executedRequests: [
          ToolRequest(
            tool: AgentToolName.workspaceRead,
            reason: '读',
            args: {'path': 'a.txt'},
          ),
          ToolRequest(
            tool: AgentToolName.workspacePatch,
            reason: '写',
            args: {'path': 'b.html'},
          ),
        ],
      ),
    );
    expect(content, contains('✅ 读取文件：a.txt · 自动'));
    expect(content, contains('✅ 已创建文件：b.html · 需批准'));
    // 自动与需批准不应串味。
    expect(content, isNot(contains('读取文件：a.txt · 需批准')));
    expect(content, isNot(contains('已创建文件：b.html · 自动')));
  });

  // requiresApproval 静态方法映射正确（入参为 AgentToolName）。
  test('AgentRuntime.requiresApproval maps tools correctly', () {
    expect(AgentRuntime.requiresApproval(AgentToolName.workspaceRead), isFalse);
    expect(AgentRuntime.requiresApproval(AgentToolName.workspaceList), isFalse);
    expect(AgentRuntime.requiresApproval(AgentToolName.workspacePatch), isTrue);
    expect(AgentRuntime.requiresApproval(AgentToolName.commandRun), isTrue);
    expect(AgentRuntime.requiresApproval(AgentToolName.browserContext), isTrue);
    expect(AgentRuntime.requiresApproval(AgentToolName.skillCreate), isTrue);
    expect(AgentRuntime.requiresApproval(AgentToolName.skillDownload), isTrue);
  });
}

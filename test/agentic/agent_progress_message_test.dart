import 'package:chat_group/features/agentic/agent_runtime.dart';
import 'package:chat_group/features/agentic/tool_request.dart';
import 'package:chat_group/features/chat_group/chat_room_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('agent progress starts with a visible planning update', () {
    expect(
      agentProgressMessageContent(characterName: '陈思远'),
      contains('正在规划'),
    );
  });

  test('agent progress reports the completed tool and file path', () {
    const request = ToolRequest(
      tool: AgentToolName.workspacePatch,
      reason: '生成分析脚本',
      args: {'path': 'sales_analysis.py', 'content': 'print(1)'},
    );

    expect(
      agentProgressMessageContent(
        characterName: '陈思远',
        progress: const AgentRuntimeProgress(
          stage: AgentRuntimeProgressStage.toolCompleted,
          executedRequests: [request],
        ),
      ),
      allOf(contains('已完成第 1 步'), contains('sales_analysis.py')),
    );
  });
}

import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/agentic/agent_progress_meta.dart';
import 'package:chat_group/features/agentic/agent_runtime.dart';
import 'package:chat_group/features/agentic/tool_request.dart';
import 'package:chat_group/features/chat_group/chat_room_utils.dart';
import 'package:chat_group/features/work_mode/work_mode_task_lifecycle.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // (a) 枚举含全部新增值。
  test('AgentRuntimeProgressStage contains all streaming stages', () {
    expect(
      AgentRuntimeProgressStage.values,
      containsAll([
        AgentRuntimeProgressStage.waitingForApproval,
        AgentRuntimeProgressStage.toolCompleted,
        AgentRuntimeProgressStage.planning,
        AgentRuntimeProgressStage.thinking,
        AgentRuntimeProgressStage.readingFile,
        AgentRuntimeProgressStage.callingTool,
        AgentRuntimeProgressStage.writingFile,
        AgentRuntimeProgressStage.fileCreated,
        AgentRuntimeProgressStage.validating,
        AgentRuntimeProgressStage.stepFailed,
        AgentRuntimeProgressStage.stepRejected,
      ]),
    );
  });

  // (b) AgentRuntimeProgress const 构造兼容（旧调用仍编译）。
  test('AgentRuntimeProgress const constructor remains compatible', () {
    const request = ToolRequest(
      tool: AgentToolName.workspacePatch,
      reason: '写文件',
      args: {'path': 'page.html', 'content': '<html></html>'},
    );
    const progress = AgentRuntimeProgress(
      stage: AgentRuntimeProgressStage.toolCompleted,
      executedRequests: [request],
    );
    expect(progress.stage, AgentRuntimeProgressStage.toolCompleted);
    expect(progress.executedRequests, hasLength(1));
    expect(progress.currentStepLabel, isNull);
    expect(progress.pendingRequest, isNull);
  });

  // (c) agentProgressMessageContent 多行格式。
  group('agentProgressMessageContent multi-line log', () {
    const request = ToolRequest(
      tool: AgentToolName.workspacePatch,
      reason: '生成页面',
      args: {'path': 'page.html', 'content': '<html></html>'},
    );

    test('planning stage shows header and active planning line', () {
      final content = agentProgressMessageContent(
        characterName: '小智',
        progress: const AgentRuntimeProgress(
          stage: AgentRuntimeProgressStage.planning,
          executedRequests: [],
        ),
      );
      expect(content, contains('🧭 小智 · 工作模式 ｜ 执行中'));
      expect(content, contains('⏳ 规划中'));
    });

    test('tool completed lists done rows derived from executedRequests', () {
      final content = agentProgressMessageContent(
        characterName: '小智',
        progress: const AgentRuntimeProgress(
          stage: AgentRuntimeProgressStage.toolCompleted,
          executedRequests: [request],
        ),
      );
      // 已完成行由 executedRequests 派生，含路径。
      expect(content, contains('✅ 已创建文件：page.html'));
      // toolCompleted 仅聚合刷新，不重复产生 ✅ 行。
      expect('✅ 已创建文件：page.html'.allMatches(content).length, 1);
    });

    test('finalResult converts the last line to done and drops the cursor', () {
      final content = agentProgressMessageContent(
        characterName: '小智',
        progress: const AgentRuntimeProgress(
          stage: AgentRuntimeProgressStage.thinking,
          executedRequests: [request],
          currentStepLabel: '正在校验结果：page.html',
        ),
        finalResult: true,
      );
      expect(content, contains('🧭 小智 · 工作模式 ｜ 已完成'));
      // 末行转为 ✅，且整体不含 ⏳ 光标。
      expect(content, contains('✅ 正在校验结果：page.html'));
      expect(content, isNot(contains('⏳')));
    });

    test('finalResult bakes elapsedSeconds into the header', () {
      final content = agentProgressMessageContent(
        characterName: '小智',
        progress: const AgentRuntimeProgress(
          stage: AgentRuntimeProgressStage.thinking,
          executedRequests: [request],
          currentStepLabel: '正在校验结果：page.html',
        ),
        finalResult: true,
        elapsedSeconds: 31,
      );
      // 首行头部之后追加「⏱ Ns」，即便后续 _progressStartTimes 清理也不丢耗时。
      expect(content, contains('🧭 小智 · 工作模式 ｜ 已完成 ⏱ 31s'));
    });

    test('finalResult without elapsedSeconds does not append ⏱', () {
      final content = agentProgressMessageContent(
        characterName: '小智',
        progress: const AgentRuntimeProgress(
          stage: AgentRuntimeProgressStage.thinking,
          executedRequests: [request],
          currentStepLabel: '正在校验结果：page.html',
        ),
        finalResult: true,
      );
      expect(content, isNot(contains('⏱')));
    });
  });

  // (e) 失败 / 拒绝阶段渲染（触发 stepFailed / stepRejected 分支）。
  group('agentProgressMessageContent failure and rejection stages', () {
    const request = ToolRequest(
      tool: AgentToolName.workspacePatch,
      reason: '生成页面',
      args: {'path': 'page.html', 'content': '<html></html>'},
    );

    test('stepFailed (live) keeps executing header and an active failed line',
        () {
      final content = agentProgressMessageContent(
        characterName: '小智',
        progress: AgentRuntimeProgress(
          stage: AgentRuntimeProgressStage.stepFailed,
          executedRequests: [request],
          currentStepLabel: stepFailedLabel('路径冲突'),
        ),
      );
      // 实时失败上报仍是「执行中」；失败标记由终态（finalResult:true）承载。
      expect(content, contains('🧭 小智 · 工作模式 ｜ 执行中'));
      expect(content, isNot(contains('｜ 失败')));
      // 当前失败行以 ⏳ 呈现（非 ✅ 已完成行）。
      expect(content, contains('⏳ 步骤失败：路径冲突'));
      expect(content, isNot(contains('✅ 步骤失败')));
    });

    test('stepFailed (final) converts header to 失败 and line to ✅', () {
      final content = agentProgressMessageContent(
        characterName: '小智',
        progress: AgentRuntimeProgress(
          stage: AgentRuntimeProgressStage.stepFailed,
          executedRequests: [request],
          currentStepLabel: stepFailedLabel('路径冲突'),
        ),
        finalResult: true,
      );
      expect(content, contains('🧭 小智 · 工作模式 ｜ 失败'));
      expect(content, contains('✅ 步骤失败：路径冲突'));
      expect(content, isNot(contains('⏳')));
    });

    test('stepRejected shows the cancelled line while still executing', () {
      final content = agentProgressMessageContent(
        characterName: '小智',
        progress: AgentRuntimeProgress(
          stage: AgentRuntimeProgressStage.stepRejected,
          executedRequests: [request],
          currentStepLabel: stepRejectedLabel('workspace.patch'),
        ),
      );
      expect(content, contains('⏳ 已取消：workspace.patch'));
      // stepRejected 不是失败终态，头部仍显示执行中。
      expect(content, contains('｜ 执行中'));
      expect(content, isNot(contains('｜ 失败')));
    });
  });

  // (d) shouldRemoveProgress 各状态（仅 cancelled 删）。
  test('shouldRemoveProgress removes only cancelled', () {
    expect(
      WorkModeTaskLifecycle.shouldRemoveProgress(AgentTaskStatus.cancelled),
      isTrue,
    );
    expect(
      WorkModeTaskLifecycle.shouldRemoveProgress(AgentTaskStatus.completed),
      isFalse,
    );
    expect(
      WorkModeTaskLifecycle.shouldRemoveProgress(AgentTaskStatus.failed),
      isFalse,
    );
    expect(
      WorkModeTaskLifecycle.shouldRemoveProgress(
          AgentTaskStatus.partiallyCompleted),
      isFalse,
    );
    expect(
      WorkModeTaskLifecycle.shouldRemoveProgress(AgentTaskStatus.planning),
      isFalse,
    );
    expect(
      WorkModeTaskLifecycle.shouldRemoveProgress(AgentTaskStatus.runningTool),
      isFalse,
    );
    expect(
      WorkModeTaskLifecycle.shouldRemoveProgress(
          AgentTaskStatus.waitingForApproval),
      isFalse,
    );
  });

  // 共享协议层辅助函数。
  group('agent_progress_meta helpers', () {
    test('completedStepLabel derives readable labels per tool', () {
      const read = ToolRequest(
        tool: AgentToolName.workspaceRead,
        reason: '读',
        args: {'path': 'x.txt'},
      );
      const patch = ToolRequest(
        tool: AgentToolName.workspacePatch,
        reason: '写',
        args: {'path': 'y.html'},
      );
      const cmd = ToolRequest(
        tool: AgentToolName.commandRun,
        reason: '跑',
        args: {'command': 'ls'},
      );
      const browser = ToolRequest(
        tool: AgentToolName.browserContext,
        reason: '抓',
        args: {},
      );
      expect(completedStepLabel(read), '读取文件：x.txt');
      expect(completedStepLabel(patch), '已创建文件：y.html');
      expect(completedStepLabel(cmd), '执行命令：ls');
      expect(completedStepLabel(browser), '抓取浏览器上下文');
    });

    test('label formula helpers compose human-readable text', () {
      expect(thinkingLabel('规划任务步骤'), '正在规划任务步骤');
      expect(callingToolLabel('workspace.patch'), '正在调用工具：workspace.patch');
      expect(readingFileLabel('a.txt'), '正在读取文件：a.txt');
      expect(writingFileLabel('a.txt'), '正在写入文件：a.txt');
      expect(fileCreatedLabel('a.txt'), '已创建文件：a.txt');
      expect(validatingLabel('a.txt'), '正在校验结果：a.txt');
      expect(stepFailedLabel('路径冲突'), '步骤失败：路径冲突');
      expect(stepRejectedLabel('workspace.patch'), '已取消：workspace.patch');
      expect(waitingApprovalLabel('workspace.patch'), '等待批准：workspace.patch');
      // path 可选：带 path 时输出含「（path）」。
      expect(waitingApprovalLabel('workspace.patch', 'page.html'),
          '等待批准：workspace.patch（page.html）');
      // 空 path 等价于不传，不追加括号。
      expect(
          waitingApprovalLabel('workspace.patch', ''), '等待批准：workspace.patch');
    });

    test('stageLabelFallback covers every rendered stage', () {
      // toolCompleted 为聚合刷新阶段，不单独渲染当前行，故无兜底文案，需跳过。
      const skipped = {AgentRuntimeProgressStage.toolCompleted};
      for (final stage in AgentRuntimeProgressStage.values) {
        if (skipped.contains(stage)) continue;
        expect(stageLabelFallback[stage], isNotNull,
            reason: 'stage $stage should have a fallback label');
      }
      // 修复4（删 toolCompleted 死代码）正向断言：stageLabelFallback 必须已移除
      // toolCompleted 条目。若被误加回，chat_room_utils.dart 的 stageLabelFallback[stage]
      // 查找会取到 '步骤完成' 并错误渲染聚合刷新行为前的一行当前行。
      expect(
          stageLabelFallback[AgentRuntimeProgressStage.toolCompleted], isNull,
          reason: 'toolCompleted 不应存在于 stageLabelFallback');
    });

    test('statusHeader reflects final/success/failure tails', () {
      expect(
        statusHeader('小智', isFinal: false, failed: false),
        '🧭 小智 · 工作模式 ｜ 执行中',
      );
      expect(
        statusHeader('小智', isFinal: true, failed: false),
        '🧭 小智 · 工作模式 ｜ 已完成',
      );
      expect(
        statusHeader('小智', isFinal: true, failed: true),
        '🧭 小智 · 工作模式 ｜ 失败',
      );
    });
  });
}

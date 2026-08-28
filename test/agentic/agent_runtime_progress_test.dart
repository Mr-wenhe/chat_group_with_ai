import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/features/agentic/agent_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

/// P2 数据模型 + 时间戳注入测试。
///
/// 覆盖：AgentRuntimeProgress 新字段构造、旧构造兼容、run() 进度上报注入
/// runStartedAtMs / currentStepStartedAtMs。
void main() {
  // (1) 新字段构造：可带 runStartedAtMs / currentStepStartedAtMs。
  test('AgentRuntimeProgress accepts runStartedAtMs / currentStepStartedAtMs',
      () {
    const progress = AgentRuntimeProgress(
      stage: AgentRuntimeProgressStage.thinking,
      executedRequests: [],
      runStartedAtMs: 123456,
      currentStepStartedAtMs: 789012,
    );
    expect(progress.runStartedAtMs, 123456);
    expect(progress.currentStepStartedAtMs, 789012);
  });

  // (2) 旧构造兼容：不传新字段时默认 null，保持既有调用点零改动可编译。
  test('AgentRuntimeProgress old constructor keeps new fields null', () {
    const progress = AgentRuntimeProgress(
      stage: AgentRuntimeProgressStage.toolCompleted,
      executedRequests: [],
    );
    expect(progress.runStartedAtMs, isNull);
    expect(progress.currentStepStartedAtMs, isNull);
  });

  test('publicDetail is an optional safe execution-output field', () {
    const progress = AgentRuntimeProgress(
      stage: AgentRuntimeProgressStage.toolCompleted,
      executedRequests: [],
      publicDetail: '工具已完成：report.md',
    );
    expect(progress.publicDetail, '工具已完成：report.md');
  });

  // (3) run() 进度上报注入时间戳：onProgress 收到的 progress 携带非空
  // runStartedAtMs 与 currentStepStartedAtMs（P2 注入，不依赖具体工具执行）。
  test('run() injects runStartedAtMs and currentStepStartedAtMs on progress',
      () async {
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

    final captured = <AgentRuntimeProgress>[];
    final runtime = AgentRuntime(
      enableLocalFilePlanner: false,
      complete: (_) async => {'success': true, 'message': '好的'},
      onProgress: (p) async {
        captured.add(p);
      },
    );

    await runtime.run(
      character: character,
      skills: const [],
      userRequest: '随便聊聊',
    );

    // 至少收到一次进度上报（规划中），且每次都携带 P2 时间戳。
    expect(captured, isNotEmpty);
    for (final progress in captured) {
      expect(progress.runStartedAtMs, isNotNull);
      expect(progress.currentStepStartedAtMs, isNotNull);
    }
  });

  test('cancelled runtime does not emit a late progress checkpoint', () async {
    var progressCount = 0;
    final runtime = AgentRuntime(
      complete: (_) async => {'success': true, 'message': '不会执行'},
      onProgress: (_) async => progressCount += 1,
      shouldCancel: () => true,
    );
    final character = AICharacter(
      name: '取消测试角色',
      avatar: '',
      age: 18,
      role: '',
      personalityTags: const [],
      systemPrompt: '',
      apiKey: '',
      apiProvider: 'deepseek',
      toolPermissions: const [],
    );

    final result = await runtime.run(
      character: character,
      skills: const [],
      userRequest: '取消这次任务',
    );

    expect(result.status, AgentRuntimeStatus.failed);
    expect(progressCount, 0);
  });
}

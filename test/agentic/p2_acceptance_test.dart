import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/features/agentic/agent_progress_meta.dart';
import 'package:chat_group/features/agentic/agent_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

/// P2 独立验收补充测试。
///
/// 覆盖工程师 3 个新测试未直接触达、但验收点明确要求的关键场景：
///  1. [formatElapsed] 全程耗时格式化（含 ≥60s 的「Nm分ss秒」分支，原测试仅覆盖 <60s）。
///  2. [approvalTag] / [autoTag] 常量文案精确匹配（验收点 ② 的契约锚点）。
///  3. [AgentRuntime.run] 时间戳「单次捕获 → 全段一致」：所有进度上报携带
///     同一非空 runStartedAtMs（证明 _runStartedAtMs 仅捕获一次、幂等写入不漂移），
///     且每步切步均注入非空 currentStepStartedAtMs。
void main() {
  // —— 1. formatElapsed：<60s / =60s / >60s / 补零分支 ——
  group('formatElapsed formats total elapsed', () {
    test('under 60s → "Ns"', () {
      expect(formatElapsed(0), '0s');
      expect(formatElapsed(1), '1s');
      expect(formatElapsed(42), '42s');
      expect(formatElapsed(59), '59s');
    });

    test('exactly 60s → "1分00秒" (seconds zero-padded)', () {
      expect(formatElapsed(60), '1分00秒');
    });

    test('over 60s → "Nm分ss秒" with zero-padded seconds', () {
      expect(formatElapsed(65), '1分05秒');
      expect(formatElapsed(125), '2分05秒');
      expect(formatElapsed(600), '10分00秒');
      expect(formatElapsed(3599), '59分59秒');
    });
  });

  // —— 2. 批准态文案常量契约 ——
  group('approval tag constants', () {
    test('approvalTag / autoTag exact strings', () {
      expect(approvalTag, ' · 需批准');
      expect(autoTag, ' · 自动');
    });
  });

  // —— 3. run() 时间戳单次捕获、全段一致、不漂移 ——
  test(
      'run() captures runStartedAtMs once and keeps it identical across all '
      'progress reports (idempotent write cannot drift)', () async {
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
      onProgress: (p) async => captured.add(p),
    );

    await runtime.run(
      character: character,
      skills: const [],
      userRequest: '随便聊聊',
    );

    // run() 至少上报一次（规划中）。
    expect(captured, isNotEmpty);

    // 所有上报的 runStartedAtMs 均非空且彼此相等（单次捕获，不漂移）。
    final firstStart = captured.first.runStartedAtMs;
    expect(firstStart, isNotNull);
    for (final progress in captured) {
      expect(progress.runStartedAtMs, equals(firstStart),
          reason: 'runStartedAtMs 在整段任务中应保持同一捕获值');
      expect(progress.currentStepStartedAtMs, isNotNull,
          reason: '每次切步都应注入非空 currentStepStartedAtMs');
    }
  });
}

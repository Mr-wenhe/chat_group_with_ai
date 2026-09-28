import 'package:chat_group/features/agentic/context_window_manager.dart';
import 'package:chat_group/features/work_mode/default_work_task_runner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('workModeRequestOutputTokens', () {
    test('honours a declared capability larger than 8192', () {
      // 曾经这里硬性截到 8192：用户在设置里声明的大输出模型会被静默压住。
      expect(
        workModeRequestOutputTokens(
          capabilityMaxOutput: 20000,
          capabilityContextWindow: 1000000,
        ),
        20000,
      );
    });

    test('never exceeds half the context window', () {
      // 8k 窗口的模型若按声明值要 8k 输出，输入预算会被压到 0，请求会带着空
      // messages 发出去（inputBudget 的守卫比的是声明值，输入为 0 时拦不住）。
      expect(
        workModeRequestOutputTokens(
          capabilityMaxOutput: 8192,
          capabilityContextWindow: 8192,
        ),
        4096,
      );
      expect(
        ContextWindowManager.inputBudget(contextWindow: 8192, maxOutput: 4096),
        greaterThan(0),
      );
    });

    test('caps a declaration that exceeds any vendor limit', () {
      // 声明值不会被上游校验，只能在请求侧挡一道，免得直接收到 400。
      expect(
        workModeRequestOutputTokens(
          capabilityMaxOutput: 200000,
          capabilityContextWindow: 1000000,
        ),
        maxWorkRequestOutputTokens,
      );
    });

    test('keeps a positive floor for degenerate capabilities', () {
      expect(
        workModeRequestOutputTokens(
          capabilityMaxOutput: 0,
          capabilityContextWindow: 0,
        ),
        1,
      );
    });
  });
}

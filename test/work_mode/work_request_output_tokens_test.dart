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

    test('honours a declaration beyond the old absolute ceiling', () {
      // 32768 绝对天花板已删除：它压住的是用户手工声明的大输出模型，而声明值
      // 本来就只由设置决定，"声明多少就发多少"的责任交回那份声明。
      expect(
        workModeRequestOutputTokens(
          capabilityMaxOutput: 200000,
          capabilityContextWindow: 1000000,
        ),
        200000,
      );
      expect(
        workModeRequestOutputTokens(
          capabilityMaxOutput: 65536,
          capabilityContextWindow: 262144,
        ),
        65536,
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

    test('glm-4.7 不再被天花板压住，代价是输入预算被压缩', () {
      // 删掉 32768 绝对天花板后，内置表里唯一声明超过它的模型（glm-4.7 /
      // glm4.7，窗口 200000 / 输出 131072）拿到了更大的输出空间，代价是输入
      // 预算被反向压缩。这条用例把这次分配变化显式化：将来再有人动预算口径，
      // 这两个数码就会报警，而不是悄悄改掉。
      expect(
        workModeRequestOutputTokens(
          capabilityMaxOutput: 131072,
          capabilityContextWindow: 200000,
        ),
        100000,
      );
      expect(
        workModeRequestInputBudget(
          capabilityMaxOutput: 131072,
          capabilityContextWindow: 200000,
        ),
        99744,
      );
    });
  });
}

import 'package:chat_group/features/agentic/context_window_manager.dart';
import 'package:chat_group/features/work_mode/default_work_task_runner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('workModeOutputReservationTokens', () {
    test('reserves the declared model output for input sizing', () {
      expect(
        workModeOutputReservationTokens(
          capabilityMaxOutput: 20000,
          capabilityContextWindow: 1000000,
        ),
        20000,
      );
    });

    test('reserves at most half the context window to keep prompt space', () {
      expect(
        workModeOutputReservationTokens(
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

    test('reserves declarations beyond the old absolute ceiling', () {
      expect(
        workModeOutputReservationTokens(
          capabilityMaxOutput: 200000,
          capabilityContextWindow: 1000000,
        ),
        200000,
      );
      expect(
        workModeOutputReservationTokens(
          capabilityMaxOutput: 65536,
          capabilityContextWindow: 262144,
        ),
        65536,
      );
    });

    test('keeps a positive floor for degenerate capabilities', () {
      expect(
        workModeOutputReservationTokens(
          capabilityMaxOutput: 0,
          capabilityContextWindow: 0,
        ),
        1,
      );
    });

    test('glm-4.7 input reservation remains bounded by half its context', () {
      expect(
        workModeOutputReservationTokens(
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

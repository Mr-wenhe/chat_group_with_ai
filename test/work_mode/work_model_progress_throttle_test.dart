import 'package:chat_group/features/work_mode/work_model_progress_throttle.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('keeps token-level model output from flooding durable progress events',
      () {
    final throttle = WorkModelProgressThrottle();
    final start = DateTime.utc(2026, 9, 11, 10);

    expect(
      throttle.shouldPublish(streamedCharacters: 1, now: start),
      isTrue,
    );
    expect(
      throttle.shouldPublish(streamedCharacters: 160, now: start),
      isFalse,
    );
    expect(
      throttle.shouldPublish(
        streamedCharacters: 161,
        now: start.add(const Duration(milliseconds: 249)),
      ),
      isFalse,
    );
    expect(
      throttle.shouldPublish(
        streamedCharacters: 162,
        now: start.add(const Duration(milliseconds: 250)),
      ),
      isTrue,
    );
  });
}

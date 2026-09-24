import 'package:flutter_test/flutter_test.dart';

/// Drives frames while giving real asynchronous work a chance to finish, until
/// [ready] reports the state the test is about to assert on.
///
/// `tester.runAsync(() => Future.delayed(...))` followed by a fixed-duration
/// `tester.pump(...)` is a race: a widget that reads Hive, resolves providers
/// or talks to a platform channel needs real time, and how much it needs varies
/// with machine load. Under a full parallel suite the guessed delay is
/// sometimes too short, so the assertion observes a half-built tree. Poll for
/// the condition instead of guessing a duration.
Future<void> pumpUntilReady(
  WidgetTester tester,
  bool Function() ready, {
  Duration step = const Duration(milliseconds: 25),
  int maxAttempts = 80,
}) async {
  for (var attempt = 0; attempt < maxAttempts; attempt++) {
    if (ready()) return;
    await tester.runAsync(() => Future<void>.delayed(step));
    await tester.pump();
  }
}

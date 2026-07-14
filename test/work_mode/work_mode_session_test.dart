import 'package:chat_group/features/work_mode/work_mode_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('disabling work mode cancels the active request immediately', () {
    final session = WorkModeSession<String>()..setEnabled(true);
    final token = session.beginRun();

    session.setEnabled(false);

    expect(session.isStopRequested, isTrue);
    expect(token.isCancelled, isTrue);
    expect(session.activeCancelToken, isNull);
  });

  test('pending approval has one owner and can be cleared atomically', () {
    final session = WorkModeSession<String>();
    session.pendingApproval = 'approval-1';

    expect(session.takePendingApproval(), 'approval-1');
    expect(session.pendingApproval, isNull);
  });

  test('finishing an old run does not clear a newer cancellation token', () {
    final session = WorkModeSession<String>()..setEnabled(true);
    final first = session.beginRun();
    final second = session.beginRun();

    session.finishRun(first);

    expect(first.isCancelled, isTrue);
    expect(session.activeCancelToken, same(second));
  });
}

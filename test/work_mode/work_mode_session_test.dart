import 'package:chat_group/features/work_mode/work_mode_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('disabling work mode cancels the active run immediately', () {
    final session = WorkModeSession<String>()..setEnabled(true);
    final run = session.beginRun();

    session.setEnabled(false);

    // 每次 run 独立持有自己的停止状态与取消令牌。
    expect(run.isRequestedStop, isTrue);
    expect(run.token.isCancelled, isTrue);
    // 关闭后没有活跃 run：取消判定交由页面闭包（workModeRun?.isRequestedStop
    // ?? false）保守处理，session 不再提供 shouldCancel() 方法。
  });

  test('pending approval has one owner and can be cleared atomically', () {
    final session = WorkModeSession<String>();
    session.pendingApproval = 'approval-1';

    expect(session.takePendingApproval(), 'approval-1');
    expect(session.pendingApproval, isNull);
  });

  test('finishing an old run does not clear a newer run', () {
    final session = WorkModeSession<String>()..setEnabled(true);
    final first = session.beginRun();
    final second = session.beginRun();

    session.finishRun(first);

    // 新 run 启动时已取消旧 run 的 token，但只影响旧 run 自己。
    expect(first.token.isCancelled, isTrue);
    // 第二个 run 仍是活跃 run，未被误清理——其停止状态未被误置。
    expect(second.isRequestedStop, isFalse);
    expect(second.token.isCancelled, isFalse);
  });

  test('per-run cancellation: stopping an old run does not revive a new run',
      () {
    final session = WorkModeSession<String>()..setEnabled(true);
    final oldRun = session.beginRun();
    final newRun = session.beginRun();

    // 旧 run 被显式停止（例如用户点停止），新 run 不受影响。
    oldRun.requestStop('用户停止');
    expect(oldRun.isRequestedStop, isTrue);
    expect(oldRun.token.isCancelled, isTrue);
    expect(newRun.isRequestedStop, isFalse);
    expect(newRun.token.isCancelled, isFalse);
  });
}

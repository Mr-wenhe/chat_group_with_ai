import 'package:chat_group/features/work_mode/work_mode_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('stores only the chat-room work-mode switch', () {
    final session = WorkModeSession();

    expect(session.enabled, isFalse);

    session.setEnabled(true);
    expect(session.enabled, isTrue);

    session.setEnabled(false);
    expect(session.enabled, isFalse);
  });
}

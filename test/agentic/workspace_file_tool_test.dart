import 'package:chat_group/features/agentic/tools/workspace_file_tool.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('workspace paths cannot escape root', () {
    expect(WorkspacePathGuard.isSafeRelativePath('lib/main.dart'), isTrue);
    expect(WorkspacePathGuard.isSafeRelativePath('../secret.txt'), isFalse);
    expect(WorkspacePathGuard.isSafeRelativePath('/etc/passwd'), isFalse);
  });
}

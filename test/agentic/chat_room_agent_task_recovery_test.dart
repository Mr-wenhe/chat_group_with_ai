import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('task recovery registers its workspace before either resume branch', () {
    final source = File(
      'lib/features/chat_group/chat_room_page.dart',
    ).readAsStringSync();
    final start = source.indexOf('Future<void> _resumeAgentTask');
    final end = source.indexOf(
      'List<ToolRequest> _restoredExecutedRequests',
      start,
    );
    expect(start, isNonNegative);
    expect(end, greaterThan(start));

    final resumeBody = source.substring(start, end);
    final workModeGuard = resumeBody.indexOf(
      'if (!_workModeEnabled || !task.workModeTask) return;',
    );
    final loadWorkspace = resumeBody.indexOf(
      'WorkModeWorkspaceService(db: _db).loadOrCreate(',
    );
    final registerWorkspace = resumeBody.indexOf(
      'LocalAgentBridgeLauncher().registerWorkspace(',
    );
    final pendingBranch = resumeBody.indexOf(
      'ToolRequest.fromJsonString(task.pendingToolRequestJson)',
    );

    expect(workModeGuard, inInclusiveRange(0, loadWorkspace - 1));
    expect(loadWorkspace, inInclusiveRange(0, registerWorkspace - 1));
    expect(registerWorkspace, inInclusiveRange(0, pendingBranch - 1));
  });
}

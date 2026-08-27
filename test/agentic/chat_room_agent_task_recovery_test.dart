import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('task recovery registers its workspace before either resume branch', () {
    final source = File(
      'lib/features/chat_group/chat_room_agentic_support.dart',
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
    final beginConversationWork = resumeBody.indexOf(
      '_conversationController.beginWork()',
    );
    final beginRun = resumeBody.indexOf('_workModeSession.beginRun()');
    final finishAndDispatch = resumeBody.indexOf(
      '_finishWorkActivityAndDispatchNext()',
    );

    expect(workModeGuard, inInclusiveRange(0, loadWorkspace - 1));
    expect(loadWorkspace, inInclusiveRange(0, registerWorkspace - 1));
    expect(registerWorkspace, inInclusiveRange(0, pendingBranch - 1));
    expect(pendingBranch, inInclusiveRange(0, beginConversationWork - 1));
    expect(beginConversationWork, inInclusiveRange(0, beginRun - 1));
    expect(finishAndDispatch, greaterThan(beginRun));
  });

  test('work mode rechecks lifecycle after every workspace await', () {
    final source = File(
      'lib/features/chat_group/chat_room_agentic_input_support.dart',
    ).readAsStringSync();
    final start = source.indexOf('Future<void> _runWorkModeTask');
    final end = source.indexOf(
      'Future<void> _finishWorkActivityAndDispatchNext',
      start,
    );
    expect(start, isNonNegative);
    expect(end, greaterThan(start));

    final body = source.substring(start, end);
    final loadWorkspace = body.indexOf(
      'WorkModeWorkspaceService(db: _db).loadOrCreate(',
    );
    final firstLifecycleGuard = body.indexOf(
      'if (!_canTouchUi || !_workModeEnabled || workModeRun.isRequestedStop)',
      loadWorkspace,
    );
    final registerWorkspace = body.indexOf(
      'LocalAgentBridgeLauncher().registerWorkspace(',
    );
    final secondLifecycleGuard = body.indexOf(
      'if (!_canTouchUi || !_workModeEnabled || workModeRun.isRequestedStop)',
      registerWorkspace,
    );
    final generateReply = body.indexOf('_generateAgenticReply(');

    expect(firstLifecycleGuard,
        inInclusiveRange(loadWorkspace, registerWorkspace - 1));
    expect(secondLifecycleGuard,
        inInclusiveRange(registerWorkspace, generateReply - 1));
  });
}

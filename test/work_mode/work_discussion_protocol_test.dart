import 'dart:convert';

import 'package:chat_group/features/work_mode/work_discussion_protocol.dart';
import 'package:chat_group/features/work_mode/work_discussion_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('structured multiline prose fits the durable field limits', () {
    final turn = WorkDiscussionTurn.fromResponse({
      'content': jsonEncode({
        'public_update': '结论一\n结论二${'字' * 1100}',
        'understanding_percent': 40,
        'understanding_evidence': ['目标\n范围'],
        'open_questions': ['位置\n格式'],
        'blockers': <String>[],
        'user_question': '请确认\n${'字' * 300}',
      }),
    });
    expect(turn.valid, isTrue);
    final state = WorkDiscussionState.initial(conversationId: 'group').copyWith(
      understandingPercent: turn.understandingPercent,
      decisionSummary: turn.publicUpdate,
      understandingEvidence: turn.understandingEvidence,
      openQuestions: [...turn.openQuestions, turn.userQuestion],
    );
    expect(state.isWithinBounds, isTrue);
    expect(turn.publicUpdate.length, 1024);
    expect(turn.publicUpdate, isNot(contains('\n')));
  });
}

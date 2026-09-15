import 'dart:convert';

import 'package:chat_group/features/work_mode/work_discussion_protocol.dart';
import 'package:chat_group/features/work_mode/work_discussion_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('extracts a valid protocol object wrapped in short model prose', () {
    final turn = WorkDiscussionTurn.fromResponse({
      'content': '好的，以下是本轮结果：\n${jsonEncode({
            'public_update': '建议补充可用性验收。',
            'understanding_percent': 40,
            'understanding_evidence': ['已明确目标范围'],
            'open_questions': <String>[],
            'resolved_questions': <String>[],
            'blockers': <String>[],
            'resolved_blockers': <String>[],
            'substantive_progress': true,
            'needs_user': false,
            'user_question': '',
          })}',
    });

    expect(turn.valid, isTrue);
    expect(turn.publicUpdate, '建议补充可用性验收。');
    expect(turn.understandingPercent, 40);
  });

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

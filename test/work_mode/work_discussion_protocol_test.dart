import 'dart:convert';

import 'package:chat_group/features/work_mode/work_discussion_protocol.dart';
import 'package:chat_group/features/work_mode/work_discussion_state.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _contractWithScope(String scope) => <String, dynamic>{
      'deliverableType': 'document',
      'format': 'docx',
      'location': 'desktop',
      'contentScope': scope,
      'explicitExecutorId': 'front',
      'revisionTarget': '',
      'requestRevision': 1,
    };

Map<String, dynamic> _turnWithContract(Map<String, dynamic> contract) =>
    <String, dynamic>{
      'content': jsonEncode(<String, dynamic>{
        'public_update': '方案已确认。',
        'understanding_percent': 60,
        'understanding_evidence': <String>['目标范围已确认'],
        'open_questions': <String>[],
        'resolved_questions': <String>[],
        'blockers': <String>[],
        'resolved_blockers': <String>[],
        'substantive_progress': true,
        'needs_user': false,
        'contract': contract,
      }),
    };

void main() {
  test('normalizes gateway HTTP failures without disguising them as bad JSON',
      () {
    final turn = WorkDiscussionTurn.fromResponse({
      'success': false,
      'statusCode': 401,
      'message': 'HTTP 401 请求失败',
    });

    expect(turn.valid, isFalse);
    expect(turn.failureReason, '模型请求失败（HTTP 401）');
  });

  test('flags an empty model completion as retryable, not as a bad reply', () {
    final turn = WorkDiscussionTurn.fromResponse({
      'success': false,
      'message': '模型返回了空内容',
      'failureCode': 'emptyResponse',
      'retryable': true,
    });

    expect(turn.valid, isFalse);
    expect(turn.emptyCompletion, isTrue);
    expect(turn.failureReason, '模型返回了空内容');

    final providerFailure = WorkDiscussionTurn.fromResponse({
      'success': false,
      'statusCode': 503,
      'message': 'HTTP 503 服务不可用',
    });
    expect(providerFailure.emptyCompletion, isFalse);
  });

  test('describes the upstream stop signal kept with an empty completion', () {
    expect(
      describeEmptyCompletion(const <String, Object?>{
        'finishReason': 'length',
        'completionTokens': 4096,
        'reasoningTokens': 4096,
      }),
      '（上游信号：finishReason=length，completionTokens=4096，reasoningTokens=4096）',
    );
    expect(describeEmptyCompletion(null), '');
    expect(describeEmptyCompletion(const <String, Object?>{}), '');
  });

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

  test('honors the caller budget instead of the live draft cap', () {
    final opinion = '字' * 1500;

    expect(boundedDiscussionText(opinion, maximum: 2400), opinion);
  });

  test('states that text was cut and how long the original was', () {
    final bounded = boundedDiscussionText('字' * 3000, maximum: 2400);

    expect(bounded.length, lessThanOrEqualTo(2400));
    expect(bounded, startsWith('字'));
    expect(bounded, endsWith('（已截断，原文 3000 字）'));
  });

  test('marks a member opinion cut by the durable field limit', () {
    final turn = WorkDiscussionTurn.fromResponse({
      'content': jsonEncode({
        'public_update': '字' * 3000,
        'understanding_percent': 40,
        'understanding_evidence': ['目标范围已确认'],
        'open_questions': <String>[],
        'resolved_questions': <String>[],
        'blockers': <String>[],
        'resolved_blockers': <String>[],
        'substantive_progress': true,
        'needs_user': false,
      }),
    });

    expect(turn.valid, isTrue);
    expect(turn.publicUpdate.length, lessThanOrEqualTo(1024));
    expect(turn.publicUpdate, endsWith('（已截断，原文 3000 字）'));
  });

  test('marks a contract scope cut by the field limit', () {
    final turn = WorkDiscussionTurn.fromResponse(
      _turnWithContract(_contractWithScope('字' * 5000)),
    );

    expect(turn.valid, isTrue);
    final scope = turn.contractPatch?['contentScope'] as String?;
    expect(scope, isNotNull);
    expect(scope!.length, lessThanOrEqualTo(4096));
    expect(scope, endsWith('（已截断，原文 5000 字）'));
  });

  test('keeps a contract scope up to the durable state limit', () {
    final scope = '范围' * 2000;
    final turn = WorkDiscussionTurn.fromResponse(
      _turnWithContract(_contractWithScope(scope)),
    );

    expect(turn.valid, isTrue);
    expect(turn.contractPatch?['contentScope'], scope);

    final state = WorkDiscussionState.initial(conversationId: 'group')
        .copyWith(deliverableContract: turn.contractPatch);
    expect(state.isWithinBounds, isTrue);
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

import 'dart:convert';

import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/work_mode/work_context_builder.dart';
import 'package:chat_group/features/work_mode/work_discussion_state.dart';
import 'package:flutter_test/flutter_test.dart';

WorkDiscussionState _readyState({
  String conversationId = 'group-a',
  int requestRevision = 1,
  int understandingPercent = 100,
  List<String> openQuestions = const [],
  List<String> blockers = const [],
}) {
  final pending = WorkDiscussionState.initial(
    conversationId: conversationId,
    requestRevision: requestRevision,
    executorId: 'worker',
    candidateCharacterIds: const ['worker'],
    participantCharacterIds: const ['worker'],
    deliverableContract: <String, dynamic>{
      'deliverableType': 'document',
      'format': 'docx',
      'location': 'desktop',
      'contentScope': '输出需求文档',
      'explicitExecutorId': 'worker',
      'revisionTarget': '',
      'requestRevision': requestRevision,
    },
  );
  return pending.copyWith(
    phase: WorkDiscussionPhase.ready,
    understandingPercent: understandingPercent,
    understandingEvidence: const ['执行人已复述目标、格式和位置。'],
    openQuestions: openQuestions,
    blockers: blockers,
  );
}

void main() {
  test('encodes a bounded versioned state and preserves unrelated metadata',
      () {
    final state = _readyState();
    final raw = WorkDiscussionState.mergeIntoExecutionState(
      jsonEncode(<String, dynamic>{
        'approvalScope': <String, dynamic>{'taskId': 'approval-a'},
        'attachmentMessageId': 'message-a',
      }),
      state,
    );
    final decoded = WorkDiscussionState.decodeExecutionState(raw);
    expect(decoded.isValid, isTrue);
    expect(decoded.state!.isExecutionReady, isTrue);
    expect(decoded.state!.deliverableContract!['format'], 'docx');
    final metadata = jsonDecode(raw) as Map<String, dynamic>;
    expect(metadata['approvalScope'], isNotNull);
    expect(metadata['attachmentMessageId'], 'message-a');
  });

  test('rejects malformed, future-version, and invalid-percent markers', () {
    final base = _readyState().toJson();
    expect(
      WorkDiscussionState.decodeExecutionState(
        jsonEncode(<String, dynamic>{'discussionState': <String, dynamic>{}}),
      ).isValid,
      isFalse,
    );
    expect(
      WorkDiscussionState.tryParse(<String, dynamic>{
        ...base,
        'schemaVersion': 99,
      }),
      isNull,
    );
    expect(
      WorkDiscussionState.tryParse(<String, dynamic>{
        ...base,
        'understandingPercent': 101,
      }),
      isNull,
    );
    for (final key in const <String>[
      'candidateCharacterIds',
      'understandingEvidence',
      'openQuestions',
      'blockers',
    ]) {
      final missing = Map<String, dynamic>.from(base)..remove(key);
      expect(WorkDiscussionState.tryParse(missing), isNull, reason: key);
    }
    expect(
      WorkDiscussionState.tryParse(<String, dynamic>{
        ...base,
        'participants': [
          <String, dynamic>{'characterId': 'worker', 'contributionCount': -1},
        ],
      }),
      isNull,
    );
    expect(
      WorkDiscussionState.tryParse(<String, dynamic>{
        ...base,
        'candidateCharacterIds': const <String>[],
      })!
          .isExecutionReady,
      isFalse,
    );
    expect(
      WorkDiscussionState.tryParse(<String, dynamic>{
        ...base,
        'conversationId': 'group-\u0000a',
      }),
      isNull,
    );
  });

  test('rejects fractional gate numbers instead of truncating them', () {
    final base = _readyState().toJson();
    expect(
      WorkDiscussionState.tryParse(<String, dynamic>{
        ...base,
        'requestRevision': 0,
      }),
      isNull,
    );
    for (final entry in const <String, num>{
      'schemaVersion': 1.5,
      'requestRevision': 1.5,
      'round': 1.5,
      'understandingPercent': 99.5,
    }.entries) {
      expect(
        WorkDiscussionState.tryParse(<String, dynamic>{
          ...base,
          entry.key: entry.value,
        }),
        isNull,
        reason: entry.key,
      );
    }
    expect(
      WorkDiscussionState.tryParse(<String, dynamic>{
        ...base,
        'participants': [
          <String, dynamic>{
            'characterId': 'worker',
            'contributionCount': 1.5,
          },
        ],
      }),
      isNull,
    );
    expect(
      WorkDiscussionState.tryParse(<String, dynamic>{
        ...base,
        'deliverableContract': {
          ...Map<String, dynamic>.from(base['deliverableContract'] as Map),
          'requestRevision': 1.5,
        },
      }),
      isNull,
    );
    expect(
      WorkDiscussionState.tryParse(<String, dynamic>{
        ...base,
        'deliverableContract': {
          ...Map<String, dynamic>.from(base['deliverableContract'] as Map),
          'requestRevision': 0,
        },
      }),
      isNull,
    );
  });

  test('rejects duplicate candidate or participant identities', () {
    final base = _readyState().toJson();
    expect(
      WorkDiscussionState.tryParse(<String, dynamic>{
        ...base,
        'candidateCharacterIds': const ['worker', 'worker'],
      }),
      isNull,
    );
    expect(
      WorkDiscussionState.tryParse(<String, dynamic>{
        ...base,
        'participants': [
          <String, dynamic>{'characterId': 'worker'},
          <String, dynamic>{'characterId': 'worker'},
        ],
      }),
      isNull,
    );
  });

  test('rejects out-of-range in-memory values before bounded conversion', () {
    final base = _readyState();
    final invalid = WorkDiscussionState(
      conversationId: base.conversationId,
      phase: WorkDiscussionPhase.ready,
      requestRevision: 1,
      executorId: 'worker',
      candidateCharacterIds: const ['worker'],
      participants: base.participants,
      understandingPercent: 101,
      understandingEvidence: const ['已确认需求'],
      deliverableContract: base.deliverableContract,
    );

    expect(invalid.isWithinBounds, isFalse);
    expect(invalid.isExecutionReady, isFalse);
    final copiedInvalid = base.copyWith(understandingPercent: 101);
    expect(copiedInvalid.isWithinBounds, isFalse);
    expect(copiedInvalid.isExecutionReady, isFalse);
    expect(
      copiedInvalid.compactForContext().isExecutionReady,
      isFalse,
    );
    expect(
      () => WorkDiscussionState.mergeIntoExecutionState('', copiedInvalid),
      throwsStateError,
    );
  });

  test(
      'rejects overlong persisted discussion fields instead of truncating them',
      () {
    final base = _readyState().toJson();
    expect(
      WorkDiscussionState.tryParse(<String, dynamic>{
        ...base,
        'decisionSummary': 'x' * 1025,
      }),
      isNull,
    );
    expect(
      WorkDiscussionState.tryParse(<String, dynamic>{
        ...base,
        'understandingEvidence': ['x' * 513],
      }),
      isNull,
    );
    expect(
      WorkDiscussionState.tryParse(<String, dynamic>{
        ...base,
        'deliverableContract': {
          ...Map<String, dynamic>.from(base['deliverableContract'] as Map),
          'contentScope': 'x' * 4097,
        },
      }),
      isNull,
    );
  });

  test(
      'ready state requires a matching contract and supports clearing executor',
      () {
    final state = _readyState();
    expect(
      state.copyWith(
        deliverableContract: {
          ...state.deliverableContract!,
          'requestRevision': 2,
        },
      ).isExecutionReady,
      isFalse,
    );
    final withoutExecutor = state.copyWith(
      clearExecutorId: true,
      phase: WorkDiscussionPhase.awaitingExecutor,
    );
    expect(withoutExecutor.executorId, isNull);
    expect(withoutExecutor.isExecutionReady, isFalse);
  });

  test('ready state requires a non-empty content scope', () {
    final state = _readyState();
    expect(
      state.copyWith(
        deliverableContract: {
          ...state.deliverableContract!,
          'contentScope': '',
        },
      ).isExecutionReady,
      isFalse,
    );
  });

  test(
      'ready state requires concrete format, location, and optional executor pin',
      () {
    final state = _readyState();
    expect(
      state.copyWith(
        deliverableContract: {
          ...state.deliverableContract!,
          'format': 'unspecified',
        },
      ).isExecutionReady,
      isFalse,
    );
    expect(
      state.copyWith(
        deliverableContract: {
          ...state.deliverableContract!,
          'location': 'unspecified',
        },
      ).isExecutionReady,
      isFalse,
    );
    // A null pin represents the role elected by the group; the selected
    // executor is still required in the discussion state itself.
    expect(
      state.copyWith(
        deliverableContract: {
          ...state.deliverableContract!,
          'explicitExecutorId': null,
        },
      ).isExecutionReady,
      isTrue,
    );
  });

  test('compact context keeps the elected executor and stays bounded', () {
    final candidates = List<String>.generate(20, (index) => 'role-$index');
    final pending = WorkDiscussionState.initial(
      conversationId: 'group-many-roles',
      executorId: 'role-19',
      candidateCharacterIds: candidates,
      participantCharacterIds: candidates,
      deliverableContract: {
        'deliverableType': 'document',
        'format': 'docx',
        'location': 'desktop',
        'contentScope': List.filled(4000, '需求').join(),
        'explicitExecutorId': 'role-19',
        'revisionTarget': '',
        'requestRevision': 1,
      },
    );
    final ready = pending.copyWith(
      phase: WorkDiscussionPhase.ready,
      understandingPercent: 100,
      understandingEvidence: const ['已确认目标、格式和位置。'],
      blockers: const [],
    );
    final compact = ready.compactForContext();
    expect(compact.candidateCharacterIds, contains('role-19'));
    expect(compact.isExecutionReady, isTrue);
    final context = const WorkContextBuilder(maxCharacters: 900).build(
      conversationId: 'group-many-roles',
      target: '生成文档',
      discussionState: ready,
    );
    expect(context.toJsonString().length, lessThanOrEqualTo(900));
  });

  test('execution marker wins over a stale compressed context copy', () {
    final task = AgentTask(
      id: 'context-authority',
      groupId: 'group-a',
      characterId: 'worker',
      userRequest: '完成 Word 需求文档',
      workModeTask: true,
    );
    const builder = WorkContextBuilder();
    final pending = WorkDiscussionState.initial(
      conversationId: task.groupId,
      executorId: 'worker',
      candidateCharacterIds: const ['worker'],
      participantCharacterIds: const ['worker'],
      deliverableContract: _readyState().deliverableContract,
    );
    task.contextSummary = builder
        .build(
          conversationId: task.groupId,
          target: task.userRequest,
          discussionState: pending,
        )
        .toJsonString();
    final ready = _readyState();
    task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
      '',
      ready,
    );

    final restored = builder.fromTask(task);
    expect(restored.discussionState, isNotNull);
    expect(restored.discussionState!.phase, WorkDiscussionPhase.ready);
    expect(restored.discussionState!.understandingPercent, 100);
  });

  test('context compression retains the discussion gate and contract',
      () async {
    const builder = WorkContextBuilder(maxCharacters: 900);
    final state = _readyState(
      openQuestions: const [],
      blockers: const [],
    );
    final source = builder.build(
      conversationId: 'group-a',
      target: '完成 Word 需求文档',
      pendingFollowUps: [List.filled(600, '追问').join()],
      completedSummaries: [List.filled(600, '摘要').join()],
      errors: [List.filled(600, '错误').join()],
      discussionState: state,
    );
    final compressed = await builder.compress(
      source,
      model: (_) async => WorkContextSnapshot(
        conversationId: 'group-a',
        target: '不可信目标',
      ),
    );
    expect(compressed.discussionState, isNotNull);
    expect(compressed.discussionState!.phase, WorkDiscussionPhase.ready);
    expect(compressed.discussionState!.understandingPercent, 100);
    expect(
      compressed.discussionState!.deliverableContract!['format'],
      'docx',
    );
    expect(compressed.discussionState!.executorId, 'worker');
  });
}

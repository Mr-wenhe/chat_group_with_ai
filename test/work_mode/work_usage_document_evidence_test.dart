import 'dart:convert';

import 'package:chat_group/features/work_mode/agent_decision.dart';
import 'package:chat_group/features/work_mode/work_usage_feedback.dart';
import 'package:chat_group/features/work_mode/work_usage_receipt.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('相同摘要在不同候选路径上保留独立正文使用观察', () {
    WorkUsageObservation observation(String path, String ref) =>
        WorkUsageObservation(
          taskId: 'task',
          conversationId: 'group',
          actorId: 'reviewer',
          scenarioId: 'read-documents',
          iterationId: 'r001',
          artifactDigest: 'b' * 64,
          planDigest: 'c' * 64,
          verificationRevision: 2,
          runtime: 'document',
          sessionRef: 'document:task:reviewer:$ref',
          operation: 'body-read',
          beforeRef: 'a' * 64,
          afterRef: ref * 64,
          outputRefs: ['document:$ref.json'],
          documentFileName: 'report.docx',
          documentPath: path,
          documentDigest: 'a' * 64,
          chunkIndexes: const [0],
          chunkCount: 1,
          sourceLocations: const [
            {'fileName': 'report.docx', 'paragraph': 1}
          ],
        );
    final first = observation('a/report.docx', 'd');
    final second = observation('b/report.docx', 'e');
    expect(first.duplicatesDocumentUse(second), isFalse);
    expect(
        first.duplicatesDocumentUse(observation('a/report.docx', 'd')), isTrue);
  });

  test('document feedback validates locations and preserves blocked status',
      () {
    final feedback = {
      'method': '逐页检查冻结候选的正文与排版',
      'result': 'passed',
      'acceptanceIds': ['layout'],
      'report': '四页均已检查，跨页表头与正文可读。',
      'defects': <Map<String, dynamic>>[],
      'documentEvidence': {
        'pageNumbers': [1, 2],
        'sourceLocations': [
          {'fileName': 'review.pdf', 'page': 1},
          {'fileName': 'review.pdf', 'page': 2},
        ],
      },
    };
    AgentFinishCompletion completion() => AgentFinishCompletion(
          summary: '本人检查了当前候选。',
          evidence: [jsonEncode(feedback)],
        );

    expect(
      parseWorkUsageFeedback(completion(),
          acceptanceIds: const ['layout'], requireDocumentEvidence: true),
      isNotNull,
    );
    final bodyOnly = jsonDecode(jsonEncode(feedback)) as Map;
    (bodyOnly['documentEvidence'] as Map)
      ..['pageNumbers'] = <int>[]
      ..['sourceLocations'] = [
        {'fileName': 'review.docx', 'paragraph': 3},
      ];
    final bodyOnlyCompletion = AgentFinishCompletion(
        summary: '本人读取了指定正文。', evidence: [jsonEncode(bodyOnly)]);
    expect(
      parseWorkUsageFeedback(bodyOnlyCompletion,
          acceptanceIds: const ['layout'], requireDocumentEvidence: true),
      isNotNull,
      reason: '正文角色以段落位置引用 DOCX 时没有视觉页码。',
    );
    expect(
      parseWorkUsageFeedback(bodyOnlyCompletion,
          acceptanceIds: const ['layout'],
          requireDocumentEvidence: true,
          requireDocumentPages: true),
      isNull,
      reason: '视觉角色缺少页码时不能声称通过。',
    );
    final missingLocation = jsonDecode(jsonEncode(feedback)) as Map;
    (missingLocation['documentEvidence'] as Map)['sourceLocations'] = [];
    expect(
      parseWorkUsageFeedback(
          AgentFinishCompletion(
              summary: '本人检查了当前候选。', evidence: [jsonEncode(missingLocation)]),
          acceptanceIds: const ['layout'],
          requireDocumentEvidence: true),
      isNull,
    );
    final blocked = jsonDecode(jsonEncode(feedback)) as Map;
    blocked['result'] = 'blocked';
    blocked['report'] = '缺少视觉渲染器，未检查任何页图。';
    (blocked['documentEvidence'] as Map)
      ..['pageNumbers'] = <int>[]
      ..['sourceLocations'] = <Map<String, dynamic>>[];
    expect(
      parseWorkUsageFeedback(
          AgentFinishCompletion(
              summary: '视觉检查受环境阻塞。', evidence: [jsonEncode(blocked)]),
          acceptanceIds: const ['layout'],
          requireDocumentEvidence: true),
      isNotNull,
      reason: '缺少渲染器时可记录阻塞，但空页位置不能满足通过门禁。',
    );
    final unknownLocation = jsonDecode(jsonEncode(feedback)) as Map;
    (unknownLocation['documentEvidence'] as Map)['sourceLocations'] = [
      {'fileName': 'review.pdf', 'page': 1, 'receiptId': 'forged'},
    ];
    expect(
      parseWorkUsageFeedback(
          AgentFinishCompletion(
              summary: '本人检查了当前候选。', evidence: [jsonEncode(unknownLocation)]),
          acceptanceIds: const ['layout'],
          requireDocumentEvidence: true),
      isNull,
    );
  });

  test('visual document receipt round-trips page, candidate, and font evidence',
      () {
    final observation = WorkUsageObservation(
      taskId: 'task',
      conversationId: 'group',
      actorId: 'reviewer',
      scenarioId: 'visual-review',
      iterationId: 'r001',
      artifactDigest: 'b' * 64,
      planDigest: 'c' * 64,
      verificationRevision: 2,
      runtime: 'document',
      sessionRef: 'document:task:reviewer:1',
      operation: 'visual-read',
      beforeRef: 'a' * 64,
      afterRef: 'd' * 64,
      outputRefs: const ['document:page.png', 'document:manifest.json'],
      documentFileName: 'review.pdf',
      documentDigest: 'a' * 64,
      pageNumbers: const [2],
      pageCount: 4,
      sourceLocations: const [
        {'fileName': 'review.pdf', 'page': 2},
      ],
      fontCoverageStatus: 'resolved',
    );

    expect(observation.valid, isTrue);
    expect(WorkUsageObservation.tryParse(observation.toJson())?.toJson(),
        observation.toJson());
    final outOfRange = observation.toJson()..['pageNumbers'] = [5];
    expect(WorkUsageObservation.tryParse(outOfRange)?.valid, isFalse);
    final unknown = observation.toJson()..['signedBy'] = 'another-member';
    expect(WorkUsageObservation.tryParse(unknown), isNull);
  });
}

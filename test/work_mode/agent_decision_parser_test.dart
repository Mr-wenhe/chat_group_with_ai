import 'dart:convert';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/features/work_mode/agent_decision.dart';
import 'package:chat_group/features/work_mode/agent_decision_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const parser = AgentDecisionParser(
    defaultCommandWorkingDirectory: '/Users/test/.chat_group',
  );

  group('Stage 03 AgentDecision strict protocol', () {
    final validCases = <({
      String name,
      String raw,
      Type decisionType,
    })>[
      (
        name: 'plan',
        raw: _json({
          'action': 'plan',
          'public_update': '已确认目标，准备按步骤执行。',
          'tool': null,
          'completion': {
            'steps': ['读取相关文件', '完成修改', '验证结果'],
          },
        }),
        decisionType: AgentPlanDecision,
      ),
      (
        name: 'tool',
        raw: _json({
          'action': 'tool',
          'public_update': '正在读取目标文件。',
          'tool': {
            'name': 'workspace.read',
            'arguments': {'path': 'lib/main.dart'},
          },
          'completion': null,
        }),
        decisionType: AgentToolDecision,
      ),
      (
        name: 'clarify',
        raw: _json({
          'action': 'clarify',
          'public_update': '还缺少会影响实现范围的信息。',
          'tool': null,
          'completion': {
            'question': '要修改哪个目录？',
            'options': ['当前工作区', '另一个已授权目录'],
          },
        }),
        decisionType: AgentClarifyDecision,
      ),
      (
        name: 'handoff',
        raw: _json({
          'action': 'handoff',
          'public_update': '需求已整理，交给开发角色继续实现。',
          'tool': null,
          'completion': {
            'target': 'developer',
            'summary': '目标、约束和验收条件已整理完成。',
          },
        }),
        decisionType: AgentHandoffDecision,
      ),
      (
        name: 'finish',
        raw: _json({
          'action': 'finish',
          'public_update': '修改和验证均已完成。',
          'tool': null,
          'completion': {
            'summary': '已完成目标文件更新。',
            'evidence': ['文件读回成功', '轻量检查通过'],
          },
        }),
        decisionType: AgentFinishDecision,
      ),
    ];

    for (final testCase in validCases) {
      test('accepts ${testCase.name} with typed model', () async {
        final result = await parser.parse(testCase.raw);

        expect(result.isSuccess, isTrue, reason: result.detail);
        expect(result.decision, isA<AgentDecision>());
        expect(result.decision.runtimeType, testCase.decisionType);
        expect(result.decision!.toJson()['action'], testCase.name);
        expect(result.decision!.toJson().keys,
            containsAll(['action', 'public_update', 'tool', 'completion']));
      });
    }

    final invalidCases = <({String name, String raw, String detail})>[
      (
        name: 'unknown action',
        raw: _json({
          'action': 'execute',
          'public_update': '开始执行。',
          'tool': null,
          'completion': null,
        }),
        detail: 'action',
      ),
      (
        name: 'missing top-level field',
        raw: _json({
          'action': 'finish',
          'public_update': '已完成。',
          'tool': null,
        }),
        detail: '顶层字段',
      ),
      (
        name: 'wrong field type',
        raw: _json({
          'action': 'finish',
          'public_update': 42,
          'tool': null,
          'completion': {'summary': '完成'},
        }),
        detail: 'public_update',
      ),
      (
        name: 'markdown fence with surrounding prose',
        raw: '模型输出如下：\n```json\n${_json({
              'action': 'finish',
              'public_update': '已完成。',
              'tool': null,
              'completion': {'summary': '完成'},
            })}\n```',
        detail: '单个合法 JSON',
      ),
      (
        name: 'multiple JSON objects',
        raw: '${_json({
              'action': 'finish',
              'public_update': '第一段。',
              'tool': null,
              'completion': {'summary': '完成'},
            })}\n${_json({
              'action': 'finish',
              'public_update': '第二段。',
              'tool': null,
              'completion': {'summary': '完成'},
            })}',
        detail: '单个合法 JSON',
      ),
      (
        name: 'unknown tool',
        raw: _json({
          'action': 'tool',
          'public_update': '开始执行工具。',
          'tool': {
            'name': 'workspace.magic',
            'arguments': {},
          },
          'completion': null,
        }),
        detail: '已注册工具',
      ),
      (
        name: 'tool arguments wrong type',
        raw: _json({
          'action': 'tool',
          'public_update': '开始读取。',
          'tool': {
            'name': 'workspace.read',
            'arguments': ['lib/main.dart'],
          },
          'completion': null,
        }),
        detail: 'JSON object',
      ),
      (
        name: 'tool argument missing',
        raw: _json({
          'action': 'tool',
          'public_update': '开始读取。',
          'tool': {
            'name': 'workspace.read',
            'arguments': {},
          },
          'completion': null,
        }),
        detail: 'path',
      ),
      (
        name: 'private reasoning in public update',
        raw: _json({
          'action': 'finish',
          'public_update': '思维链：我先隐藏真实推理。',
          'tool': null,
          'completion': {'summary': '完成'},
        }),
        detail: '公开动作',
      ),
    ];

    for (final testCase in invalidCases) {
      test('rejects ${testCase.name}', () async {
        final result = await parser.parse(testCase.raw);

        expect(result.isFailure, isTrue);
        expect(result.failure, AgentDecisionParseFailure.modelProtocol);
        expect(result.detail, contains(testCase.detail));
        expect(result.repairAttempted, isFalse);
      });
    }
  });

  test('accepts one markdown json fence around a decision object', () async {
    final result = await parser.parse(
      '```json\n${_validFinishJson()}\n```',
    );

    expect(result.isSuccess, isTrue, reason: result.detail);
    expect(result.decision, isA<AgentFinishDecision>());
  });

  test('uses reasoning_content only when standard content is empty', () async {
    final raw = _validFinishJson();
    final result = await parser.parse('', reasoningContent: raw);

    expect(result.isSuccess, isTrue);
    expect(result.usedReasoningContent, isTrue);
  });

  test('does not use reasoning_content when non-empty content is invalid',
      () async {
    final result = await parser.parse(
      'not-json',
      reasoningContent: _validFinishJson(),
    );

    expect(result.failure, AgentDecisionParseFailure.modelProtocol);
    expect(result.usedReasoningContent, isFalse);
  });

  test('reports both empty response channels without repairing', () async {
    var repairCalls = 0;
    final result = await parser.parse(
      '  ',
      reasoningContent: '\n',
      repair: (_) {
        repairCalls++;
        return _validFinishJson();
      },
    );

    expect(result.failure, AgentDecisionParseFailure.emptyResponse);
    expect(result.detail, contains('均为空'));
    expect(repairCalls, 0);
  });

  test('repairs malformed response once using the original response as data',
      () async {
    const malformed = '模型输出不是 JSON';
    var repairCalls = 0;
    String? original;
    final result = await parser.parse(
      malformed,
      repair: (rawResponse) {
        repairCalls++;
        original = rawResponse;
        return _validFinishJson();
      },
    );

    expect(result.isSuccess, isTrue);
    expect(result.repairAttempted, isTrue);
    expect(repairCalls, 1);
    expect(original, malformed);
  });

  test('second parse failure returns modelProtocol and never retries again',
      () async {
    var repairCalls = 0;
    final result = await parser.parse(
      'not-json',
      repair: (_) {
        repairCalls++;
        return 'still-not-json';
      },
    );

    expect(result.failure, AgentDecisionParseFailure.modelProtocol);
    expect(result.repairAttempted, isTrue);
    expect(repairCalls, 1);
  });

  test('parseResponse preserves content priority and supports message alias',
      () async {
    final raw = _validFinishJson();
    final contentResult = await parser.parseResponse({
      'content': raw,
      'reasoning_content': _validFinishJson(publicUpdate: '不应被使用。'),
    });
    final messageResult = await parser.parseResponse({'message': raw});

    expect(contentResult.isSuccess, isTrue);
    expect(contentResult.usedReasoningContent, isFalse);
    expect(messageResult.isSuccess, isTrue);
  });

  test('falls back to a non-empty message when content is blank', () async {
    final result = await parser.parseResponse({
      'content': '  ',
      'message': _validFinishJson(publicUpdate: '使用标准别名完成解析。'),
      'reasoning_content': _validFinishJson(publicUpdate: '不应被使用。'),
    });

    expect(result.isSuccess, isTrue);
    expect(result.usedReasoningContent, isFalse);
    expect(
      (result.decision! as AgentFinishDecision).publicUpdate,
      '使用标准别名完成解析。',
    );
  });

  test('ignores malformed reasoning_content when content is present', () async {
    final result = await parser.parseResponse({
      'content': _validFinishJson(),
      'reasoning_content': const <String>['unused'],
    });

    expect(result.isSuccess, isTrue);
  });

  test('accepts the existing exact workspace patch argument map', () async {
    final result = await parser.parse(_json({
      'action': 'tool',
      'public_update': '正在应用精确补丁。',
      'tool': {
        'name': 'workspace.patch',
        'arguments': {
          'path': 'lib/main.dart',
          'expectedSha256': List.filled(64, 'a').join(),
          'expectedFragment': 'old',
          'replacement': 'new',
        },
      },
      'completion': null,
    }));

    expect(result.isSuccess, isTrue, reason: result.detail);
    expect(result.decision, isA<AgentToolDecision>());
  });

  test('resolves a blank command working directory to the configured default',
      () async {
    final result = await parser.parse(_json({
      'action': 'tool',
      'public_update': '检查缺失命令。',
      'tool': {
        'name': 'command.run',
        'arguments': {
          'executable': 'insta',
          'arguments': <String>[],
          'workingDirectory': '',
          'declaredImpact': ['.'],
        },
      },
      'completion': null,
    }));

    expect(result.isSuccess, isTrue, reason: result.detail);
    final decision = result.decision! as AgentToolDecision;
    expect(
      decision.tool.arguments['workingDirectory'],
      '/Users/test/.chat_group',
    );
  });

  test('resolves a blank command working directory to the user-home default',
      () async {
    final result = await const AgentDecisionParser().parse(_json({
      'action': 'tool',
      'public_update': '检查缺失命令。',
      'tool': {
        'name': 'command.run',
        'arguments': {
          'executable': 'insta',
          'arguments': <String>[],
          'workingDirectory': '',
          'declaredImpact': ['.'],
        },
      },
      'completion': null,
    }));

    expect(result.isSuccess, isTrue, reason: result.detail);
    final decision = result.decision! as AgentToolDecision;
    expect(
      decision.tool.arguments['workingDirectory'],
      DatabaseService.defaultAiProcessingDirectoryPath(),
    );
    expect(decision.tool.arguments['workingDirectory'], isNot('.'));
  });

  test('repair-empty detail preserves the first protocol validation error',
      () async {
    final result = await parser.parse(
      _json({
        'action': 'tool',
        'public_update': '检查缺失命令。',
        'tool': {
          'name': 'command.run',
          'arguments': {
            'executable': 'insta',
            'arguments': <String>[],
            'workingDirectory': '',
            'declaredImpact': <String>[],
          },
        },
        'completion': null,
      }),
      repair: (_) => null,
    );

    expect(result.failure, AgentDecisionParseFailure.modelProtocol);
    expect(result.detail, contains('declaredImpact'));
    expect(result.detail, contains('修复响应为空'));
  });

  test('toJson emits the fixed four top-level fields', () async {
    final result = await parser.parse(_validFinishJson());
    final json = result.decision!.toJson();

    expect(json.keys.toSet(), {
      'action',
      'public_update',
      'tool',
      'completion',
    });
  });
}

String _validFinishJson({String publicUpdate = '已完成。'}) => _json({
      'action': 'finish',
      'public_update': publicUpdate,
      'tool': null,
      'completion': {
        'summary': '已完成目标。',
        'evidence': ['检查通过'],
      },
    });

String _json(Map<String, dynamic> value) => jsonEncode(value);

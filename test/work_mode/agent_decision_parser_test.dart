import 'dart:async';
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

    test('accepts weather forecast tool with a bounded day count', () async {
      final result = await parser.parse(_json({
        'action': 'tool',
        'public_update': '正在查询未来七天天气。',
        'tool': {
          'name': 'weather.forecast',
          'arguments': {'location': '上海', 'days': 7},
        },
        'completion': null,
      }));

      expect(result.isSuccess, isTrue, reason: result.detail);
      final decision = result.decision! as AgentToolDecision;
      expect(decision.tool.name.wireName, 'weather.forecast');
      expect(decision.tool.arguments, {'location': '上海', 'days': 7});
    });

    test('rejects weather forecast tool with an unsupported day count',
        () async {
      final result = await parser.parse(_json({
        'action': 'tool',
        'public_update': '正在查询天气。',
        'tool': {
          'name': 'weather.forecast',
          'arguments': {'days': 8},
        },
        'completion': null,
      }));

      expect(result.isFailure, isTrue);
      expect(result.detail, contains('1 到 7'));
    });

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
    expect(result.extractedFromProse, isFalse);
  });

  test('accepts a decision object preceded by one spoken sentence', () async {
    final result = await parser.parse('先看看工作区现状，然后开始写材料。\n\n'
        '${_validFinishJson()}');

    expect(result.isSuccess, isTrue, reason: result.detail);
    expect(result.decision, isA<AgentFinishDecision>());
    // 解析成功不等于模型守约，调用方要靠这个标志量违约频率。
    expect(result.extractedFromProse, isTrue);
  });

  test('accepts a fenced decision object wrapped in prose', () async {
    final result = await parser.parse(
      '模型输出如下：\n```json\n${_validFinishJson()}\n```\n希望有帮助。',
    );

    expect(result.isSuccess, isTrue, reason: result.detail);
    expect(result.decision, isA<AgentFinishDecision>());
    expect(result.extractedFromProse, isTrue);
  });

  test('accepts a fenced decision object with trailing prose after the fence',
      () async {
    final result = await parser.parse(
      '```json\n${_validFinishJson()}\n```\n希望有帮助。',
    );

    expect(result.isSuccess, isTrue, reason: result.detail);
    expect(result.decision, isA<AgentFinishDecision>());
    expect(result.extractedFromProse, isTrue);
  });

  test('a broken fence keeps its own diagnostic', () async {
    // 没有闭合围栏，也没有可抽取的 object：围栏专用文案仍是更准确的归因。
    final result = await parser.parse('```json\n我先看看工作区。');

    expect(result.isFailure, isTrue);
    expect(result.detail, contains('Markdown code fence'));
  });

  test('a bare decision object is not reported as extracted', () async {
    final result = await parser.parse(_validFinishJson());

    expect(result.isSuccess, isTrue, reason: result.detail);
    expect(result.extractedFromProse, isFalse);
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

  test('a repair request that failed is not reported as an empty repair',
      () async {
    // 真实故障（2026-09-30，sensenova-6.8-flash-lite）：唯一一次修复请求撞上
    // 上游停滞，客户端 180 秒后自己取消。把它说成"修复响应为空"等于告诉用户
    // 模型没写出东西——事实是链路一个字符都没回，归因错了处置也就错了。
    final result = await parser.parse(
      'not-json',
      repair: (_) => throw TimeoutException('上游毫无响应'),
    );

    expect(result.failure, AgentDecisionParseFailure.modelProtocol);
    expect(result.repairAttempted, isTrue);
    expect(result.repairRequestFailed, isTrue);
    expect(result.detail, contains('修复请求'));
    expect(result.detail, isNot(contains('修复响应为空')));
    // 未知异常的 toString 会带上对象与耗时，不能原样落到用户可见的失败文案里。
    expect(result.detail, isNot(contains('上游毫无响应')));
  });

  test('a blank repair response is not a failed repair request', () async {
    final result = await parser.parse('not-json', repair: (_) => null);

    expect(result.repairAttempted, isTrue);
    expect(result.repairRequestFailed, isFalse);
    expect(result.detail, contains('修复响应为空'));
  });

  test('a repair failure reason from the runner is preserved verbatim',
      () async {
    final result = await parser.parse(
      'not-json',
      repair: (_) => throw const AgentDecisionRepairFailure('工作模式模型请求首字节超时。'),
    );

    expect(result.repairRequestFailed, isTrue);
    expect(result.detail, contains('首字节超时'));
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

  test('native.app accepts only the narrow operation contract', () async {
    for (final arguments in <Map<String, Object?>>[
      {'operation': 'open'},
      {'operation': 'observe', 'sessionRef': 'native:0123456789abcdef01234567'},
      {'operation': 'close', 'sessionRef': 'native:0123456789abcdef01234567'},
      {
        'operation': 'act',
        'action': 'click',
        'sessionRef': 'native:0123456789abcdef01234567',
        'elementId': 'save',
      },
      {
        'operation': 'act',
        'action': 'input',
        'sessionRef': 'native:0123456789abcdef01234567',
        'elementId': 'title',
        'text': 'draft',
      },
      {
        'operation': 'act',
        'action': 'scroll',
        'sessionRef': 'native:0123456789abcdef01234567',
        'elementId': 'list',
        'direction': 'down',
        'distance': 120,
      },
      {
        'operation': 'act',
        'action': 'resize',
        'sessionRef': 'native:0123456789abcdef01234567',
        'widthDelta': 30,
        'heightDelta': 20,
      },
      {
        'operation': 'act',
        'action': 'reopen',
        'sessionRef': 'native:0123456789abcdef01234567',
      },
      {'operation': 'close'},
    ]) {
      final result = await parser.parse(_json({
        'action': 'tool',
        'public_update': '我按当前场景操作应用。',
        'tool': {'name': 'native.app', 'arguments': arguments},
        'completion': null,
      }));
      expect(result.isSuccess, isTrue, reason: result.detail);
    }

    final injectedTarget = await parser.parse(_json({
      'action': 'tool',
      'public_update': '我试着切换目标。',
      'tool': {
        'name': 'native.app',
        'arguments': {
          'operation': 'open',
          'appPath': '/Applications/Other.app',
          'bundleId': 'com.example.other',
        },
      },
      'completion': null,
    }));
    expect(injectedTarget.isSuccess, isFalse);

    final missingSession = await parser.parse(_json({
      'action': 'tool',
      'public_update': '观察当前窗口。',
      'tool': {
        'name': 'native.app',
        'arguments': {'operation': 'observe'},
      },
      'completion': null,
    }));
    expect(missingSession.isSuccess, isFalse);

    final emptySession = await parser.parse(_json({
      'action': 'tool',
      'public_update': '操作当前窗口。',
      'tool': {
        'name': 'native.app',
        'arguments': {
          'operation': 'act',
          'action': 'click',
          'sessionRef': '',
          'elementId': 'save',
        },
      },
      'completion': null,
    }));
    expect(emptySession.isSuccess, isFalse);

    final emptyCloseSession = await parser.parse(_json({
      'action': 'tool',
      'public_update': '关闭当前窗口。',
      'tool': {
        'name': 'native.app',
        'arguments': {'operation': 'close', 'sessionRef': ''},
      },
      'completion': null,
    }));
    expect(emptyCloseSession.isSuccess, isFalse);
  });

  test('browser.context is group usage only and validates bounded operations',
      () async {
    const allowedParser = AgentDecisionParser(allowBrowserContext: true);
    const session = 'browser:0123456789abcdef01234567';
    final valid = <Map<String, Object?>>[
      {'operation': 'open'},
      {
        'operation': 'open',
        'queryParameters': {'scene': 'track', 'dice': '4'},
      },
      {'operation': 'observe', 'sessionRef': session},
      {'operation': 'close', 'sessionRef': session},
      {'operation': 'click', 'sessionRef': session, 'label': '掷骰子'},
      {
        'operation': 'assert',
        'sessionRef': session,
        'acceptanceId': 'dice_result',
        'expectedText': '点数',
      },
      {
        'operation': 'assert',
        'sessionRef': session,
        'acceptanceId': '验收-起飞',
        'expectedText': '点数',
      },
      {
        'operation': 'assert',
        'sessionRef': session,
        'acceptanceId': '验收' * 64,
        'expectedText': '点数',
      },
      {
        'operation': 'resize',
        'sessionRef': session,
        'width': 375,
        'height': 667,
      },
    ];
    for (final arguments in valid) {
      final raw = _json({
        'action': 'tool',
        'public_update': '我正在操作当前冻结网页。',
        'tool': {'name': 'browser.context', 'arguments': arguments},
        'completion': null,
      });
      expect((await allowedParser.parse(raw)).isSuccess, isTrue,
          reason: arguments.toString());
      expect((await parser.parse(raw)).isFailure, isTrue,
          reason: '默认解析器不得给普通工作任务开放浏览器工具。');
    }

    for (final arguments in <Map<String, Object?>>[
      {'operation': 'open', 'filePath': '/tmp/other.html'},
      {
        'operation': 'open',
        'queryParameters': {'api_key': 'must-not-be-stored'},
      },
      {
        'operation': 'open',
        'queryParameters': {'scene': 'x' * 257},
      },
      {
        'operation': 'open',
        'queryParameters': {
          'scene': ['track']
        },
      },
      {
        'operation': 'open',
        'queryParameters': {
          for (var i = 0; i < 9; i++) 'key$i': 'value',
        },
      },
      {'operation': 'observe', 'sessionRef': 'browser:bad'},
      {'operation': 'click', 'sessionRef': session, 'label': 'x' * 257},
      {
        'operation': 'assert',
        'sessionRef': session,
        'acceptanceId': '',
        'expectedText': '完成',
      },
      {
        'operation': 'assert',
        'sessionRef': session,
        'acceptanceId': '验收' * 65,
        'expectedText': '完成',
      },
      {
        'operation': 'assert',
        'sessionRef': session,
        'acceptanceId': 'bad\u0001id',
        'expectedText': '完成',
      },
      {
        'operation': 'resize',
        'sessionRef': session,
        'width': 2000,
        'height': 667,
      },
      {
        'operation': 'navigate',
        'sessionRef': session,
        'url': 'https://example.com',
      },
    ]) {
      final result = await allowedParser.parse(_json({
        'action': 'tool',
        'public_update': '我正在检查浏览器请求。',
        'tool': {'name': 'browser.context', 'arguments': arguments},
        'completion': null,
      }));
      expect(result.isFailure, isTrue, reason: arguments.toString());
    }
  });

  test('技能导入只接受内置模板 ID 或结构化 GitHub 资源字段', () async {
    final requests = <Map<String, Object?>>[
      {
        'name': 'skill.download',
        'arguments': {
          'templateId': 'document.pdf',
          'url': 'https://github.com/x/y'
        },
      },
      {
        'name': 'skill.github.import',
        'arguments': {
          'owner': 'sample',
          'repo': 'skills',
          'path': 'sample/SKILL.md',
          'ref': List.filled(40, 'a').join(),
          'url': 'https://example.test/',
        },
      },
      {
        'name': 'skill.github.search',
        'arguments': {'query': 'flutter skill', 'url': 'https://example.test/'},
      },
      {
        'name': 'skill.resource.read',
        'arguments': {
          'packId': List.filled(64, 'a').join(),
          'path': 'SKILL.md',
          'url': 'file:///etc/passwd',
        },
      },
    ];

    for (final tool in requests) {
      final result = await parser.parse(_json({
        'action': 'tool',
        'public_update': '尝试传入非结构化目标。',
        'tool': tool,
        'completion': null,
      }));
      expect(result.isSuccess, isFalse, reason: tool['name'] as String);
    }
  });

  test('skill.create accepts a single string body and the steps/content aliases',
      () async {
    // 回归（任务 ab8549a1）：模型把技能正文写成 `steps` / `content`，旧校验
    // 报「tool.arguments 不支持字段 steps」，只能换个名字再试，每次创建技能
    // 都白烧一轮。三个名字现在是等价别名，正文写成一段字符串也成立。
    final bodies = <Map<String, Object?>>[
      {
        'name': 'html-tech-ui-polish',
        'domain': 'frontend',
        'description': '优化润色 HTML 界面',
        'instructions': ['读取目标文件', '应用科技感设计语言'],
      },
      {
        'name': 'html-tech-ui-polish',
        'domain': 'frontend',
        'description': '优化润色 HTML 界面',
        'steps': ['读取目标文件', '应用科技感设计语言'],
      },
      {
        'name': 'html-tech-ui-polish',
        'domain': 'frontend',
        'description': '优化润色 HTML 界面',
        'content': '读取目标文件\n应用科技感设计语言',
      },
      {
        // 正文分段写出的空行是正常排版，不能判成非法条目：执行层也会丢弃它们。
        'name': 'html-tech-ui-polish',
        'domain': 'frontend',
        'description': '优化润色 HTML 界面',
        'content': '读取目标文件\n\n应用科技感设计语言\n',
      },
    ];

    for (final arguments in bodies) {
      final result = await parser.parse(_json({
        'action': 'tool',
        'public_update': '创建技能。',
        'tool': {'name': 'skill.create', 'arguments': arguments},
        'completion': null,
      }));
      expect(result.isSuccess, isTrue, reason: arguments.toString());
    }
  });

  test('skill.create reports the missing body with the accepted field names',
      () async {
    final result = await parser.parse(_json({
      'action': 'tool',
      'public_update': '创建技能。',
      'tool': {
        'name': 'skill.create',
        'arguments': {
          'name': 'html-tech-ui-polish',
          'domain': 'frontend',
          'description': '优化润色 HTML 界面',
        },
      },
      'completion': null,
    }));

    expect(result.isSuccess, isFalse);
    expect(result.detail ?? '', contains('instructions'));
    expect(result.detail ?? '', contains('steps'));
  });

  test('normalizes a JSON-encoded command argument list', () async {
    final result = await parser.parse(_json({
      'action': 'tool',
      'public_update': '运行检查。',
      'tool': {
        'name': 'command.run',
        'arguments': {
          'executable': 'flutter',
          'arguments': '["test", "--no-pub"]',
          'workingDirectory': '',
          'declaredImpact': ['.'],
        },
      },
      'completion': null,
    }));

    expect(result.isSuccess, isTrue, reason: result.detail);
    final decision = result.decision! as AgentToolDecision;
    expect(decision.tool.arguments['arguments'], ['test', '--no-pub']);
  });

  test('normalizes a simple whitespace-separated command argument string',
      () async {
    final result = await parser.parse(_json({
      'action': 'tool',
      'public_update': '运行检查。',
      'tool': {
        'name': 'command.run',
        'arguments': {
          'executable': 'flutter',
          'arguments': 'test --no-pub',
          'workingDirectory': '',
          'declaredImpact': ['.'],
        },
      },
      'completion': null,
    }));

    expect(result.isSuccess, isTrue, reason: result.detail);
    final decision = result.decision! as AgentToolDecision;
    expect(decision.tool.arguments['arguments'], ['test', '--no-pub']);
  });

  test('does not split shell syntax from a command argument string', () async {
    final result = await parser.parse(_json({
      'action': 'tool',
      'public_update': '运行检查。',
      'tool': {
        'name': 'command.run',
        'arguments': {
          'executable': 'flutter',
          'arguments': 'test && echo unsafe',
          'workingDirectory': '',
          'declaredImpact': ['.'],
        },
      },
      'completion': null,
    }));

    expect(result.isFailure, isTrue);
    expect(result.detail, contains('类型不正确'));
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

  group('workspace.patch append and merge arguments', () {
    String patchJson(Map<String, dynamic> args) => _json({
          'action': 'tool',
          'public_update': '正在写文件。',
          'tool': {'name': 'workspace.patch', 'arguments': args},
          'completion': null,
        });

    test('accepts append with content', () async {
      final result = await parser.parse(
        patchJson({'path': 'report.md', 'content': '第二段', 'append': true}),
      );

      expect(result.isSuccess, isTrue, reason: result.detail);
      final decision = result.decision! as AgentToolDecision;
      expect(decision.tool.arguments['append'], isTrue);
    });

    test('accepts a merge plan with parts only', () async {
      final result = await parser.parse(
        patchJson({
          'path': 'report.md',
          'parts': ['report.part1.md', 'report.part2.md'],
        }),
      );

      expect(result.isSuccess, isTrue, reason: result.detail);
    });

    final invalidCases =
        <({String name, Map<String, dynamic> args, String detail})>[
      (
        name: 'append without content',
        args: {'path': 'report.md', 'append': true},
        detail: '必须与 content 一起使用',
      ),
      (
        name: 'append together with parts',
        args: {
          'path': 'report.md',
          'content': 'x',
          'append': true,
          'parts': ['a.md'],
        },
        detail: '不能与 content 或 append 同时使用',
      ),
      (
        name: 'parts together with content',
        args: {
          'path': 'report.md',
          'content': 'x',
          'parts': ['a.md']
        },
        detail: '不能与 content 或 append 同时使用',
      ),
      (
        name: 'parts together with an exact patch',
        args: {
          'path': 'report.md',
          'parts': ['a.md'],
          'expectedSha256': 'abc',
          'expectedFragment': 'x',
          'replacement': 'y',
        },
        detail: '不能与 append 或 parts 同时使用',
      ),
      (
        name: 'empty parts',
        args: {'path': 'report.md', 'parts': <String>[]},
        detail: '必须是非空字符串数组',
      ),
      (
        name: 'parts with a blank entry',
        args: {
          'path': 'report.md',
          'parts': ['a.md', ' ']
        },
        detail: '只能包含非空字符串',
      ),
      (
        name: 'append with a non-boolean flag',
        args: {'path': 'report.md', 'content': 'x', 'append': 'true'},
        detail: '类型不正确',
      ),
      // 空白追加是"什么都没写"：放它过去会落到工具侧的"未检测到实际修改"，模型
      // 收到的解释（内容没有实际变化）与真因对不上。
      (
        name: 'append with blank content',
        args: {'path': 'report.md', 'content': '  \n ', 'append': true},
        detail: '追加内容不能为空',
      ),
    ];

    for (final testCase in invalidCases) {
      test('rejects ${testCase.name}', () async {
        final result = await parser.parse(patchJson(testCase.args));

        expect(result.isFailure, isTrue);
        expect(result.detail, contains(testCase.detail));
      });
    }
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

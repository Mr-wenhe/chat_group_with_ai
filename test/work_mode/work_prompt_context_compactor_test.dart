import 'dart:convert';

import 'package:chat_group/features/work_mode/work_prompt_context_compactor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const compactor = WorkPromptContextCompactor();

  int measure(Map<String, dynamic> candidate) =>
      jsonEncode(candidate).length ~/ 3;

  test('未超预算时逐字不动作业上下文', () {
    final context = _context();
    final result = compactor.compactIfNeeded(
      context,
      budgetTokens: measure(context) + 1,
      measureTokens: measure,
    );

    expect(result, context);
  });

  test('中等超支只收缩低价值字段，必保字段与 checkpoint 原样保留', () {
    final context = _context();
    final result = compactor.compactIfNeeded(
      context,
      // 触发前三个阶段即收敛：丢 publicUpdates、committedWrites 与
      // completedActions 留尾，工具结果与对话历史都还没被动过。
      budgetTokens: 3000,
      measureTokens: measure,
    );

    expect(measure(result), lessThanOrEqualTo(3000));
    expect(result['publicUpdates'], isEmpty);
    expect((result['committedWrites'] as List), hasLength(32));
    expect((result['completedActions'] as List), hasLength(8));
    // 还没轮到工具结果与对话历史。
    expect((result['recentToolResults'] as List), hasLength(8));
    expect((result['conversationHistory'] as List), hasLength(16));

    // 执行状态不是模型散文，任何阶段都不能被丢掉。
    expect(result['goal'], '生成报告');
    expect(result['plan'], '写文件');
    expect(result['actionCount'], 3);
    expect(result['actionLimit'], 20);
    expect(result['artifacts'], ['/work/report.md']);

    // checkpointSummary 是压缩后的 JSON 字符串，target / pendingFollowUps 必须还在。
    final checkpoint =
        jsonDecode(result['checkpointSummary'] as String) as Map;
    expect(checkpoint['target'], '生成报告');
    expect(checkpoint['pendingFollowUps'], ['补充图表']);
    expect(checkpoint['artifactPaths'], ['/work/report.md']);
  });

  test('深度超支后输出仍是合法 JSON，不会把检查点剪成两半', () {
    final context = _context()
      ..['recentToolResults'] = [
        {
          'tool': 'workspace.read',
          'status': 'success',
          'data': {'content': 'A' * 200000},
        },
      ];

    final result = compactor.compactIfNeeded(
      context,
      budgetTokens: 500,
      measureTokens: measure,
    );

    // 逐字段收缩后必须仍能被 jsonEncode → jsonDecode 往返，这是旧实现
    // （对整条 system 消息从中间插入裁剪标记）做不到的。
    final roundTrip = jsonDecode(jsonEncode(result)) as Map<String, dynamic>;
    expect(roundTrip['goal'], '生成报告');
    expect(measure(result), lessThan(measure(context)));

    final toolResult = (result['recentToolResults'] as List).single as Map;
    final content = (toolResult['data'] as Map)['content'] as String;
    expect(content.length, lessThan(200000));
  });

  test('命令输出 (data.stdout) 与文件正文一样会被收缩', () {
    final context = _context()
      ..['recentToolResults'] = [
        {
          'tool': 'command.run',
          'status': 'success',
          'data': {
            'stdout': 'B' * 200000,
            'exitCode': 0,
          },
        },
      ];

    final result = compactor.compactIfNeeded(
      context,
      budgetTokens: 500,
      measureTokens: measure,
    );

    final toolResult = (result['recentToolResults'] as List).single as Map;
    final data = toolResult['data'] as Map;
    // 只认 data.content 会让命令输出整块漏出收缩范围——它是提示词里最大的一块。
    expect((data['stdout'] as String).length, lessThan(200000));
    // 短字段照旧原样保留。
    expect(data['exitCode'], 0);
  });

  test('多模态载荷保留图片数据 URI，只收缩其中的文本分段', () {
    final imageUri = 'data:image/png;base64,${'y' * 80000}';
    final context = _context()
      ..['recentToolResults'] = [
        {
          'tool': 'workspace.document',
          'status': 'success',
          'data': {
            'content': [
              {'type': 'text', 'text': 'x' * 40000},
              {
                'type': 'image_url',
                'image_url': {'url': imageUri},
              },
            ],
          },
        },
      ];

    final result = compactor.compactIfNeeded(
      context,
      budgetTokens: 500,
      measureTokens: measure,
    );

    final toolResult = (result['recentToolResults'] as List).single as Map;
    final parts = (toolResult['data'] as Map)['content'] as List;
    // 图片按原生 content-part 发给模型，截断会把它降级成文本，同时绕过网关的
    // 视觉能力校验。
    expect((parts.last as Map)['image_url'], {'url': imageUri});
    // 文本分段属于正文，照常收缩。
    expect(((parts.first as Map)['text'] as String).length, lessThan(40000));
  });

  test('预算为 0 或负数时不抛错，仍返回可编码的上下文', () {
    for (final budget in [0, -1]) {
      final result = compactor.compactIfNeeded(
        _context(),
        budgetTokens: budget,
        measureTokens: measure,
      );

      expect(jsonDecode(jsonEncode(result)), isA<Map<String, dynamic>>());
      expect(result['goal'], '生成报告');
    }
  });
}

Map<String, dynamic> _context() => <String, dynamic>{
      'goal': '生成报告',
      'plan': '写文件',
      'resultSummary': '',
      'lastError': '',
      'actionCount': 3,
      'actionLimit': 20,
      'completedActions':
          List<String>.generate(32, (index) => '校验步骤 $index' * 20),
      'committedWrites':
          List<String>.generate(128, (index) => 'workspace/write/$index'),
      'publicUpdates':
          List<String>.generate(20, (index) => '公开进度 $index' * 20),
      'recentToolResults': List<Map<String, dynamic>>.generate(
        8,
        (index) => {
          'tool': 'workspace.read',
          'status': 'success',
          'data': {'content': '文件正文 $index' * 50},
        },
      ),
      'artifacts': ['/work/report.md'],
      'pendingToolRequest': '',
      'conversationHistory': List<Map<String, dynamic>>.generate(
        16,
        (index) => {'role': 'user', 'content': '群聊消息 $index' * 30},
      ),
      'checkpointSummary': jsonEncode({
        'conversationId': 'group-a',
        'target': '生成报告',
        'pendingFollowUps': ['补充图表'],
        'artifactPaths': ['/work/report.md'],
        'completedSummaries': ['已写出大纲'],
      }),
    };

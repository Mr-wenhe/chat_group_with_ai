// These tests intentionally exercise retired compatibility entry points.
// ignore_for_file: deprecated_member_use_from_same_package

import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/character_memory.dart';
import 'package:chat_group/features/agentic/context_window_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('默认压缩阈值为 200k token 并按字符粗略估算', () {
    const manager = ContextWindowManager(
      complete: _unusedCompletion,
    );
    final messages = [
      {'role': 'user', 'content': List.filled(800000, '字').join()},
    ];

    expect(kContextCompressThresholdTokens, 200000);
    expect(manager.estimateTokenCount(messages), 200000);
    expect(manager.shouldSummarize(messages), isTrue);
  });

  test('工作模式压缩阈值按「标准窗口」计算，声明窗口不足 20 万时兜底到 20 万', () {
    // 两个常量现在数值相同但用途无关，刻意写成两份。这条断言就是那道闸：
    // 改动任一侧都会先在这里失败，逼人显式决定另一侧怎么办。
    expect(kStandardContextWindowTokens, kContextCompressThresholdTokens);

    // 8192 / 32768 / 131072 三档都兜底到 200000，阈值同为 160000。
    for (final declared in [8192, 32768, 131072, 200000]) {
      expect(
        ContextWindowManager.effectiveContextWindow(contextWindow: declared),
        200000,
        reason: '声明窗口 $declared 未兜底到标准窗口',
      );
      expect(
        ContextWindowManager.workContextCompactionTokens(
          contextWindow: declared,
        ),
        160000,
      );
    }

    // 超过标准窗口的声明值按原值算。
    expect(
      ContextWindowManager.workContextCompactionTokens(contextWindow: 250000),
      200000,
    );
    expect(
      ContextWindowManager.workContextCompactionTokens(contextWindow: 1000000),
      800000,
    );
  });

  test('损坏的窗口声明不会让阈值计算抛错或回退到 0', () {
    for (final declared in [0, -1, -1000000]) {
      expect(
        ContextWindowManager.workContextCompactionTokens(
          contextWindow: declared,
        ),
        160000,
      );
    }
  });

  test('压缩预算取阈值与输入预算的较小者，小窗口模型完全不受影响', () {
    // 8192 窗口、内置默认 8192 输出的实际执行预算：阈值 160000 被压到 3840，
    // 于是这条规则对小窗口模型是空操作，行为与改动前完全一致。
    expect(
      ContextWindowManager.workPromptCompactionBudget(
        contextWindow: 8192,
        inputBudget: ContextWindowManager.inputBudget(
          contextWindow: 8192,
          maxOutput: 4096,
        ),
      ),
      3840,
    );

    // 现场模型（声明 200000 / maxOutput 20480）：179264 被压到 160000。
    expect(
      ContextWindowManager.workPromptCompactionBudget(
        contextWindow: 200000,
        inputBudget: ContextWindowManager.inputBudget(
          contextWindow: 200000,
          maxOutput: 20480,
        ),
      ),
      160000,
    );

    // 输入预算为 0 时不能返回负数——那会让压缩器把提示词清空。
    expect(
      ContextWindowManager.workPromptCompactionBudget(
        contextWindow: 128,
        inputBudget: 0,
      ),
      0,
    );
  });

  test('群讨论字符预算取窗口预算与既有固定上限的较小者', () {
    const fallback = 24 * 1024;

    // 8k 窗口 + 4096 输出：输入预算只有 3840 token，固定上限 24576 字符
    // （约 8192 token）必然超窗，这里收紧到 11520 字符。
    expect(
      ContextWindowManager.workDiscussionPromptCharacters(
        contextWindow: 8192,
        maxOutput: 4096,
        fallbackCharacters: fallback,
      ),
      11520,
    );

    // 现场模型（声明 200000）：窗口预算远大于固定上限，保持 24576 不变——
    // 群讨论的字段本来就各自有界，放宽它只会让一次讨论请求更大更慢。
    expect(
      ContextWindowManager.workDiscussionPromptCharacters(
        contextWindow: 200000,
        maxOutput: 4096,
        fallbackCharacters: fallback,
      ),
      fallback,
    );

    // 输入预算按**实际发送的**输出预算算，不按窗口一半折算：这条预算的职责是
    // 「提示词 + 4096 输出」不超过窗口。折算会让 4352～8192 这一档（原本跑得通）
    // 算出更大的提示词预算，把讨论推成超窗。
    expect(
      ContextWindowManager.workDiscussionPromptCharacters(
        contextWindow: 6000,
        maxOutput: 4096,
        fallbackCharacters: fallback,
      ),
      4944,
      reason: '6000 窗口只容得下 1648 token 的提示词，放大到窗口一半就会超窗',
    );

    // 窗口连输出预算都容不下时输入预算算成 0，提示词只剩 1 个字符。这一档本来就
    // 是 inputTokens + maxTokens > contextWindow、必然被网关拒绝，所以不做补偿。
    expect(
      ContextWindowManager.workDiscussionPromptCharacters(
        contextWindow: 128,
        maxOutput: 4096,
        fallbackCharacters: fallback,
      ),
      1,
    );
  });

  test('压缩后保留摘要和最后一条用户消息', () {
    const manager = ContextWindowManager(complete: _unusedCompletion);
    final compacted = manager.compact(
      const [
        {'role': 'user', 'content': '旧问题'},
        {'role': 'assistant', 'content': '旧回答'},
        {'role': 'user', 'content': '当前任务'},
      ],
      const ContextSummary(
        summary: '已决定采用方案 A，下一步补测试。',
        facts: ['采用方案 A'],
      ),
    );

    expect(compacted.length, 2);
    expect(compacted.first['role'], 'system');
    expect(compacted.first['content'], contains('已决定采用方案 A'));
    expect(compacted.last, {'role': 'user', 'content': '当前任务'});
  });

  test('请求预算裁剪旧对话并保留系统约束和最新消息', () {
    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': '始终遵守角色和安全约束。'},
      {'role': 'user', 'content': List.filled(400, '旧问题').join()},
      {'role': 'assistant', 'content': List.filled(400, '旧回答').join()},
      {'role': 'user', 'content': '请继续修改当前文件。'},
    ];

    final bounded = ContextWindowManager.fitToTokenBudget(
      messages,
      maxTokens: 120,
    );

    expect(
      ContextWindowManager.estimateRequestTokens(bounded),
      lessThanOrEqualTo(120),
    );
    expect(bounded.first['role'], 'system');
    expect(bounded.last['content'], '请继续修改当前文件。');
    expect(bounded.where((message) => message['role'] == 'user'), hasLength(1));
  });

  test('输入预算不会超过极小自定义模型窗口', () {
    expect(
      ContextWindowManager.inputBudget(
        contextWindow: 128,
        maxOutput: 64,
      ),
      0,
    );
    expect(
      ContextWindowManager.inputBudget(
        contextWindow: 8192,
        maxOutput: 1024,
      ),
      6912,
    );
  });

  test('极小预算也不删除系统约束和最新对话', () {
    final bounded = ContextWindowManager.fitToTokenBudget(
      const [
        {'role': 'system', 'content': '安全'},
        {'role': 'user', 'content': '继续'},
      ],
      maxTokens: 1,
    );

    expect(bounded.first['role'], 'system');
    expect(bounded.last['role'], 'user');
  });

  test('超长多模态内容在预算不足时降级为安全占位文本', () {
    final bounded = ContextWindowManager.fitToTokenBudget(
      [
        {
          'role': 'system',
          'content': '保留当前任务约束。',
        },
        {
          'role': 'user',
          'content': [
            {
              'type': 'image_url',
              'image_url': {'url': 'data:image/png;base64,${'x' * 4000}'},
            },
          ],
        },
      ],
      maxTokens: 80,
    );

    expect(
      ContextWindowManager.estimateRequestTokens(bounded),
      lessThanOrEqualTo(80),
    );
    expect(bounded.last['content'], contains('内容已按模型上下文上限省略'));
  });

  test('退役摘要写入 API refuses legacy model writes', () async {
    final character = _character();
    final memory = CharacterMemory(groupId: 'dm:c1', characterId: character.id);
    var characterSaved = false;
    var memorySaved = false;
    const summary = ContextSummary(
      summary: '用户偏好简洁答案，任务尚待补充测试。',
      facts: ['任务尚待补充测试'],
      relationshipNotes: ['用户偏好简洁答案'],
      personaGrowth: ['先给结论再解释'],
    );
    const manager = ContextWindowManager(complete: _unusedCompletion);

    await expectLater(
      manager.persistToCharacterMemory(
        character: character,
        memory: memory,
        summary: summary,
        saveCharacter: (_) async => characterSaved = true,
        saveMemory: (_) async => memorySaved = true,
      ),
      throwsA(isA<UnsupportedError>()),
    );

    expect(characterSaved, isFalse);
    expect(memorySaved, isFalse);
    expect(character.memorySummary, isEmpty);
    expect(memory.facts, isEmpty);
    expect(memory.relationshipNotes, isEmpty);
    expect(memory.personaGrowth, isEmpty);
  });

  test('摘要 LLM 遇到瞬态失败后按统一策略恢复', () async {
    var calls = 0;
    final manager = ContextWindowManager(
      thresholdTokens: 1,
      retrySleep: (_) async {},
      complete: (_) async {
        calls++;
        if (calls == 1) {
          return {'success': false, 'message': 'HTTP 503: unavailable'};
        }
        return {
          'success': true,
          'message':
              '{"summary":"核心摘要","facts":["事实"],"relationshipNotes":[],"personaGrowth":[]}'
        };
      },
    );

    final summary = await manager.summarize(
      const [
        {'role': 'user', 'content': '很长的任务上下文'}
      ],
      isDirectChat: true,
    );

    expect(calls, 2);
    expect(summary.summary, '核心摘要');
    expect(summary.facts, ['事实']);
  });
}

Future<Map<String, dynamic>> _unusedCompletion(
  List<Map<String, dynamic>> messages,
) async =>
    {'success': true, 'message': '{}'};

AICharacter _character() => AICharacter(
      id: 'c1',
      name: '小助手',
      avatar: '🤖',
      age: 24,
      role: '助理',
      personalityTags: const [],
      systemPrompt: '帮助用户。',
      apiKey: 'k',
      apiProvider: 'deepseek',
    );

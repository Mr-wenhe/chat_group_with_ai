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

  test('摘要写入角色全局记忆和会话三层记忆', () async {
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

    await manager.persistToCharacterMemory(
      character: character,
      memory: memory,
      summary: summary,
      saveCharacter: (_) async => characterSaved = true,
      saveMemory: (_) async => memorySaved = true,
    );

    expect(characterSaved, isTrue);
    expect(memorySaved, isTrue);
    expect(character.memorySummary, contains('任务尚待补充测试'));
    expect(memory.facts, contains('任务尚待补充测试'));
    expect(memory.relationshipNotes, contains('用户偏好简洁答案'));
    expect(memory.personaGrowth, contains('先给结论再解释'));
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

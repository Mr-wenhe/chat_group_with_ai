import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/features/chat_group/agentic_reply_utils.dart';
import 'package:flutter_test/flutter_test.dart';

AICharacter _c(String id) => AICharacter(
      id: id,
      name: id,
      avatar: '',
      age: 18,
      role: '',
      personalityTags: const [],
      systemPrompt: '',
      apiKey: '',
      apiProvider: 'deepseek',
    );

/// Bug B-b2 选角收敛的纯函数单测。
///
/// 通过 [selectAgenticCharactersForRound]（从 [_runAiRound] 抽出的纯函数）断言：
/// 群聊显式 agentic 任务且未 @ 限定时只保留单个角色（避免多条气泡）；
/// 而 @ 多角色、私聊、非显式 agentic 等正常场景不被误伤。
void main() {
  group('selectAgenticCharactersForRound (Bug B-b2)', () {
    final a = _c('a');
    final b = _c('b');
    final c = _c('c');
    final all = [a, b, c];

    test('群聊显式 agentic 且无 @ → 只保留单个角色', () {
      final result = selectAgenticCharactersForRound(
        isDirectChat: false,
        isExplicitAgenticTask: true,
        candidates: all,
        mentionedIds: null,
      );
      expect(result, hasLength(1));
      expect(result.single.id, 'a');
    });

    test('群聊显式 agentic 且 @ 多个角色 → 只由第一个被 @ 角色执行', () {
      final result = selectAgenticCharactersForRound(
        isDirectChat: false,
        isExplicitAgenticTask: true,
        candidates: all,
        mentionedIds: ['b', 'c'],
      );
      expect(result, hasLength(1));
      expect(result.single.id, 'b');
    });

    test('群聊显式 agentic 但 @ 的角色不在候选 → 回退为空（交由既有兜底）', () {
      final result = selectAgenticCharactersForRound(
        isDirectChat: false,
        isExplicitAgenticTask: true,
        candidates: all,
        mentionedIds: ['x'],
      );
      expect(result, isEmpty);
    });

    test('私聊下不收敛，保留全部候选', () {
      final result = selectAgenticCharactersForRound(
        isDirectChat: true,
        isExplicitAgenticTask: true,
        candidates: all,
        mentionedIds: null,
      );
      expect(result, hasLength(3));
    });

    test('非显式 agentic 群聊不收敛，保留全部候选', () {
      final result = selectAgenticCharactersForRound(
        isDirectChat: false,
        isExplicitAgenticTask: false,
        candidates: all,
        mentionedIds: null,
      );
      expect(result, hasLength(3));
    });

    test('候选为空时不抛异常、返回空', () {
      final result = selectAgenticCharactersForRound(
        isDirectChat: false,
        isExplicitAgenticTask: true,
        candidates: const [],
        mentionedIds: null,
      );
      expect(result, isEmpty);
    });
  });
}

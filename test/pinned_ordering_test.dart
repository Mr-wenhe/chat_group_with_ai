import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/features/direct_chat/pinned_ordering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PinnedOrdering', () {
    test('sorts pinned characters before normal characters', () {
      final alice = _character(id: 'alice', name: '小夏');
      final bob = _character(id: 'bob', name: '阿哲');
      final cici = _character(id: 'cici', name: '小七');

      final sorted = PinnedOrdering.sortCharacters(
        [alice, bob, cici],
        pinnedIds: {'cici'},
      );

      expect(sorted.map((c) => c.id), ['cici', 'bob', 'alice']);
    });

    test('sorts Chinese character names by pinyin initials', () {
      final zhang = _character(id: 'zhang', name: '张三');
      final xia = _character(id: 'xia', name: '小夏');
      final lin = _character(id: 'lin', name: '林溪');
      final a = _character(id: 'a', name: '阿哲');

      final sorted = PinnedOrdering.sortCharacters(
        [zhang, xia, lin, a],
        pinnedIds: const {},
      );

      expect(sorted.map((c) => c.id), ['a', 'lin', 'xia', 'zhang']);
    });

    test('sorts characters by name within pinned and normal groups', () {
      final zed = _character(id: 'zed', name: 'Zed');
      final alpha = _character(id: 'alpha', name: 'Alpha');
      final beta = _character(id: 'beta', name: 'Beta');
      final amber = _character(id: 'amber', name: 'Amber');

      final sorted = PinnedOrdering.sortCharacters(
        [zed, alpha, beta, amber],
        pinnedIds: {'zed', 'amber'},
      );

      expect(sorted.map((c) => c.id), ['amber', 'zed', 'alpha', 'beta']);
    });

    test('sorts pinned groups before normal groups', () {
      final a = _group(id: 'a', name: 'A');
      final b = _group(id: 'b', name: 'B');
      final c = _group(id: 'c', name: 'C');

      final sorted = PinnedOrdering.sortGroups(
        [a, b, c],
        pinnedIds: {'b'},
      );

      expect(sorted.map((g) => g.id), ['b', 'a', 'c']);
    });
  });
}

AICharacter _character({required String id, required String name}) {
  return AICharacter(
    id: id,
    name: name,
    avatar: name.substring(0, 1),
    age: 24,
    role: '测试角色',
    personalityTags: const [],
    systemPrompt: '保持角色口吻。',
    apiKey: 'key',
    apiProvider: 'deepseek',
    apiConfigId: '',
  );
}

ChatGroup _group({required String id, required String name}) {
  return ChatGroup(
    id: id,
    name: name,
    theme: '测试',
    aiCharacterIds: const [],
  );
}

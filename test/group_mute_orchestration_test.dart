import 'dart:io';
import 'dart:math';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/features/chat_group/group_mute_store.dart';
import 'package:chat_group/features/chat_group/humanized_chat_orchestrator.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/lifecycle_hive.dart';

/// 禁言必须作为编排器的硬资格过滤；被点名时例外放行。
void main() {
  late Directory directory;
  late GroupMuteStore store;

  setUp(() async {
    directory = await openLifecycleHive();
    store = GroupMuteStore(DatabaseService());
  });

  tearDown(() => closeLifecycleHive(directory));

  List<ReplyIntent> intentsFor(Set<String> mentioned) {
    final character = testCharacter('a');
    return HumanizedChatOrchestrator.selectReplyIntents(
      characters: [character],
      recentMessages: const [],
      recentMessagesForCharacter: (_) => const [],
      groupId: 'g1',
      groupTheme: '日常聊天',
      userMessage: null,
      mentionedIds: mentioned.toList(),
      memories: const [],
      relationships: const [],
      isEligible: (candidate) => store.mayAutoPick(
        groupId: 'g1',
        characterId: candidate.id,
        mentionedIds: mentioned,
      ),
      random: Random(1),
      isAutoChat: false,
    );
  }

  test('未禁言：被点名时进入意图列表', () {
    expect(intentsFor({'a'}).map((intent) => intent.speakerId), contains('a'));
  });

  test('已禁言且未被点名：编排器硬过滤掉该成员', () async {
    await store.setMuted(groupId: 'g1', characterId: 'a', muted: true);

    expect(intentsFor(const {}), isEmpty);
  });

  test('已禁言但被点名：仍进入意图列表', () async {
    await store.setMuted(groupId: 'g1', characterId: 'a', muted: true);

    expect(intentsFor({'a'}).map((intent) => intent.speakerId), contains('a'));
  });
}

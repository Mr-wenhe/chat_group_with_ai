import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/features/memory/relationship_event_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/lifecycle_hive.dart';

/// 自动写入规则：心情只被明确情绪信号改变，普通事件既不改心情也不续命。
void main() {
  late Directory directory;
  late DatabaseService db;

  setUp(() async {
    directory = await openLifecycleHive();
    db = DatabaseService();
  });

  tearDown(() => closeLifecycleHive(directory));

  List<AICharacter> charList(List<String> ids) =>
      ids.map((id) => testCharacter(id, apiConfigId: 'cfg_$id')).toList();

  Future<RelationshipState> seed({
    required RelationshipMood mood,
    DateTime? moodAt,
  }) async {
    final state = RelationshipState.global(
      sourceCharacterId: 'a',
      targetType: RelationshipTargetType.ai,
      targetId: 'b',
      recentMood: mood,
      recentMoodAt: moodAt,
    );
    await db.relationshipStateBox.put(state.id, state);
    return state;
  }

  Future<void> applyUserMessage(
    RelationshipState state, {
    required String content,
  }) async {
    final message = Message(
      groupId: 'g1',
      senderId: 'user',
      senderType: 'user',
      content: content,
    )..visibleToCharacterIds = ['a', 'b'];
    await RelationshipEventService(db).observeAndApply(
      sourceCharacterId: 'a',
      targetId: 'b',
      targetType: RelationshipTargetType.ai,
      message: message,
      conversationId: 'g1',
      conversationNameSnapshot: 'TestGroup',
      allCharacters: charList(['a', 'b']),
    );
  }

  test('普通事件不改变仍有效的心情', () async {
    final seeded = await seed(
      mood: RelationshipMood.warm,
      moodAt: DateTime.now().subtract(const Duration(minutes: 1)),
    );

    await applyUserMessage(seeded, content: '今天天气不错');

    final updated = db.relationshipStateBox.get(seeded.id)!;
    expect(updated.recentMood, RelationshipMood.warm);
  });

  test('普通事件不刷新时间戳（不给过期心情续命）', () async {
    final moodAt = DateTime.now().subtract(const Duration(minutes: 1));
    final seeded = await seed(mood: RelationshipMood.warm, moodAt: moodAt);

    await applyUserMessage(seeded, content: '今天天气不错');

    final updated = db.relationshipStateBox.get(seeded.id)!;
    expect(
      updated.recentMoodAt,
      moodAt,
      reason: '普通事件不得推进心情时间戳，否则活跃会话会让心情永不失效',
    );
  });

  test('过期心情在写入时归一化为 neutral 且清空时间戳', () async {
    final seeded = await seed(
      mood: RelationshipMood.annoyed,
      moodAt: DateTime.now().subtract(const Duration(hours: 3)),
    );

    await applyUserMessage(seeded, content: '今天天气不错');

    final updated = db.relationshipStateBox.get(seeded.id)!;
    expect(updated.recentMood, RelationshipMood.neutral);
    expect(updated.recentMoodAt, isNull);
  });

  test('明确情绪信号设置心情并打上当前时间戳', () async {
    final seeded = await seed(mood: RelationshipMood.neutral);

    await applyUserMessage(seeded, content: '我要攻击你，你这个垃圾');

    final updated = db.relationshipStateBox.get(seeded.id)!;
    expect(updated.recentMood, RelationshipMood.annoyed);
    expect(updated.recentMoodAt, isNotNull);
    expect(
      DateTime.now().difference(updated.recentMoodAt!).inMinutes,
      lessThan(1),
    );
  });
}

import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/features/memory/relationship_event_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/lifecycle_hive.dart';

/// 熟悉度分档：平凡互动低增量，重要事件保持高增量。
///
/// 熟悉度语义为「互动量」，与发言人身份无关；互动质量由 affinity / trust 承载。
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

  /// 跑一条消息，返回熟悉度增量。
  ///
  /// 每次调用使用不同的目标 ID：关系稳定 ID 由 (source, targetType, target)
  /// 派生，复用同一目标会让同一测试内的多次调用互相叠加。
  var targetSeq = 0;
  Future<int> deltaFor({
    required bool isGroupChat,
    required String senderType,
    String content = '今天天气不错',
    bool isBystander = false,
  }) async {
    final targetId = 'b${targetSeq++}';
    final seeded = RelationshipState.global(
      sourceCharacterId: 'a',
      targetType: RelationshipTargetType.ai,
      targetId: targetId,
    );
    await db.relationshipStateBox.put(seeded.id, seeded);

    final conversationId = isGroupChat ? 'g1' : 'dm:$targetId';
    final message = Message(
      groupId: conversationId,
      senderId: senderType == 'user' ? 'user' : targetId,
      senderType: senderType,
      content: content,
    )..visibleToCharacterIds = ['a', targetId];

    await RelationshipEventService(db).observeAndApply(
      sourceCharacterId: 'a',
      targetId: targetId,
      targetType: RelationshipTargetType.ai,
      message: message,
      conversationId: conversationId,
      conversationNameSnapshot: 'TestGroup',
      allCharacters: charList(['a', targetId]),
      isBystander: isBystander,
    );

    return db.relationshipStateBox.get(seeded.id)!.familiarity;
  }

  group('普通互动（分档后）', () {
    test('普通用户消息：群聊 +1、私聊 +2', () async {
      expect(await deltaFor(isGroupChat: true, senderType: 'user'), 1);
      expect(await deltaFor(isGroupChat: false, senderType: 'user'), 2);
    });

    test('普通 AI 消息：群聊 +1、私聊 +2', () async {
      expect(await deltaFor(isGroupChat: true, senderType: 'ai'), 1);
      expect(await deltaFor(isGroupChat: false, senderType: 'ai'), 2);
    });

    test('旁观者仍累积 1（减半但不归零）', () async {
      // 熟悉度是「互动量」：旁观者确实目睹了互动。普通互动增量降为 1 后，
      // 若仍按整数减半会归零、变成完全不累积——那是改动前没有的行为退化。
      expect(
        await deltaFor(isGroupChat: true, senderType: 'user', isBystander: true),
        1,
      );
    });
  });

  group('重要事件（保持不变）', () {
    test('浪漫表达：群聊 +3、私聊 +6', () async {
      expect(
        await deltaFor(isGroupChat: true, senderType: 'user', content: '我好像喜欢你了'),
        3,
      );
      expect(
        await deltaFor(isGroupChat: false, senderType: 'user', content: '我好像喜欢你了'),
        6,
      );
    });
  });
}

import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/features/chat_group/roundtable_news_role_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/lifecycle_hive.dart';

void main() {
  late Directory directory;
  late DatabaseService db;

  setUp(() async {
    directory = await openLifecycleHive();
    db = DatabaseService();
  });

  tearDown(() => closeLifecycleHive(directory, db));

  test('adds one silent news role without a chat API config', () async {
    final group = ChatGroup(
      id: 'roundtable-group',
      name: '圆桌',
      theme: '新闻讨论',
      aiCharacterIds: const [],
    );
    await db.chatGroupBox.put(group.id, group);

    final first = await RoundtableNewsRoleService.ensureForGroup(
      db,
      group.id,
    );
    expect(first, isNotNull);
    expect(first!.group.aiCharacterIds, [roundtableNewsRoleId]);
    expect(first.character.zhipuSearchAnswerOnly, isTrue);
    expect(first.character.webSearchEnabled, isTrue);
    expect(first.character.proactiveChatEnabled, isFalse);
    expect(first.character.apiConfigId, isEmpty);
    expect(first.character.modelName, 'glm-4.7');

    final second = await RoundtableNewsRoleService.ensureForGroup(
      db,
      group.id,
    );
    expect(second!.group.aiCharacterIds, [roundtableNewsRoleId]);
    expect(db.aiCharacterBox.values.whereType<AICharacter>(), hasLength(1));
  });
}

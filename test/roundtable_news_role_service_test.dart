import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/features/chat_group/roundtable_news_role_service.dart';
import 'package:chat_group/features/web_search/application/autonomous_web_policy.dart';
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

  test('roundtable and Zhipu-only roles never receive autonomous web tools', () {
    final character = AICharacter(
      id: 'ordinary', name: 'ordinary', avatar: 'A', age: 25,
      role: '工程师', personalityTags: const [], systemPrompt: '', apiKey: '',
      apiProvider: 'zhipu', webSearchEnabled: true,
    );
    expect(
      AutonomousWebPolicy.allows(character, AutonomousWebScene.groupChat),
      isTrue,
    );
    expect(
      AutonomousWebPolicy.allows(character, AutonomousWebScene.roundtable),
      isFalse,
    );
    character.webSearchEnabled = false;
    expect(
      AutonomousWebPolicy.allows(character, AutonomousWebScene.workMode),
      isTrue,
      reason: '关闭智谱搜索选项后，普通角色仍可自主联网',
    );
    character.zhipuSearchAnswerOnly = true;
    expect(
      AutonomousWebPolicy.allows(character, AutonomousWebScene.directChat),
      isFalse,
    );
    final legacyNews = AICharacter(
      id: roundtableNewsRoleId, name: '新闻角色', avatar: 'N', age: 25,
      role: '检索', personalityTags: const [], systemPrompt: '', apiKey: '',
      apiProvider: 'zhipu', zhipuSearchAnswerOnly: false,
    );
    expect(
      AutonomousWebPolicy.allows(legacyNews, AutonomousWebScene.groupChat),
      isFalse,
    );
  });

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

    final stale = first.character
      ..zhipuSearchAnswerOnly = false
      ..webSearchEnabled = false
      ..proactiveChatEnabled = true
      ..agenticEnabled = true;
    await db.aiCharacterBox.put(stale.id, stale);
    final restored = await RoundtableNewsRoleService.ensureForGroup(db, group.id);
    expect(restored!.character.zhipuSearchAnswerOnly, isTrue);
    expect(restored.character.webSearchEnabled, isTrue);
    expect(restored.character.proactiveChatEnabled, isFalse);
    expect(restored.character.agenticEnabled, isFalse);
  });
}

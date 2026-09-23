import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/features/chat_group/group_mute_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'helpers/lifecycle_hive.dart';

/// 群内禁言：持久化在 app_settings，且只作用于「自动挑选」。
void main() {
  late Directory directory;
  late DatabaseService db;
  late GroupMuteStore store;

  setUp(() async {
    directory = await openLifecycleHive();
    db = DatabaseService();
    store = GroupMuteStore(db);
  });

  tearDown(() => closeLifecycleHive(directory));

  test('默认没有任何禁言', () {
    expect(store.isMuted('g1', 'a'), isFalse);
    expect(store.mutedFor('g1'), isEmpty);
  });

  test('禁言后 isMuted 为真，取消后清除且不残留空条目', () async {
    await store.setMuted(groupId: 'g1', characterId: 'a', muted: true);
    expect(store.isMuted('g1', 'a'), isTrue);
    expect(store.mutedFor('g1'), {'a'});

    await store.setMuted(groupId: 'g1', characterId: 'a', muted: false);
    expect(store.isMuted('g1', 'a'), isFalse);
    expect(store.mutedFor('g1'), isEmpty);
    expect(
      db.appSettingsBox.get(GroupMuteStore.storageKey),
      isEmpty,
      reason: '最后一个成员取消禁言后，该群的条目不应残留',
    );
  });

  test('禁言按群隔离', () async {
    await store.setMuted(groupId: 'g1', characterId: 'a', muted: true);

    expect(store.isMuted('g1', 'a'), isTrue);
    expect(store.isMuted('g2', 'a'), isFalse);
    expect(store.isMuted('g1', 'b'), isFalse);
  });

  test('重复禁言同一角色不会产生重复项', () async {
    await store.setMuted(groupId: 'g1', characterId: 'a', muted: true);
    await store.setMuted(groupId: 'g1', characterId: 'a', muted: true);

    expect(store.mutedFor('g1'), {'a'});
  });

  test('重开 box 后禁言仍然生效', () async {
    await store.setMuted(groupId: 'g1', characterId: 'a', muted: true);

    await Hive.close();
    await reopenLifecycleHive(directory);

    expect(GroupMuteStore(DatabaseService()).isMuted('g1', 'a'), isTrue);
  });

  test('存储内容损坏时不抛异常，按无禁言处理', () async {
    await db.appSettingsBox.put(GroupMuteStore.storageKey, 'not-a-map');
    expect(store.mutedFor('g1'), isEmpty);

    await db.appSettingsBox
        .put(GroupMuteStore.storageKey, {'g1': 'not-a-list'});
    expect(store.mutedFor('g1'), isEmpty);

    await db.appSettingsBox.put(
      GroupMuteStore.storageKey,
      {
        'g1': [1, 'a', null],
      },
    );
    expect(store.mutedFor('g1'), {'a'}, reason: '非字符串项应被忽略');
  });

  group('mayAutoPick：禁言只拦自动挑选', () {
    test('未禁言 → 可以自动挑选', () {
      expect(
        store.mayAutoPick(groupId: 'g1', characterId: 'a', mentionedIds: {}),
        isTrue,
      );
    });

    test('已禁言且未被点名 → 不进入自动挑选', () async {
      await store.setMuted(groupId: 'g1', characterId: 'a', muted: true);

      expect(
        store.mayAutoPick(groupId: 'g1', characterId: 'a', mentionedIds: {}),
        isFalse,
      );
      expect(
        store.mayAutoPick(groupId: 'g1', characterId: 'a', mentionedIds: {'b'}),
        isFalse,
      );
    });

    test('已禁言但被点名 → 仍参与（语气仍由心情决定）', () async {
      await store.setMuted(groupId: 'g1', characterId: 'a', muted: true);

      expect(
        store.mayAutoPick(groupId: 'g1', characterId: 'a', mentionedIds: {'a'}),
        isTrue,
      );
    });
  });
}

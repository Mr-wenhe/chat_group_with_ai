import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/features/chat_group/chat_activity_policy.dart';
import 'package:flutter_test/flutter_test.dart';

ChatGroup _group({
  String? hostUserId,
  String? roomId,
  String? inviteCode,
}) {
  return ChatGroup(
    name: '周末去哪儿',
    theme: '闲聊',
    aiCharacterIds: const <String>['c1'],
    hostUserId: hostUserId,
    roomId: roomId,
    inviteCode: inviteCode,
  );
}

void main() {
  group('ChatGroup 的共享状态', () {
    test('从未共享过的群不是共享群，且任何人在自己机器上都是主人', () {
      // 向后兼容开关：老数据读出来 hostUserId 为 null，行为与加入实时功能之前一致。
      final group = _group();
      expect(group.isShared, isFalse);
      expect(group.isHost('任意用户'), isTrue);
    });

    test('已注册的群只有登记的那个 hostUserId 是主人', () {
      final group = _group(hostUserId: 'host-1', roomId: 'grp-1');
      expect(group.isShared, isTrue);
      expect(group.isHost('host-1'), isTrue);
      expect(group.isHost('guest-9'), isFalse);
    });

    test('只有 roomId 缺一半时按未共享处理', () {
      // 注册中途失败可能只写进去一半。此时既连不上也不该被当成客人，
      // 否则用户会看到一个永远"正在重连"、又没有任何客人权限的群。
      final halfRegistered = _group(hostUserId: 'host-1');
      expect(halfRegistered.isShared, isFalse);
      expect(halfRegistered.isHost('host-1'), isTrue);

      final halfJoined = _group(roomId: 'grp-1');
      expect(halfJoined.isShared, isFalse);
      expect(halfJoined.isHost('guest-9'), isTrue);
    });

    test('客人本地群默认不带任何 AI 角色', () {
      // 客人只说话和看，AI 回复全部由主人端生成后广播过来。
      final guestGroup = ChatGroup(
        name: '周末去哪儿',
        theme: '多人联机',
        aiCharacterIds: const <String>[],
        hostUserId: 'host-1',
        roomId: 'grp-1',
        inviteCode: '7K2M9P',
      );
      expect(guestGroup.isShared, isTrue);
      expect(guestGroup.isHost('guest-9'), isFalse);
      expect(guestGroup.aiCharacterIds, isEmpty);
    });
  });

  group('canStartAutoChat 的客人闸门', () {
    test('其他条件全部满足时，客人仍然不能启动空闲自动聊天', () {
      final forHost = ChatActivityPolicy.canStartAutoChat(
        workModeEnabled: false,
        autoChatEnabled: true,
        hasCharacters: true,
        hasApiConfig: true,
      );
      expect(forHost, isTrue);

      final forGuest = ChatActivityPolicy.canStartAutoChat(
        workModeEnabled: false,
        autoChatEnabled: true,
        hasCharacters: true,
        hasApiConfig: true,
        isGuest: true,
      );
      // 这是唯一的入口闸门。漏掉它，同一个群会在主人和客人的设备上各生成一遍 AI 发言。
      expect(forGuest, isFalse);
    });

    test('isGuest 默认为 false，老调用方行为不变', () {
      expect(
        ChatActivityPolicy.canStartAutoChat(
          workModeEnabled: false,
          autoChatEnabled: true,
          hasCharacters: true,
          hasApiConfig: true,
        ),
        isTrue,
      );
    });
  });
}

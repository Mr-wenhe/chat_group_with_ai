import 'dart:convert';

import 'package:chat_group/features/realtime/realtime_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _frame(String type, [Map<String, Object?> extra = const {}]) =>
    <String, Object?>{'type': type, ...extra};

void main() {
  group('parseRealtimeServerEvent', () {
    test('parses a joined frame with members and recent history', () {
      final event = parseRealtimeServerEvent(jsonEncode(_frame('joined', {
        'roomId': 'grp-1',
        'seq': 7,
        'members': [
          {'userId': 'u1', 'displayName': '小明'},
          {'userId': 'u2', 'displayName': '小红'},
        ],
        'recent': [
          {
            'roomId': 'grp-1',
            'seq': 6,
            'userId': 'u2',
            'displayName': '小红',
            'text': '在的',
            'sentAt': 1700000000000,
          },
        ],
      })));

      expect(event, isA<RealtimeJoined>());
      final joined = event! as RealtimeJoined;
      expect(joined.roomId, 'grp-1');
      expect(joined.seq, 7);
      expect(joined.members.map((m) => m.displayName), ['小明', '小红']);
      expect(joined.recent.single.text, '在的');
      expect(joined.recent.single.seq, 6);
    });

    test('parses an incoming message', () {
      final event = parseRealtimeServerEvent(jsonEncode(_frame('msg', {
        'roomId': 'grp-1',
        'seq': 9,
        'userId': 'u2',
        'displayName': '小红',
        'text': '晚上吃什么',
        'sentAt': 1700000000001,
      })));

      final message = (event! as RealtimeIncomingMessage).message;
      expect(message.seq, 9);
      expect(message.userId, 'u2');
      expect(message.text, '晚上吃什么');
    });

    test('parses presence and exposes join vs leave', () {
      final join = parseRealtimeServerEvent(jsonEncode(_frame('presence', {
        'event': 'join',
        'member': {'userId': 'u3', 'displayName': '阿强'},
        'members': [
          {'userId': 'u3', 'displayName': '阿强'},
        ],
      })))! as RealtimePresence;
      expect(join.isJoin, isTrue);
      expect(join.member.displayName, '阿强');

      final leave = parseRealtimeServerEvent(jsonEncode(_frame('presence', {
        'event': 'leave',
        'member': {'userId': 'u3', 'displayName': '阿强'},
        'members': const <Object?>[],
      })))! as RealtimePresence;
      expect(leave.isJoin, isFalse);
      expect(leave.members, isEmpty);
    });

    test('parses an error frame and tolerates a missing message', () {
      final event = parseRealtimeServerEvent(
        jsonEncode(_frame('error', {'code': 'ROOM_FULL'})),
      );
      final error = event! as RealtimeErrorEvent;
      expect(error.code, 'ROOM_FULL');
      expect(error.message, '');
    });

    test('returns null for malformed, unknown, or empty payloads', () {
      // 单条坏帧必须返回 null 而不是抛异常，否则监听流会被一条脏数据打断。
      expect(parseRealtimeServerEvent('not json'), isNull);
      expect(parseRealtimeServerEvent('[]'), isNull);
      expect(parseRealtimeServerEvent('null'), isNull);
      expect(parseRealtimeServerEvent(jsonEncode(_frame('something-new'))), isNull);
      expect(parseRealtimeServerEvent(jsonEncode(_frame('msg'))), isNull);
    });

    test('rejects frames with missing or wrongly typed required fields', () {
      expect(
        parseRealtimeServerEvent(jsonEncode(_frame('joined', {
          'roomId': 'grp-1',
          // seq 缺失
          'members': const <Object?>[],
          'recent': const <Object?>[],
        }))),
        isNull,
      );
      expect(
        parseRealtimeServerEvent(jsonEncode(_frame('msg', {
          'roomId': 'grp-1',
          'seq': '9', // 字符串而不是数字
          'userId': 'u2',
          'displayName': '小红',
          'text': 'hi',
          'sentAt': 1,
        }))),
        isNull,
      );
      expect(
        parseRealtimeServerEvent(jsonEncode(_frame('msg', {
          'roomId': 'grp-1',
          'seq': 9,
          'userId': 'u2',
          'displayName': '小红',
          'text': '', // 空文本视为非法
          'sentAt': 1,
        }))),
        isNull,
      );
    });

    test('discards a whole frame when one member entry is broken', () {
      // 宁可丢掉整帧，也不要把半截成员表交给界面——半截花名册比没有更难排查。
      expect(
        parseRealtimeServerEvent(jsonEncode(_frame('joined', {
          'roomId': 'grp-1',
          'seq': 1,
          'members': [
            {'userId': 'u1', 'displayName': '小明'},
            {'userId': 'u2'}, // 缺 displayName
          ],
          'recent': const <Object?>[],
        }))),
        isNull,
      );
    });
  });

  group('encode', () {
    test('join frame carries room, identity and display name', () {
      final decoded = jsonDecode(encodeRealtimeJoin(
        roomId: 'grp-1',
        userId: 'u1',
        displayName: '小明',
      )) as Map<String, Object?>;

      expect(decoded['type'], 'join');
      expect(decoded['roomId'], 'grp-1');
      expect(decoded['userId'], 'u1');
      expect(decoded['displayName'], '小明');
    });

    test('say frame sends only the text', () {
      // 身份由入群帧决定，发言帧带 userId 只会给伪造留下口子。
      final decoded =
          jsonDecode(encodeRealtimeSay('你好')) as Map<String, Object?>;
      expect(decoded, {'type': 'say', 'text': '你好'});
    });

    test('say frame carries the speaker when the host speaks for an AI', () {
      final decoded = jsonDecode(encodeRealtimeSay(
        '在的',
        speaker: const RealtimeSpeaker(id: 'char-1', name: '小明'),
      )) as Map<String, Object?>;
      expect(decoded, {
        'type': 'say',
        'text': '在的',
        'speaker': {'id': 'char-1', 'name': '小明'},
      });
    });

    test('普通成员发言不带 speaker 字段', () {
      // 少一个字段就少一次解析分支，服务端也据此保持与旧协议完全一致。
      final decoded =
          jsonDecode(encodeRealtimeSay('你好')) as Map<String, Object?>;
      expect(decoded.containsKey('speaker'), isFalse);
    });
  });

  group('RealtimeSpeaker', () {
    test('reads a well-formed speaker off a message', () {
      final message = RealtimeChatMessage.fromJson(<String, Object?>{
        'roomId': 'grp-1',
        'seq': 3,
        'userId': 'u1',
        'displayName': '小明',
        'text': '在的',
        'sentAt': 1700000000000,
        'speaker': {'id': 'char-1', 'name': '阿离'},
      });

      expect(message!.speaker, const RealtimeSpeaker(id: 'char-1', name: '阿离'));
      // 展示名要取真实作者，否则客人端会把 AI 的话记在主人头上。
      expect(message.authorName, '阿离');
    });

    test('falls back to the sending account when no speaker is present', () {
      final message = RealtimeChatMessage.fromJson(<String, Object?>{
        'roomId': 'grp-1',
        'seq': 3,
        'userId': 'u1',
        'displayName': '小明',
        'text': '在的',
        'sentAt': 1700000000000,
      });

      expect(message!.speaker, isNull);
      expect(message.authorName, '小明');
    });

    test('drops a malformed speaker instead of dropping the message', () {
      // 与 parseRealtimeServerEvent 的整体策略不同：缺字段的 speaker 只让
      // 这一层退化，消息本身照常显示，总好过整条发言凭空消失。
      final message = RealtimeChatMessage.fromJson(<String, Object?>{
        'roomId': 'grp-1',
        'seq': 3,
        'userId': 'u1',
        'displayName': '小明',
        'text': '在的',
        'sentAt': 1700000000000,
        'speaker': {'id': 'char-1'},
      });

      expect(message, isNotNull);
      expect(message!.speaker, isNull);
      expect(message.authorName, '小明');
    });
  });

  group('RealtimeGroupRegistration', () {
    test('reads the full invite response shape', () {
      final parsed = RealtimeGroupRegistration.fromJson(<String, Object?>{
        'roomId': 'grp-1',
        'inviteCode': '7K2M9P',
        'name': '周末去哪儿',
        'hostUserId': 'u1',
        'hostDisplayName': '小明',
      });

      expect(parsed, isNotNull);
      expect(parsed!.inviteCode, '7K2M9P');
      expect(parsed.hostDisplayName, '小明');
    });

    test('returns null when any required field is absent', () {
      expect(
        RealtimeGroupRegistration.fromJson(<String, Object?>{
          'roomId': 'grp-1',
          'inviteCode': '7K2M9P',
          // name / hostUserId / hostDisplayName 缺失
        }),
        isNull,
      );
      expect(RealtimeGroupRegistration.fromJson(const <Object?>[]), isNull);
    });
  });
}

/// 多人实时群聊的线协议，与服务端 `realtime/src/protocol.ts`、`http_api.ts` 一一对应。
///
/// 两边都是手写的，没有共享的 schema 生成器，改动其中一边时另一边必须同步，
/// 否则只会在运行时表现为「未知的消息类型」。
///
/// 本文件不碰任何 I/O，只做编解码，因此可以直接单测。
library;

import 'dart:convert';

/// 与服务端 `protocol.ts` 里的上限保持一致，超出即视为非法输入。
const int maxRealtimeUserIdLength = 128;
const int maxRealtimeDisplayNameLength = 64;
const int maxRealtimeTextLength = 4000;
const int maxRealtimeGroupNameLength = 64;

/// 邀请码输入的字符上限。
///
/// 服务端当前只生成 6 位，但查表接口本身不限制长度——这里纯粹是给输入框
/// 兜底，避免用户误粘贴一大段文本拼进 URL。所以取值比真实长度宽松，将来
/// 服务端改长度也不会立刻卡住老客户端。
const int maxRealtimeInviteCodeLength = 32;

/// 群成员：一个真人用户。
class RealtimeMember {
  const RealtimeMember({required this.userId, required this.displayName});

  final String userId;
  final String displayName;

  static RealtimeMember? fromJson(Object? json) {
    final map = _asMap(json);
    if (map == null) return null;
    final userId = _readString(map, 'userId');
    final displayName = _readString(map, 'displayName');
    if (userId == null || displayName == null) return null;
    return RealtimeMember(userId: userId, displayName: displayName);
  }

  @override
  bool operator ==(Object other) =>
      other is RealtimeMember &&
      other.userId == userId &&
      other.displayName == displayName;

  @override
  int get hashCode => Object.hash(userId, displayName);

  @override
  String toString() => 'RealtimeMember($userId, $displayName)';
}

/// 一句话的真实作者，当它不是发出这条帧的账号时使用。
///
/// 主人端会替本机的 AI 角色发言：帧的发送者是主人自己的账号，但这句话其实
/// 是「小明」这个角色说的。没有这层区分，客人端会把所有 AI 角色的发言都
/// 显示成主人一个人在说话。
class RealtimeSpeaker {
  const RealtimeSpeaker({required this.id, required this.name});

  /// 主人本机 Hive 里的角色 id。对客人而言只是个不透明的稳定字符串，
  /// 用来分组头像和去重；客人本机并没有这个角色。
  final String id;
  final String name;

  static RealtimeSpeaker? fromJson(Object? json) {
    final map = _asMap(json);
    if (map == null) return null;
    final id = _readString(map, 'id');
    final name = _readString(map, 'name');
    if (id == null || name == null) return null;
    return RealtimeSpeaker(id: id, name: name);
  }

  Map<String, Object?> toJson() => <String, Object?>{'id': id, 'name': name};

  @override
  bool operator ==(Object other) =>
      other is RealtimeSpeaker && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);

  @override
  String toString() => 'RealtimeSpeaker($id, $name)';
}

/// 服务端广播的一条群消息。[seq] 由服务端分配，是同一个房间里唯一的顺序依据。
class RealtimeChatMessage {
  const RealtimeChatMessage({
    required this.roomId,
    required this.seq,
    required this.userId,
    required this.displayName,
    required this.text,
    required this.sentAt,
    this.speaker,
  });

  final String roomId;
  final int seq;

  /// 发出这条帧的账号（主人端替 AI 发言时，这里是主人的 userId）。
  final String userId;
  final String displayName;
  final String text;

  /// 服务端接收时刻（epoch 毫秒）。不要用它和本机时钟直接比较排序。
  final int sentAt;

  /// 真实作者，仅在 [userId] 不是作者时出现（主人端替 AI 角色发言）。
  final RealtimeSpeaker? speaker;

  /// 展示这条消息时应该用的名字：优先真实作者，其次才是发帧账号。
  String get authorName => speaker?.name ?? displayName;

  static RealtimeChatMessage? fromJson(Object? json) {
    final map = _asMap(json);
    if (map == null) return null;
    final roomId = _readString(map, 'roomId');
    final seq = _readInt(map, 'seq');
    final userId = _readString(map, 'userId');
    final displayName = _readString(map, 'displayName');
    final text = _readString(map, 'text');
    final sentAt = _readInt(map, 'sentAt');
    if (roomId == null ||
        seq == null ||
        userId == null ||
        displayName == null ||
        text == null ||
        sentAt == null) {
      return null;
    }
    return RealtimeChatMessage(
      roomId: roomId,
      seq: seq,
      userId: userId,
      displayName: displayName,
      text: text,
      sentAt: sentAt,
      speaker: RealtimeSpeaker.fromJson(map['speaker']),
    );
  }

  @override
  String toString() => 'RealtimeChatMessage(seq: $seq, $authorName: $text)';
}

/// 服务端下行事件。
sealed class RealtimeServerEvent {
  const RealtimeServerEvent();
}

/// 入群成功。带回当前成员列表与最近的若干条消息，用于补齐断线期间的空档。
class RealtimeJoined extends RealtimeServerEvent {
  const RealtimeJoined({
    required this.roomId,
    required this.seq,
    required this.members,
    required this.recent,
  });

  final String roomId;
  final int seq;
  final List<RealtimeMember> members;
  final List<RealtimeChatMessage> recent;
}

/// 群里有人说话。包含自己发的那条（服务端回显），调用方需要按 userId 去重。
class RealtimeIncomingMessage extends RealtimeServerEvent {
  const RealtimeIncomingMessage(this.message);

  final RealtimeChatMessage message;
}

/// 有人进群或退群。[members] 是事件发生后的完整成员列表。
class RealtimePresence extends RealtimeServerEvent {
  const RealtimePresence({
    required this.event,
    required this.member,
    required this.members,
  });

  /// `'join'` 或 `'leave'`。
  final String event;
  final RealtimeMember member;
  final List<RealtimeMember> members;

  bool get isJoin => event == 'join';
}

/// 服务端拒绝或报错。`code` 见服务端 `protocol.ts` / `server.ts`。
class RealtimeErrorEvent extends RealtimeServerEvent {
  const RealtimeErrorEvent({required this.code, required this.message});

  final String code;
  final String message;
}

/// 解析一条服务端下行帧。
///
/// 解析失败返回 null 而不是抛异常：单条坏帧不应该让整条连接崩掉，
/// 调用方记录日志后继续即可。
RealtimeServerEvent? parseRealtimeServerEvent(String raw) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return null;
  }
  final map = _asMap(decoded);
  if (map == null) return null;

  switch (_readString(map, 'type')) {
    case 'joined':
      final roomId = _readString(map, 'roomId');
      final seq = _readInt(map, 'seq');
      final members = _readList(map, 'members', RealtimeMember.fromJson);
      final recent = _readList(map, 'recent', RealtimeChatMessage.fromJson);
      if (roomId == null || seq == null || members == null || recent == null) {
        return null;
      }
      return RealtimeJoined(
        roomId: roomId,
        seq: seq,
        members: members,
        recent: recent,
      );
    case 'msg':
      final message = RealtimeChatMessage.fromJson(map);
      return message == null ? null : RealtimeIncomingMessage(message);
    case 'presence':
      final event = _readString(map, 'event');
      final member = RealtimeMember.fromJson(map['member']);
      final members = _readList(map, 'members', RealtimeMember.fromJson);
      if (event == null || member == null || members == null) return null;
      return RealtimePresence(event: event, member: member, members: members);
    case 'error':
      final code = _readString(map, 'code');
      if (code == null) return null;
      return RealtimeErrorEvent(
        code: code,
        message: _readString(map, 'message') ?? '',
      );
    default:
      return null;
  }
}

/// 构造入群帧。[roomId] 决定进哪个房间，[userId] 是发言权的归属。
String encodeRealtimeJoin({
  required String roomId,
  required String userId,
  required String displayName,
}) {
  return jsonEncode(<String, Object?>{
    'type': 'join',
    'roomId': roomId,
    'userId': userId,
    'displayName': displayName,
  });
}

/// 构造发言帧。服务端从入群帧里取发送者身份，所以这里只需要文本。
///
/// [speaker] 只在「替别人说话」时传入——主人端把本机 AI 角色的回复广播出去，
/// 发送者仍是主人自己，但作者要写成那个角色。
String encodeRealtimeSay(String text, {RealtimeSpeaker? speaker}) {
  return jsonEncode(<String, Object?>{
    'type': 'say',
    'text': text,
    if (speaker != null) 'speaker': speaker.toJson(),
  });
}

/// 邀请码解析结果，对应服务端 `GET /v1/groups/{inviteCode}` 的响应体。
class RealtimeGroupRegistration {
  const RealtimeGroupRegistration({
    required this.roomId,
    required this.inviteCode,
    required this.name,
    required this.hostUserId,
    required this.hostDisplayName,
  });

  final String roomId;
  final String inviteCode;
  final String name;
  final String hostUserId;
  final String hostDisplayName;

  static RealtimeGroupRegistration? fromJson(Object? json) {
    final map = _asMap(json);
    if (map == null) return null;
    final roomId = _readString(map, 'roomId');
    final inviteCode = _readString(map, 'inviteCode');
    final name = _readString(map, 'name');
    final hostUserId = _readString(map, 'hostUserId');
    final hostDisplayName = _readString(map, 'hostDisplayName');
    if (roomId == null ||
        inviteCode == null ||
        name == null ||
        hostUserId == null ||
        hostDisplayName == null) {
      return null;
    }
    return RealtimeGroupRegistration(
      roomId: roomId,
      inviteCode: inviteCode,
      name: name,
      hostUserId: hostUserId,
      hostDisplayName: hostDisplayName,
    );
  }
}

Map<String, Object?>? _asMap(Object? json) {
  if (json is Map<String, Object?>) return json;
  if (json is Map) {
    return json.map((key, value) => MapEntry(key.toString(), value));
  }
  return null;
}

String? _readString(Map<String, Object?> json, String key) {
  final value = json[key];
  return value is String && value.isNotEmpty ? value : null;
}

int? _readInt(Map<String, Object?> json, String key) {
  final value = json[key];
  return value is int ? value : null;
}

List<T>? _readList<T>(
  Map<String, Object?> json,
  String key,
  T? Function(Object?) parse,
) {
  final value = json[key];
  if (value is! List) return null;
  final result = <T>[];
  for (final entry in value) {
    final parsed = parse(entry);
    // 一条坏元素就当作整帧非法：宁可丢弃也不要半截成员表。
    if (parsed == null) return null;
    result.add(parsed);
  }
  return result;
}

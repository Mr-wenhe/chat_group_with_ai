import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:chat_group/features/realtime/realtime_client.dart';
import 'package:chat_group/features/realtime/realtime_protocol.dart';
import 'package:chat_group/features/realtime/realtime_socket_types.dart';
import 'package:flutter_test/flutter_test.dart';

/// 退避抖动恒为 0 的随机源，让"多少毫秒后重连"在测试里是确定的。
class _NoJitter implements Random {
  @override
  int nextInt(int max) => 0;

  @override
  bool nextBool() => false;

  @override
  double nextDouble() => 0;
}

class _FakeSocket implements RealtimeSocket {
  _FakeSocket(this.uri);

  final Uri uri;
  final List<String> sent = <String>[];
  bool closed = false;
  final _controller = StreamController<String>.broadcast();

  @override
  Stream<String> get messages => _controller.stream;

  @override
  void send(String frame) => sent.add(frame);

  @override
  Future<void> close() async {
    closed = true;
    if (!_controller.isClosed) await _controller.close();
  }

  void emit(String frame) {
    if (!_controller.isClosed) _controller.add(frame);
  }

  /// 模拟网络中断：流直接结束，客户端应当走重连分支。
  Future<void> drop() async {
    if (!_controller.isClosed) await _controller.close();
  }
}

class _FakeOpener {
  final List<_FakeSocket> sockets = <_FakeSocket>[];
  bool failNextOpen = false;

  Future<RealtimeSocket> open(Uri uri) async {
    if (failNextOpen) {
      failNextOpen = false;
      throw StateError('dial failed');
    }
    final socket = _FakeSocket(uri);
    sockets.add(socket);
    return socket;
  }
}

String _joinedFrame({int seq = 1}) => jsonEncode(<String, Object?>{
      'type': 'joined',
      'roomId': 'grp-1',
      'seq': seq,
      'members': <Object?>[],
      'recent': <Object?>[],
    });

String _messageFrame({int seq = 2, String text = '你好'}) =>
    jsonEncode(<String, Object?>{
      'roomId': 'grp-1',
      'seq': seq,
      'userId': 'u2',
      'displayName': '小红',
      'text': text,
      'sentAt': 1700000000000,
      'type': 'msg',
    });

/// 让事件循环跑几轮，等 Timer(Duration.zero) 与各层 await 落地。
Future<void> _pump([int turns = 6]) async {
  for (var index = 0; index < turns; index += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}

RealtimeClient _client(_FakeOpener opener) => RealtimeClient(
      uri: Uri.parse('ws://relay.invalid/?token=t'),
      roomId: 'grp-1',
      userId: 'u1',
      displayName: '小明',
      opener: opener.open,
      reconnectBaseDelay: Duration.zero,
      // 直接把重连间隔压到 0，测试才不必真的等退避。
      random: _NoJitter(),
    );

void main() {
  test('首次连接立刻发送入群帧，且要等 joined 才算连上', () async {
    final opener = _FakeOpener();
    final client = _client(opener);
    addTearDown(client.dispose);

    await client.connect();

    expect(opener.sockets, hasLength(1));
    expect(client.state.value, RealtimeConnectionState.connecting);
    // join 必须紧跟握手发出：服务端限制了入群时限。
    final join = jsonDecode(opener.sockets.single.sent.single)
        as Map<String, Object?>;
    expect(join['type'], 'join');
    expect(join['roomId'], 'grp-1');
    expect(join['userId'], 'u1');
    expect(join['displayName'], '小明');

    opener.sockets.single.emit(_joinedFrame());
    await _pump();
    expect(client.state.value, RealtimeConnectionState.connected);
  });

  test('未入群前 say 返回 false 且不发出任何帧', () async {
    final opener = _FakeOpener();
    final client = _client(opener);
    addTearDown(client.dispose);

    await client.connect();
    expect(client.say('这条不该发出去'), isFalse);
    expect(opener.sockets.single.sent, hasLength(1)); // 只有 join

    opener.sockets.single.emit(_joinedFrame());
    await _pump();
    expect(client.say('现在可以了'), isTrue);
    final frames = opener.sockets.single.sent;
    expect(frames, hasLength(2));
    expect(jsonDecode(frames.last), {'type': 'say', 'text': '现在可以了'});

    // 替 AI 角色发言时，帧里必须带上真实作者，客人端才知道是谁说的。
    expect(
      client.say('在的', speaker: const RealtimeSpeaker(id: 'char-1', name: '小明')),
      isTrue,
    );
    expect(jsonDecode(opener.sockets.single.sent.last), {
      'type': 'say',
      'text': '在的',
      'speaker': {'id': 'char-1', 'name': '小明'},
    });
  });

  test('重复 connect 不会开出第二条连接', () async {
    final opener = _FakeOpener();
    final client = _client(opener);
    addTearDown(client.dispose);

    await client.connect();
    await client.connect();
    await client.connect();

    expect(opener.sockets, hasLength(1));
  });

  test('掉线后进入 reconnecting，并按退避自动重连', () async {
    final opener = _FakeOpener();
    final client = _client(opener);
    addTearDown(client.dispose);

    await client.connect();
    opener.sockets.single.emit(_joinedFrame());
    await _pump();
    expect(client.state.value, RealtimeConnectionState.connected);

    await opener.sockets.single.drop();
    await _pump();
    expect(client.state.value, RealtimeConnectionState.reconnecting);
    expect(opener.sockets, hasLength(2));

    // 重连成功后再入群，状态回到 connected。
    opener.sockets.last.emit(_joinedFrame(seq: 5));
    await _pump();
    expect(client.state.value, RealtimeConnectionState.connected);
  });

  test('建立连接本身失败时也会退避重试，而不是停在 connecting', () async {
    final opener = _FakeOpener()..failNextOpen = true;
    final client = _client(opener);
    addTearDown(client.dispose);

    // connect() 的 Future 在微任务里完成，重试的 Timer 还没到点，
    // 所以这里能看到"失败后先回到 reconnecting、还没重试"的中间态。
    await client.connect();
    expect(opener.sockets, isEmpty);
    expect(client.state.value, RealtimeConnectionState.reconnecting);

    await _pump();
    expect(opener.sockets, hasLength(1));
  });

  test('服务端明确报错后掉线进入 closed，且不再重连', () async {
    final opener = _FakeOpener();
    final client = _client(opener);
    addTearDown(client.dispose);

    await client.connect();
    opener.sockets.single.emit(jsonEncode(<String, Object?>{
      'type': 'error',
      'code': 'ROOM_FULL',
      'message': 'room is full',
    }));
    await _pump();
    await opener.sockets.single.drop();
    await _pump();

    expect(client.state.value, RealtimeConnectionState.closed);
    expect(opener.sockets, hasLength(1));
  });

  test('坏帧只被丢掉，不影响后续帧的解析', () async {
    final opener = _FakeOpener();
    final client = _client(opener);
    addTearDown(client.dispose);

    final received = <RealtimeServerEvent>[];
    final subscription = client.events.listen(received.add);
    addTearDown(subscription.cancel);

    await client.connect();
    final socket = opener.sockets.single;
    socket.emit('这不是 JSON');
    socket.emit('{"type":"unknown-future-frame"}');
    socket.emit(_joinedFrame());
    socket.emit(_messageFrame(text: '还好没断'));
    await _pump();

    expect(client.state.value, RealtimeConnectionState.connected);
    expect(received.whereType<RealtimeJoined>(), hasLength(1));
    final messages = received.whereType<RealtimeIncomingMessage>().toList();
    expect(messages, hasLength(1));
    expect(messages.single.message.text, '还好没断');
  });

  test('dispose 关闭套接字并停止后续重连', () async {
    final opener = _FakeOpener();
    final client = _client(opener);

    await client.connect();
    final socket = opener.sockets.single;
    await client.dispose();
    // dispose 会先取消订阅再关套接字，所以这里不会有 onDone 触发的重连。
    expect(socket.closed, isTrue);

    await socket.drop();
    await _pump();
    expect(opener.sockets, hasLength(1));
  });
}

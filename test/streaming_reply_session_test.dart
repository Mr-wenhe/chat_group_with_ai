import 'dart:async';

import 'package:chat_group/core/streaming/chat_stream_event.dart';
import 'package:chat_group/features/chat_group/streaming_reply_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('collects tokens and usage into one completed result', () async {
    final session = StreamingReplySession(flushInterval: Duration.zero);
    final drafts = <String>[];

    final result = await session.run(
      Stream.fromIterable([
        ChatStreamEvent.token('你'),
        ChatStreamEvent.token('好'),
        ChatStreamEvent.done('你好', null, 3, 2, 1),
      ]),
      onDraft: drafts.add,
    );

    expect(result.content, '你好');
    expect(result.failed, isFalse);
    expect(result.stopped, isFalse);
    expect(result.promptTokens, 3);
    expect(result.completionTokens, 2);
    expect(drafts.last, '你好');
  });

  test('stop completes the run and keeps partial content', () async {
    final controller = StreamController<ChatStreamEvent>();
    final session = StreamingReplySession(flushInterval: Duration.zero);
    final run = session.run(controller.stream, onDraft: (_) {});
    controller.add(ChatStreamEvent.token('partial'));
    await Future<void>.delayed(Duration.zero);

    await session.stop();
    final result = await run;

    expect(result.content, 'partial');
    expect(result.stopped, isTrue);
    await controller.close();
  });

  test('dispose prevents callbacks after page teardown', () async {
    final controller = StreamController<ChatStreamEvent>();
    final session = StreamingReplySession(flushInterval: Duration.zero);
    var callbackCount = 0;
    final run = session.run(
      controller.stream,
      onDraft: (_) => callbackCount++,
    );

    await session.dispose();
    controller.add(ChatStreamEvent.token('late'));
    await controller.close();
    await run;

    expect(callbackCount, 0);
  });
}

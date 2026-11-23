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

  test('dispose cancels the owned SSE subscription', () async {
    var cancelled = false;
    final controller = StreamController<ChatStreamEvent>(
      onCancel: () {
        cancelled = true;
      },
    );
    final session = StreamingReplySession(flushInterval: Duration.zero);
    final run = session.run(controller.stream, onDraft: (_) {});

    await session.dispose();
    await run;

    expect(cancelled, isTrue);
    await controller.close();
  });

  // 上游发完响应头就静默：async* 卡在 await 上，订阅取消打断不了它。
  Stream<ChatStreamEvent> stalledSource() async* {
    await Completer<void>().future;
    yield const ChatStreamEvent(type: ChatStreamEventType.done);
  }

  test('上游卡在 await 时 stop() 仍然立即收尾', () async {
    final session = StreamingReplySession(flushInterval: Duration.zero);
    final run = session.run(stalledSource(), onDraft: (_) {});
    expect(session.isActive, isTrue);

    await session.stop().timeout(const Duration(seconds: 1));

    final result = await run.timeout(const Duration(seconds: 1));
    expect(result.stopped, isTrue);
    expect(session.isActive, isFalse);
  });

  test('正文停滞看门狗把静默流判为失败，而不是永久生成中', () async {
    final session = StreamingReplySession(
      flushInterval: Duration.zero,
      stallTimeout: const Duration(milliseconds: 50),
    );
    final run = session.run(stalledSource(), onDraft: (_) {});

    final result = await run.timeout(const Duration(seconds: 2));

    expect(session.isActive, isFalse);
    expect(result.failed, isTrue);
    expect(result.stopped, isFalse, reason: '不是用户停止，失败必须能落成可见回复');
    expect(result.error, contains('超时'));
  });

  test('停止与看门狗都会通知上游放弃请求', () async {
    var cancels = 0;
    final session = StreamingReplySession(
      flushInterval: Duration.zero,
      stallTimeout: const Duration(milliseconds: 50),
      onCancel: () => cancels++,
    );
    final run = session.run(stalledSource(), onDraft: (_) {});
    await run.timeout(const Duration(seconds: 2));
    expect(cancels, 1);

    var stopCancels = 0;
    final stopping = StreamingReplySession(
      flushInterval: Duration.zero,
      onCancel: () => stopCancels++,
    );
    final stoppingRun = stopping.run(stalledSource(), onDraft: (_) {});
    await stopping.stop();
    await stoppingRun;
    expect(stopCancels, 1);
  });

  test('兼容重试会通知界面，且那一帧不算正文', () async {
    var notified = 0;
    final controller = StreamController<ChatStreamEvent>();
    final session = StreamingReplySession(
      flushInterval: Duration.zero,
      onCompatibilityRetry: () => notified++,
    );
    final drafts = <String>[];
    final run = session.run(controller.stream, onDraft: drafts.add);

    controller.add(const ChatStreamEvent(
      type: ChatStreamEventType.token,
      delta: '',
      transportFailure: ChatStreamEvent(
        type: ChatStreamEventType.error,
        message: '采样参数不被接受',
      ),
    ));
    controller.add(ChatStreamEvent.done('OK', null, 1, 1, 0));
    final result = await run.timeout(const Duration(seconds: 1));

    expect(notified, 1);
    expect(result.content, 'OK');
    expect(result.failed, isFalse);
    await controller.close();
  });

  test('持续有事件到达时看门狗不会误杀', () async {
    final session = StreamingReplySession(
      flushInterval: Duration.zero,
      stallTimeout: const Duration(milliseconds: 400),
    );
    final run = session.run(
      () async* {
        for (var index = 0; index < 4; index++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          yield ChatStreamEvent.token('段$index');
        }
        yield const ChatStreamEvent(type: ChatStreamEventType.done);
      }(),
      onDraft: (_) {},
    );

    final result = await run.timeout(const Duration(seconds: 2));

    expect(result.failed, isFalse);
    expect(result.content, contains('段3'));
  });
}

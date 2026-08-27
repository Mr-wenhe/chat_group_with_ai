import 'dart:async';

import 'package:chat_group/core/streaming/chat_stream_event.dart';
import 'package:chat_group/features/chat_group/streaming_reply_commit_policy.dart';
import 'package:chat_group/features/chat_group/streaming_reply_session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('停止后的流结果标记为 stopped 且不会进入提交路径', () async {
    final events = StreamController<ChatStreamEvent>();
    final session = StreamingReplySession(flushInterval: Duration.zero);
    final drafts = <String>[];
    final resultFuture = session.run(
      events.stream,
      onDraft: drafts.add,
    );

    events.add(ChatStreamEvent.token('部分回复'));
    await Future<void>.delayed(Duration.zero);
    await session.stop();
    final result = await resultFuture;

    expect(result.stopped, isTrue);
    expect(result.content, '部分回复');
    expect(drafts, contains('部分回复'));
    expect(
      shouldDiscardStreamingReply(
        stopped: result.stopped,
        pageActive: true,
        conversationStopping: false,
      ),
      isTrue,
    );
    await events.close();
  });

  test('页面离开或会话进入 stopping 阶段也禁止提交流结果', () {
    expect(
      shouldDiscardStreamingReply(
        stopped: false,
        pageActive: false,
        conversationStopping: false,
      ),
      isTrue,
    );
    expect(
      shouldDiscardStreamingReply(
        stopped: false,
        pageActive: true,
        conversationStopping: true,
      ),
      isTrue,
    );
    expect(
      shouldDiscardStreamingReply(
        stopped: false,
        pageActive: true,
        conversationStopping: false,
      ),
      isFalse,
    );
  });

  test('工作模式切换只有在确有活跃流时才设置丢弃标记', () {
    expect(
      shouldArmDiscardOnWorkModeToggle(
        schedulerRunning: true,
        streamActive: false,
      ),
      isFalse,
    );
    expect(
      shouldArmDiscardOnWorkModeToggle(
        schedulerRunning: true,
        streamActive: true,
      ),
      isTrue,
    );
    expect(
      shouldArmDiscardOnWorkModeToggle(
        schedulerRunning: false,
        streamActive: true,
      ),
      isFalse,
    );
  });
}

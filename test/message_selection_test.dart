import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/features/chat_group/message_selection.dart';
import 'package:chat_group/features/work_mode/work_mode_task_lifecycle.dart';
import 'package:flutter_test/flutter_test.dart';

/// 多选能勾到哪些消息，与单条删除能给哪些消息入口必须是同一个判据。
void main() {
  Message messageOf(String id) => Message(
        id: id,
        groupId: 'g',
        senderId: 'user',
        senderType: 'user',
        content: id,
      );

  test('普通消息都可勾选', () {
    final selectable = selectableMessageIds(
      [messageOf('m1'), messageOf('m2')],
      streamingMessageId: null,
      isRealtimeGuest: false,
    );

    expect(selectable, {'m1', 'm2'});
  });

  test('工作模式进度气泡不可勾选', () {
    const progressId =
        '${WorkModeTaskLifecycle.progressMessageIdPrefix}task-1';
    final selectable = selectableMessageIds(
      [messageOf('m1'), messageOf(progressId)],
      streamingMessageId: null,
      isRealtimeGuest: false,
    );

    expect(selectable, {'m1'});
  });

  test('正在流式输出的那条不可勾选', () {
    final selectable = selectableMessageIds(
      [messageOf('m1'), messageOf('m2')],
      streamingMessageId: 'm2',
      isRealtimeGuest: false,
    );

    expect(selectable, {'m1'});
  });

  test('客人端一条都不可勾选', () {
    final selectable = selectableMessageIds(
      [messageOf('m1'), messageOf('m2')],
      streamingMessageId: null,
      isRealtimeGuest: true,
    );

    expect(selectable, isEmpty);
  });

  test('只覆盖传进来的这一页，不替调用方去捞更早的消息', () {
    final selectable = selectableMessageIds(
      [messageOf('m1')],
      streamingMessageId: null,
      isRealtimeGuest: false,
    );

    expect(
      selectable,
      {'m1'},
      reason: '全选若越过已加载窗口，用户会删掉自己没读过的旧消息',
    );
  });
}

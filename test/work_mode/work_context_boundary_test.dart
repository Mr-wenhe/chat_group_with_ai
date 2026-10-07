import 'dart:io';

import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/features/work_mode/work_context_boundary.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

/// 删除工作任务后划下的「工作上下文分界线」。
///
/// 语义只有一个方向：线之前的聊天消息永不进入工作任务的模型提示。这里钉住的
/// 核心就是方向性——无论值损坏、还是有人把线往回调，旧上下文都不该复活。
void main() {
  late Directory directory;
  late Box<dynamic> settingsBox;

  setUp(() async {
    directory =
        await Directory.systemTemp.createTemp('work-context-boundary-test-');
    Hive.init(directory.path);
    settingsBox = await Hive.openBox<dynamic>('app_settings');
  });

  tearDown(() async {
    await Hive.close();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  Message messageAt(String content, DateTime timestamp) => Message(
        groupId: 'g1',
        senderId: 'user',
        senderType: 'user',
        content: content,
        timestamp: timestamp,
      );

  List<String> visibleContents(
    Iterable<Message> messages, {
    String conversationId = 'g1',
  }) =>
      WorkContextBoundary.visible(settingsBox, conversationId, messages)
          .map((message) => message.content)
          .toList();

  final base = DateTime(2026, 9, 30, 10);
  final onTheLine = base.add(const Duration(minutes: 1));

  test('分界线之前与恰在分界线上的消息不可见，之后的消息按原顺序保留', () async {
    await WorkContextBoundary.advance(settingsBox, 'g1', onTheLine);
    expect(
      visibleContents([
        messageAt('线前', base),
        messageAt('线上', onTheLine),
        messageAt('线后', onTheLine.add(const Duration(minutes: 1))),
        messageAt('更后', onTheLine.add(const Duration(minutes: 2))),
      ]),
      ['线后', '更后'],
      reason: '严格晚于分界线才可见；把线上也算进去，旧上下文就没有被切断',
    );
  });

  test('没有分界线时全部消息可见', () async {
    expect(
      visibleContents([
        messageAt('第一条', base),
        messageAt('第二条', onTheLine),
      ]),
      ['第一条', '第二条'],
      reason: '从未删除过任务的会话不该被过滤',
    );
  });

  test('advance 写下的时刻可以被读回', () async {
    final at = DateTime(2026, 9, 30, 10, 30);
    await WorkContextBoundary.advance(settingsBox, 'g1', at);
    expect(WorkContextBoundary.readAt(settingsBox, 'g1'), at);
  });

  test('分界线只前进：更早的时刻不会把它往回调', () async {
    final later = DateTime(2026, 9, 30, 12);
    await WorkContextBoundary.advance(settingsBox, 'g1', later);
    await WorkContextBoundary.advance(settingsBox, 'g1', DateTime(2026, 9, 30, 9));
    expect(
      WorkContextBoundary.readAt(settingsBox, 'g1'),
      later,
      reason: '回退会把已经被切断的旧上下文重新放回模型提示',
    );
  });

  test('损坏的值视为没有分界线，并被下一次 advance 覆写', () async {
    await settingsBox.put(WorkContextBoundary.storageKey('g1'), 12345);
    expect(
      WorkContextBoundary.readAt(settingsBox, 'g1'),
      isNull,
      reason: '读不懂的值不能当成一条有效分界线',
    );
    final at = DateTime(2026, 9, 30, 11);
    await WorkContextBoundary.advance(settingsBox, 'g1', at);
    expect(WorkContextBoundary.readAt(settingsBox, 'g1'), at);
  });

  test('分界线按会话维度存放，DM 键里的冒号不影响还原', () async {
    expect(
      WorkContextBoundary.storageKey('dm:c1'),
      'work_mode_context_boundary:dm:c1',
    );
    final at = DateTime(2026, 9, 30, 11);
    await WorkContextBoundary.advance(settingsBox, 'dm:c1', at);
    expect(WorkContextBoundary.readAt(settingsBox, 'dm:c1'), at);
    expect(
      WorkContextBoundary.readAt(settingsBox, 'g1'),
      isNull,
      reason: '一个会话的分界线不能泄漏到另一个会话',
    );
  });
}

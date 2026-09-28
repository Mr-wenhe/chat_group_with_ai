import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/work_mode/presentation/work_task_tab_visibility.dart';
import 'package:flutter_test/flutter_test.dart';

AgentTask _task(
  String id, {
  required String conversationId,
  AgentTaskStatus status = AgentTaskStatus.planning,
  int day = 1,
}) {
  return AgentTask(
    id: id,
    groupId: conversationId,
    characterId: 'developer',
    userRequest: '整理发布说明',
    status: status,
    workModeTask: true,
    updatedAt: DateTime.utc(2026, 5, day),
  );
}

void main() {
  group('WorkTaskTabVisibility.visibleTasks', () {
    test('shows the current conversation and running tasks from elsewhere', () {
      final mine = _task('mine', conversationId: 'dm:mine');
      final myFinished = _task(
        'mine-finished',
        conversationId: 'dm:mine',
        status: AgentTaskStatus.completed,
      );
      final elsewhereRunning = _task(
        'elsewhere-running',
        conversationId: 'group-running',
        status: AgentTaskStatus.runningTool,
      );
      final elsewhereFinished = _task(
        'elsewhere-finished',
        conversationId: 'group-old',
        status: AgentTaskStatus.failed,
      );

      final visible = WorkTaskTabVisibility.visibleTasks(
        <AgentTask>[
          mine,
          myFinished,
          elsewhereRunning,
          elsewhereFinished,
        ],
        hiddenTaskIds: const <String>{},
        activeConversationId: 'dm:mine',
      );

      final ids = visible.map((task) => task.id).toList();
      // 别的会话的终态任务曾经占满标签栏，把当前会话的任务挤出去。
      expect(ids, isNot(contains('elsewhere-finished')));
      expect(ids, containsAll(<String>['mine', 'mine-finished']));
      // 切走页面任务照跑：别的会话里执行中的任务必须留着。
      expect(ids, contains('elsewhere-running'));
      // 执行中的排在前面，免得被更新的排队任务挤掉。
      expect(ids.first, 'mine');
    });

    test('caps the strip and appends the task the user asked for', () {
      final tasks = <AgentTask>[
        for (var index = 0; index < 6; index++)
          _task('task-$index', conversationId: 'dm:cap', day: index + 1),
      ];

      final capped = WorkTaskTabVisibility.visibleTasks(
        tasks,
        hiddenTaskIds: const <String>{},
        activeConversationId: 'dm:cap',
      );
      expect(capped.length, WorkTaskTabVisibility.maxTabs);

      // 从聊天卡片点名打开的任务必须能看见，哪怕它已经被折叠掉。
      final withPreferred = WorkTaskTabVisibility.visibleTasks(
        tasks,
        hiddenTaskIds: const <String>{},
        activeConversationId: 'dm:cap',
        preferredTaskId: 'task-0',
      );
      expect(withPreferred.map((task) => task.id), contains('task-0'));
      expect(withPreferred.length, WorkTaskTabVisibility.maxTabs + 1);
    });

    test('keeps the previous behaviour when no conversation is active', () {
      // 不在任何会话里（角色列表、设置页）时没有可归属的会话：两个执行槽都占满
      // 就只展示执行中的任务，槽位空闲才补上其余标签。
      final running = <AgentTask>[
        _task('running-a', conversationId: 'group-a', status: AgentTaskStatus.planning, day: 3),
        _task('running-b', conversationId: 'group-b', status: AgentTaskStatus.runningTool, day: 2),
      ];
      final queued = _task('queued', conversationId: 'group-c', status: AgentTaskStatus.queued, day: 4);

      final busy = WorkTaskTabVisibility.visibleTasks(
        <AgentTask>[...running, queued],
        hiddenTaskIds: const <String>{},
        activeConversationId: null,
      );
      expect(busy.map((task) => task.id), <String>['running-a', 'running-b']);

      final free = WorkTaskTabVisibility.visibleTasks(
        <AgentTask>[running.first, queued],
        hiddenTaskIds: const <String>{},
        activeConversationId: null,
      );
      expect(free.map((task) => task.id), containsAll(<String>['running-a', 'queued']));
    });
  });

  group('WorkTaskTabVisibility.foldedUnfinishedCount', () {
    test('counts only unfinished tasks of the current conversation', () {
      final visible = <AgentTask>[
        for (var index = 0; index < 4; index++)
          _task('shown-$index', conversationId: 'dm:count', day: index + 2),
      ];
      final all = <AgentTask>[
        ...visible,
        _task(
          'folded-paused',
          conversationId: 'dm:count',
          status: AgentTaskStatus.paused,
          day: 1,
        ),
        // 本会话已结束的任务、别的会话的失败任务，都不算"队列"。
        _task(
          'mine-finished',
          conversationId: 'dm:count',
          status: AgentTaskStatus.completed,
          day: 1,
        ),
        _task(
          'elsewhere-failed',
          conversationId: 'group-elsewhere',
          status: AgentTaskStatus.failed,
          day: 9,
        ),
      ];

      expect(
        WorkTaskTabVisibility.foldedUnfinishedCount(
          all,
          visible,
          hiddenTaskIds: const <String>{},
          activeConversationId: 'dm:count',
        ),
        1,
      );
      // 用户自己关掉的标签不再提示。
      expect(
        WorkTaskTabVisibility.foldedUnfinishedCount(
          all,
          visible,
          hiddenTaskIds: <String>{'folded-paused'},
          activeConversationId: 'dm:count',
        ),
        0,
      );
      // 没有当前会话就没有"本会话队列"这回事。
      expect(
        WorkTaskTabVisibility.foldedUnfinishedCount(
          all,
          visible,
          hiddenTaskIds: const <String>{},
          activeConversationId: null,
        ),
        0,
      );
    });
  });

  group('WorkTaskTabVisibility.hasContent', () {
    test('keeps the panel for the conversation history entry point', () {
      // 标签栏为空但本会话仍有记录：面板必须留着，否则「历史任务」入口也消失。
      final finished = _task(
        'finished',
        conversationId: 'dm:history',
        status: AgentTaskStatus.completed,
      );
      expect(
        WorkTaskTabVisibility.hasContent(
          <AgentTask>[finished],
          const <AgentTask>[],
          hiddenTaskIds: const <String>{},
          activeConversationId: 'dm:history',
        ),
        isTrue,
      );
      // 别的会话的终态记录不再让面板出现。
      expect(
        WorkTaskTabVisibility.hasContent(
          <AgentTask>[finished],
          const <AgentTask>[],
          hiddenTaskIds: const <String>{},
          activeConversationId: null,
        ),
        isFalse,
      );
      // 被用户关掉的标签仍然让面板留着，否则再也找不回来。
      expect(
        WorkTaskTabVisibility.hasContent(
          <AgentTask>[finished],
          const <AgentTask>[],
          hiddenTaskIds: const <String>{'finished'},
          activeConversationId: null,
        ),
        isTrue,
      );
    });
  });
}

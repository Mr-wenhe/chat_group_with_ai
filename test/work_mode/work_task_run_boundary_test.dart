import 'package:chat_group/features/work_mode/work_task_event.dart';
import 'package:chat_group/features/work_mode/work_task_run_boundary.dart';
import 'package:flutter_test/flutter_test.dart';

WorkTaskEvent _event(
  int sequence, {
  WorkTaskEventKind kind = WorkTaskEventKind.toolOutput,
  String title = '执行了一件事',
  Map<String, dynamic>? safeMetadata,
}) {
  return WorkTaskEvent(
    taskId: 'task-1',
    sequence: sequence,
    timestamp: DateTime.utc(2026, 9, 11).add(Duration(minutes: sequence)),
    kind: kind,
    title: title,
    safeMetadata: safeMetadata,
  );
}

void main() {
  group('WorkTaskRunBoundary', () {
    test('没有分界时整条日志算一段', () {
      final events = <WorkTaskEvent>[_event(1), _event(2), _event(3)];

      expect(WorkTaskRunBoundary.currentRunStartIndex(events), 0);
    });

    test('旧日志靠标题认分界，分界事件本身属于新的一段', () {
      final events = <WorkTaskEvent>[
        _event(1),
        _event(2),
        _event(3, kind: WorkTaskEventKind.queued, title: '开始处理已排队的追问'),
        _event(4, kind: WorkTaskEventKind.planning, title: '任务开始执行'),
      ];

      expect(WorkTaskRunBoundary.currentRunStartIndex(events), 2);
    });

    test('新事件靠 safeMetadata 标记认分界，标题改动也不影响', () {
      final events = <WorkTaskEvent>[
        _event(1),
        _event(
          2,
          kind: WorkTaskEventKind.queued,
          title: '换了一句文案',
          safeMetadata: const <String, dynamic>{
            WorkTaskRunBoundary.metadataKey: WorkTaskRunBoundary.followUpPromotion,
          },
        ),
        _event(3),
      ];

      expect(WorkTaskRunBoundary.currentRunStartIndex(events), 1);
    });

    test('标记值不是本约定的取值、标题也不是旧文案时不算分界', () {
      final events = <WorkTaskEvent>[
        _event(1),
        _event(
          2,
          kind: WorkTaskEventKind.queued,
          title: '换了一句文案',
          safeMetadata: const <String, dynamic>{
            WorkTaskRunBoundary.metadataKey: 'somethingElse',
          },
        ),
      ];

      expect(WorkTaskRunBoundary.currentRunStartIndex(events), 0);
    });

    test('旧文案即便被新标记否掉也仍按旧日志分段', () {
      // 存量日志里那条事件没有任何标记。新约定只加标记、不改判定：带上别的标记
      // 也不能让已经落盘的历史重新铺满面板。
      final events = <WorkTaskEvent>[
        _event(1),
        _event(
          2,
          kind: WorkTaskEventKind.queued,
          title: '开始处理已排队的追问',
          safeMetadata: const <String, dynamic>{
            WorkTaskRunBoundary.metadataKey: 'somethingElse',
          },
        ),
      ];

      expect(WorkTaskRunBoundary.currentRunStartIndex(events), 1);
    });

    test('取最后一次分界：一条记录里并入了多轮请求', () {
      final events = <WorkTaskEvent>[
        _event(1),
        _event(2, kind: WorkTaskEventKind.queued, title: '开始处理已排队的追问'),
        _event(3),
        _event(4, kind: WorkTaskEventKind.queued, title: '开始处理已排队的追问'),
        _event(5),
      ];

      expect(WorkTaskRunBoundary.currentRunStartIndex(events), 3);
    });

    test('同名的 queued 事件若不是这条提示就不算分界', () {
      final events = <WorkTaskEvent>[
        _event(1),
        _event(2, kind: WorkTaskEventKind.queued, title: '任务已排队'),
      ];

      expect(WorkTaskRunBoundary.currentRunStartIndex(events), 0);
    });

    test('分界正好是最后一条时，新的一段从它开始且只含它自己', () {
      final events = <WorkTaskEvent>[
        _event(1),
        _event(2, kind: WorkTaskEventKind.queued, title: '开始处理已排队的追问'),
      ];

      final start = WorkTaskRunBoundary.currentRunStartIndex(events);
      expect(start, 1);
      expect(events.sublist(start), hasLength(1));
    });
  });
}

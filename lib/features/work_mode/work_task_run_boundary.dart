import 'work_task_event.dart';

/// 任务时间线上「一次新请求并入同一条记录」的分界。
///
/// 私聊里一条任务记录是一条长期血缘：追问被推广时会覆盖 `task.userRequest`，并在
/// 同一份事件日志上继续追加。于是面板标签写的是新请求、时间线却仍是这条记录从第一
/// 次运行起的全部历史——看起来像"新任务带着老任务的历史"。执行动态据此按运行段
/// 收敛：默认只显示当前这一段，更早的折叠起来由用户点开。
class WorkTaskRunBoundary {
  const WorkTaskRunBoundary._();

  /// 推广一次排队追问时写在这个事件上的标记。
  static const String metadataKey = 'runBoundary';

  /// [metadataKey] 的取值。
  static const String followUpPromotion = 'followUpPromotion';

  /// 本条约定之前落盘的日志只有标题可认。标题是展示文案，将来可能改，所以新事件
  /// 一律带 [metadataKey] 标记；这里只负责让已经写进用户磁盘的历史也能正确分段。
  static const String legacyFollowUpTitle = '开始处理已排队的追问';

  /// 这条事件是否标志着一轮新请求开始。
  static bool isRunBoundary(WorkTaskEvent event) {
    if (event.safeMetadata[metadataKey] == followUpPromotion) return true;
    return event.kind == WorkTaskEventKind.queued &&
        event.title == legacyFollowUpTitle;
  }

  /// 当前运行段的第一条事件在 [events]（按 sequence 升序）里的下标。
  ///
  /// 没有分界时返回 0（整条日志就是一段）。分界事件本身算作新一段的开头：它就是
  /// 「上一轮已经结束、开始处理新请求」的那一刻，属于新请求的故事。
  static int currentRunStartIndex(List<WorkTaskEvent> events) {
    for (var index = events.length - 1; index >= 0; index--) {
      if (isRunBoundary(events[index])) return index;
    }
    return 0;
  }
}

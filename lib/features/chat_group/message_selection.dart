import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/features/work_mode/work_mode_task_lifecycle.dart';

/// 这条消息能不能被删除。
///
/// 单条删除的入口与多选的勾选框共用这一条判据——两处各写一份时，新加的
/// "不可删"规则只会落在其中一边，多选就能绕过它把不该删的气泡删掉。
///
/// - 客人端一律不给：本地删掉的消息会被主人端的同步写回来，删了跟没删一样。
/// - 工作模式进度气泡不给：它由任务生命周期持续改写，删掉会让任务面板失去落点。
/// - 正在流式输出的那条不给：写入方还活着，删完立刻又会被写回来。
bool canDeleteRoomMessage(
  Message message, {
  required String? streamingMessageId,
  required bool isRealtimeGuest,
}) {
  if (isRealtimeGuest) return false;
  if (message.id == streamingMessageId) return false;
  return !WorkModeTaskLifecycle.isProgressMessageId(message.id);
}

/// 多选模式当前可以勾选的消息 id。
///
/// 只看传进来的这一页。页面手里是分页窗口，全选若越过
/// `_hasOlderMessages` 去把更早的消息也捞出来勾上，用户就会删掉自己从没读过的
/// 内容——"清空全部"是另一个入口，且带着完整的数量说明。
Set<String> selectableMessageIds(
  Iterable<Message> messages, {
  required String? streamingMessageId,
  required bool isRealtimeGuest,
}) =>
    {
      for (final message in messages)
        if (canDeleteRoomMessage(
          message,
          streamingMessageId: streamingMessageId,
          isRealtimeGuest: isRealtimeGuest,
        ))
          message.id,
    };

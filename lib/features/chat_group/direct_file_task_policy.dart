/// 普通聊天中的写文件任务必须经过显式批准。
///
/// 保留这个策略入口是为了让调用处清楚地区分普通私聊与已经单独授权的自治任务。
/// 自治任务由调用方传入 `autoApproveTools: true`，不会经过本策略。
bool shouldAutoApproveDirectFileTask({
  required bool isDirectChat,
  required String userMessage,
}) {
  return false;
}

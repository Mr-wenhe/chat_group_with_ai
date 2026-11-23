/// 聊天室上下文压缩的三种去向。
enum ContextCompactionDecision {
  /// 本轮要发的内容本身就放得下：不压缩，也不花额外的模型请求。
  none,

  /// 上次摘要 + 它之后的新消息仍放得下：直接复用，不再请求。
  reuseSummary,

  /// 连「摘要 + 增量」都放不下：重新压缩整段可见历史。
  resummarize,
}

/// 压缩的触发条件是**本轮要发的请求放不下**，不是某个绝对阈值：聊天室只把最近
/// 20 条放进请求，用整段已加载历史判阈值会让每条回复都先跑一次压缩请求（现场：
/// 中转上每次 16-32 秒，用户看到的就是几十秒无输出）。
///
/// [reusableTokens] 为 null 表示没有可复用的摘要（从未压缩过，或 checkpoint 已
/// 失效——那条消息被删了）；此时只能重新压缩。
ContextCompactionDecision decideContextCompaction({
  required int windowTokens,
  required int inputBudget,
  int? reusableTokens,
}) {
  if (windowTokens <= inputBudget) return ContextCompactionDecision.none;
  if (reusableTokens != null && reusableTokens <= inputBudget) {
    return ContextCompactionDecision.reuseSummary;
  }
  return ContextCompactionDecision.resummarize;
}

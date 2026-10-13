/// 群讨论一轮要推进的阶段。
///
/// 协议文本按它裁剪、聚焦提示按它生成、公开正文的协议标识清洗按它拦改名——同一份
/// 词表的三处使用。**第三处仍是字面量**：`WorkPublicUpdateStream._protocolNotation`
/// 里的 `reviewApproval|resolveIssue|prepareProposal` 没有跟着这个枚举走，新增
/// 阶段名时必须同步改那行正则，否则成员把新阶段名写进气泡就不再被拦。
enum WorkDiscussionStage {
  /// 有一个未决问题要先解决。
  resolveIssue,

  /// 方案还不完整，本轮补齐。
  prepareProposal,

  /// 方案/提案/候选已就位，本轮逐人认可。
  reviewApproval;

  /// 从提示词里的阶段名还原。
  ///
  /// 未知值直接抛错而不是回退到某个默认阶段：回退会让协议按别的阶段裁剪，而聚焦
  /// 提示说的是另一件事，成员于是拿到对不上的两句话。错误消息带上实际取值——这个
  /// 异常在讨论 runner 的 `on Object catch` 里会被收成"成员请求失败"，只有消息本身
  /// 能说明是哪个阶段名对不上。
  static WorkDiscussionStage fromName(String name) => values.firstWhere(
        (value) => value.name == name,
        orElse: () => throw ArgumentError('未知的讨论阶段名：$name'),
      );
}

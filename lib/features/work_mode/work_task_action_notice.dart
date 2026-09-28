/// 面板动作被拒后需要用户看到并处理的一条提示。
///
/// 借用异常传递是为了复用面板已有的呈现通道（详情里的「操作失败」和对话框）。
/// 它只携带瞬时信息：任务记录会被导出，本地绝对路径不能落进里面，所以持久化的
/// 失败原因仍然只有不带路径的文案。
class WorkTaskActionNotice implements Exception {
  const WorkTaskActionNotice(this.message, {this.requiredDirectory});

  /// 面板详情里显示的文案，不含本地路径。
  final String message;

  /// 需要授权的本地目录。
  ///
  /// 非空表示这是「选错了目录」这类可以当场修好的问题：面板据此弹出对话框点名
  /// 需要哪个目录。为空时只把 [message] 记进面板详情，不打断用户。
  final String? requiredDirectory;

  @override
  String toString() => message;
}

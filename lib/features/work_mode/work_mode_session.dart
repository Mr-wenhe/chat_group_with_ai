import 'package:dio/dio.dart';

/// 单次运行（run）的取消句柄。
///
/// 每次 [beginRun] 得到一个独立的句柄，持有自己的 [CancelToken] 与独立的
/// 「已请求停止」状态。旧 run 的停止/取消只影响它自己的句柄，绝不会被新 run
/// 的 [beginRun] 误复位——这正是修复「用户停止旧 run 后，新 run 把共享标志
/// 复位为 false 导致旧 run 在下一检查点复活、继续跑工具/写文件」竞态的关键。
class WorkModeRunHandle {
  final CancelToken token = CancelToken();
  bool _requestedStop = false;

  /// 本 run 是否已被请求停止（仅供 AgentRuntime 检查点读取）。
  bool get isRequestedStop => _requestedStop;

  void requestStop(String reason) {
    _requestedStop = true;
    if (!token.isCancelled) token.cancel(reason);
  }
}

/// 集中持有一个显式工作模式会话的可变运行状态。
///
/// 取消令牌和待审批对象必须有唯一所有者；否则旧异步分支结束时，可能误清理
/// 后启动任务的新状态。页面只负责事件接线，不再分别维护这些并发字段。
class WorkModeSession<TApproval> {
  bool enabled = false;
  TApproval? pendingApproval;
  WorkModeRunHandle? _activeRun;

  void setEnabled(bool value) {
    enabled = value;
    if (!value) requestStop('工作模式已关闭');
  }

  /// 开始一次新的 run：返回该 run 专属的取消句柄。
  ///
  /// 旧 run 会被标记停止（置其 `_requestedStop` 并取消其 token），避免它卡在
  /// 非网络检查点多跑一步工具；该停止只作用于旧 run 自己的句柄，但**不会**复位
  /// 任何「会被后续 run 共享」的标志——每个 run 独立持有自己的停止状态。
  WorkModeRunHandle beginRun() {
    _activeRun?.requestStop('新的工作任务已开始');
    _activeRun = WorkModeRunHandle();
    return _activeRun!;
  }

  void finishRun(WorkModeRunHandle handle) {
    if (identical(_activeRun, handle)) _activeRun = null;
  }

  void requestStop(String reason) {
    _activeRun?.requestStop(reason);
    _activeRun = null;
  }

  TApproval? takePendingApproval() {
    final value = pendingApproval;
    pendingApproval = null;
    return value;
  }
}

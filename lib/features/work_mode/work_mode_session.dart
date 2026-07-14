import 'package:dio/dio.dart';

/// 集中持有一个显式工作模式会话的可变运行状态。
///
/// 取消令牌和待审批对象必须有唯一所有者；否则旧异步分支结束时，可能误清理
/// 后启动任务的新状态。页面只负责事件接线，不再分别维护这些并发字段。
class WorkModeSession<TApproval> {
  bool enabled = false;
  bool isStopRequested = false;
  CancelToken? activeCancelToken;
  TApproval? pendingApproval;

  void setEnabled(bool value) {
    enabled = value;
    if (value) {
      isStopRequested = false;
    } else {
      requestStop('工作模式已关闭');
    }
  }

  CancelToken beginRun() {
    activeCancelToken?.cancel('新的工作任务已开始');
    isStopRequested = false;
    final token = CancelToken();
    activeCancelToken = token;
    return token;
  }

  void finishRun(CancelToken token) {
    if (identical(activeCancelToken, token)) activeCancelToken = null;
  }

  void requestStop(String reason) {
    isStopRequested = true;
    activeCancelToken?.cancel(reason);
    activeCancelToken = null;
  }

  TApproval? takePendingApproval() {
    final value = pendingApproval;
    pendingApproval = null;
    return value;
  }
}

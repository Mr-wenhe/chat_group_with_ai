import '../../agentic/context_window_manager.dart';

const networkContextOverflowMessage = '联网所需的角色设定、当前输入或来源正文放不进模型窗口，请缩小范围或更换模型。';

/// Keep the current request and real evidence intact; only optional history yields.
List<Map<String, dynamic>>? fitNetworkReplyContext(
  List<Map<String, dynamic>> messages, {
  required List<Map<String, dynamic>> requiredMessages,
  required int inputTokenBudget,
}) {
  bool matches(Map<String, dynamic> left, Map<String, dynamic> right) =>
      left['role'] == right['role'] && left['content'] == right['content'];
  final fitted = ContextWindowManager.fitToTokenBudget(
    messages,
    maxTokens: inputTokenBudget,
    isProtected: (message) =>
        requiredMessages.any((required) => matches(message, required)),
  );
  if (ContextWindowManager.estimateRequestTokens(fitted) > inputTokenBudget ||
      requiredMessages.any(
          (required) => !fitted.any((message) => matches(message, required)))) {
    return null;
  }
  return fitted;
}

/// 流式输出事件类型枚举：统一区分「增量 token」「整条完成」「异常」三种情况。
///
/// 之所以单独抽成枚举而不是用 Map/动态对象，是为了让 UI 层能通过 `switch`
/// 做穷尽匹配（编译器保证不会漏处理某种情况），同时避免页面自行解析 SSE。
enum ChatStreamEventType {
  /// 增量文本片段，携带 [ChatStreamEvent.delta]。
  token,

  /// 整条回复完成，携带 [ChatStreamEvent.content]（完整文本）与可选 [ChatStreamEvent.model]。
  done,

  /// 流式过程中出现异常（网络/超时/解析失败），携带 [ChatStreamEvent.message]。
  error,
}

/// 流式输出事件：ChatApiService 通过 Stream 只产出此类型，UI 层据此增量渲染或报错，
/// 从而把「SSE 解析细节」完全封装在底层，页面不得自行解析 SSE。
///
/// 这是贯穿「流式输出」功能的统一事件契约（见架构文档「共享约定」）。
class ChatStreamEvent {
  /// 事件类型。
  final ChatStreamEventType type;

  /// type == token 时有效：本次增量文本。
  final String? delta;

  /// type == done 时有效：整条完整文本。
  final String? content;

  /// type == done 时可选：实际使用的模型名（用于展示）。
  final String? model;

  /// type == error 时有效：人类可读的错误信息。
  final String? message;

  const ChatStreamEvent({
    required this.type,
    this.delta,
    this.content,
    this.model,
    this.message,
  });

  /// 便捷工厂：构造一个 token 事件，[delta] 为本次增量文本。
  factory ChatStreamEvent.token(String delta) =>
      ChatStreamEvent(type: ChatStreamEventType.token, delta: delta);

  /// 便捷工厂：构造一个 done 事件，[content] 为完整文本，[model] 可选。
  factory ChatStreamEvent.done(String content, [String? model]) =>
      ChatStreamEvent(
          type: ChatStreamEventType.done, content: content, model: model);

  /// 便捷工厂：构造一个 error 事件，[message] 为人类可读的错误描述。
  factory ChatStreamEvent.error(String message) =>
      ChatStreamEvent(type: ChatStreamEventType.error, message: message);

  @override
  String toString() =>
      'ChatStreamEvent(type: $type, delta: $delta, content: $content, model: $model, message: $message)';
}

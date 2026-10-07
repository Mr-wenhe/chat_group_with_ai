/// 客户端自己的模型时限掐断了一次请求。
///
/// 单独一个类型、而不是裸 `TimeoutException`：归因必须在**分类之前**带上。
/// [sanitizeWorkTaskError] 会把首字节停滞与总时限一起折叠成「任务执行超时」，
/// 之后 `WorkFailure._typeFor` 只会按「超时」给出笼统的 `retryableNetwork`——
/// 与上游 5xx 同码。码随异常传递，才能一路走到工作模式事件的元数据。
class WorkModelDeadlineException implements Exception {
  const WorkModelDeadlineException._(this.code, this.message);

  /// 一个字符都还没收到就放弃了这次尝试。
  ///
  /// 与总时限分开措辞，是为了让事件、日志与归因能区分「上游一个字符都没吐」和
  /// 「这次请求整体太慢」——两者的处置完全不同：零输出意味着不存在任何已生成
  /// 内容，提前放弃并重试不会丢掉工作，而总时限必须容下"生成很慢但正在输出"的
  /// 请求，缩短它就是砍掉正常的那一类。用户看到的失败文案仍会被
  /// `WorkTaskErrorSanitizer` 统一折叠成「任务执行超时」。
  static const WorkModelDeadlineException firstByteStall =
      WorkModelDeadlineException._(
    'modelFirstByteStall',
    '工作模式模型请求首字节超时。',
  );

  /// 整轮请求到了总时限。
  static const WorkModelDeadlineException completionDeadline =
      WorkModelDeadlineException._(
    'modelCompletionTimeout',
    '工作模式模型请求超时。',
  );

  /// 落进模型响应体与事件元数据的稳定分类码。
  final String code;

  final String message;

  /// 归一化后的码是否属于本类时限。
  ///
  /// `WorkFailure._typeFor` 收到的 code 已经统一转成小写，比对放在这里而不是
  /// 各写一份字面量，避免两处漂移后停滞被当成未知码。
  static bool matches(String normalizedCode) =>
      normalizedCode == firstByteStall.code.toLowerCase() ||
      normalizedCode == completionDeadline.code.toLowerCase();

  @override
  String toString() => message;
}

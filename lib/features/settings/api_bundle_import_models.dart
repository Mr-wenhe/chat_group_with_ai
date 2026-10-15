/// 授权码导入的预览与结果模型。
///
/// 刻意与执行逻辑分开：预览是**纯读**的（不碰安全存储、不写任何 box），执行是
/// 唯一有副作用的地方。分开之后，测试可以先断言「预览说要做哪些改动」，再断言
/// 「执行确实只做了那些改动」。
library;

/// 配置包里的四类服务。
enum BundleService {
  chat('聊天', 'AI 角色的对话模型'),
  voice('语音', '火山引擎 TTS / ASR'),
  image('图像', 'IP 形象文生图'),
  search('搜索', '联网检索提供方');

  const BundleService(this.label, this.description);

  final String label;
  final String description;
}

/// 预览里每一行要做的事。
enum BundleChangeAction {
  /// 新增一条配置。
  create('新增'),

  /// 覆盖既有配置（保留原 id，指向它的角色/任务不会断）。
  overwrite('覆盖'),

  /// 不动。既包括「包里的条目与现有配置一致」，也包括「条目自身不合法」——
  /// 后者必须带 [BundleChange.detail] 说明原因，否则用户只会看到一条沉默的跳过。
  skip('跳过');

  const BundleChangeAction(this.label);

  final String label;
}

/// 预览里的一行。
class BundleChange {
  const BundleChange({
    required this.service,
    required this.action,
    required this.title,
    this.detail = '',
    this.keyFingerprint = '',
  });

  final BundleService service;
  final BundleChangeAction action;

  /// 展示用标题，如「DeepSeek 主力」。
  final String title;

  /// 覆盖时说明改了什么；跳过时说明为什么跳过。
  final String detail;

  /// 密钥指纹（`sha256(apiKey)` 的前 8 位十六进制）。
  ///
  /// 预览里**绝不出现密钥的任何字符**（哪怕打码的尾部也不行——打码尾部仍泄露
  /// 长度与结尾字符）。指纹让用户能拿生成工具打印的同一指纹三方对照，
  /// 确认「包里的确实是这把钥匙」，同时零泄露。
  final String keyFingerprint;

  /// 在预览页里是否可以被用户取消勾选。
  bool get selectable => action != BundleChangeAction.skip;
}

/// 一次导入的预览。
class BundleImportPlan {
  const BundleImportPlan({required this.label, required this.changes});

  final String label;
  final List<BundleChange> changes;

  int get createCount => _count(BundleChangeAction.create);
  int get overwriteCount => _count(BundleChangeAction.overwrite);
  int get skipCount => _count(BundleChangeAction.skip);

  /// 有实际写入动作的行。
  List<BundleChange> get applicable =>
      changes.where((change) => change.selectable).toList(growable: false);

  bool get hasWork => applicable.isNotEmpty;

  int _count(BundleChangeAction action) =>
      changes.where((change) => change.action == action).length;
}

/// 单条动作的执行结果。
class BundleImportOutcome {
  const BundleImportOutcome({
    required this.service,
    required this.title,
    required this.succeeded,
    this.reason = '',
  });

  final BundleService service;
  final String title;
  final bool succeeded;

  /// 失败原因（可直接展示的中文），成功时为空串。
  final String reason;
}

/// 一次导入的执行结果。
class BundleImportResult {
  const BundleImportResult(this.outcomes);

  final List<BundleImportOutcome> outcomes;

  int get successCount => outcomes.where((o) => o.succeeded).length;
  int get failureCount => outcomes.where((o) => !o.succeeded).length;
  bool get hasFailure => failureCount > 0;
}

/// 导入被整体拒绝（一个字节都没写）。
///
/// 与「逐条失败」严格区分：整体拒绝意味着**环境根本不具备写入凭据的能力**
/// （Web、钥匙串不可用），此时做任何写入都只会留下半配置状态。
class BundleImportRejected implements Exception {
  const BundleImportRejected(this.message);

  final String message;

  @override
  String toString() => 'BundleImportRejected: $message';
}

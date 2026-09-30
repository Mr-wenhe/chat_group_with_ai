import 'dart:convert';

import 'work_context_builder.dart';

/// 工作模式提示词的上下文收缩器。
///
/// 触发判据与预算由调用方给出（`ContextWindowManager.workPromptCompactionBudget`），
/// 这里只负责"怎么缩"。收缩按价值从低到高分阶段进行，每一阶段都作用于结构化的
/// context map，最后才 `jsonEncode`——所以**输出永远是合法 JSON**。这一点是它存在
/// 的理由：被它取代的兜底路径 `ContextWindowManager.fitToTokenBudget` 在装不下时会对
/// 最长的那条消息从中间插入裁剪标记，而工作模式里最长的那条恰好是整段检查点 JSON
/// （`公开任务检查点：{...}`），等于把 JSON 剪成两半发给模型。
///
/// 下列字段是执行状态而不是模型散文，任何阶段都不参与收缩：[goal]、[plan]、
/// [resultSummary]、[lastError]、[previousToolFailure]、[previousCompletionFailure]、
/// [workFailure]、[actionCount]、[actionLimit]、[pendingToolRequest]。检查点里的
/// `target` / `pendingFollowUps` / `approvalScope` / `artifactPaths` 同理——收缩检查点时
/// 走 [WorkContextBuilder] 自己的既有策略，它最后才动这些字段。
class WorkPromptContextCompactor {
  const WorkPromptContextCompactor();

  /// 收缩后的检查点字符预算。原值是 12000，这里收紧是因为它已经挤占了提示词里
  /// 唯一那条 system 检查点消息的大部分；诊断信息丢了可以从产物与公开时间线重建，
  /// 而提示词超预算是会直接让任务卡在慢请求上的。
  static const int _checkpointCharacters = 2048;

  /// 工具结果的嵌套深度上限，与持久化边界的脱敏深度保持一致。
  static const int _maxResultDepth = 8;

  static const String _imageDataUriPrefix = 'data:image/';

  /// 按 [budgetTokens] 收缩 [context]。
  ///
  /// [measureTokens] 估算"这份上下文装进真实提示词后有多大"，由调用方提供，
  /// 因为只有它知道消息是怎么拼装的。
  ///
  /// 未超预算时**原样返回**（逐字一致，不做多余的编码）。预算为 0 或负数表示调用方
  /// 没有配出可用预算（例如窗口小到输入预算为 0），此时同样原样返回，交给既有的
  /// `fitToTokenBudget` 兜底。所有阶段走完仍超预算时返回收缩到最深的一版：输入预算
  /// 始终是模型窗口的硬上限，由调用方在拼接后继续兜底。
  Map<String, dynamic> compactIfNeeded(
    Map<String, dynamic> context, {
    required int budgetTokens,
    required int Function(Map<String, dynamic> candidate) measureTokens,
  }) {
    if (budgetTokens <= 0 || measureTokens(context) <= budgetTokens) {
      return context;
    }
    var current = context;
    for (final stage in _stages) {
      final next = stage(current);
      if (identical(next, current)) continue;
      current = next;
      if (measureTokens(current) <= budgetTokens) break;
    }
    return current;
  }

  /// 收缩阶段，按价值从低到高排列。顺序本身就是策略，不要按"哪步删得多"重排。
  static final List<Map<String, dynamic> Function(Map<String, dynamic>)>
      _stages = <Map<String, dynamic> Function(Map<String, dynamic>)>[
    // 公开进度是模型自己写过的叙述，检查点的 completedSummaries 已经留了一份，
    // 对下一步决策的信息量最低。
    (context) => _trimList(context, 'publicUpdates', 0),
    (context) => _trimList(context, 'committedWrites', 32),
    (context) => _trimList(context, 'completedActions', 8),
    // 先减条数，再减单条正文，最后才动检查点与产物清单。
    (context) => _trimList(context, 'recentToolResults', 4),
    (context) => _trimList(context, 'conversationHistory', 8),
    (context) => _trimList(context, 'recentToolResults', 2),
    (context) => _trimList(context, 'conversationHistory', 2),
    (context) => _clipToolResultTexts(context, 4000),
    _shrinkCheckpointSummary,
    (context) => _clipToolResultTexts(context, 1000),
    (context) => _trimList(context, 'artifacts', 8),
  ];

  static Map<String, dynamic> _trimList(
    Map<String, dynamic> context,
    String key,
    int keep,
  ) {
    final value = context[key];
    if (value is! List || value.length <= keep) return context;
    return <String, dynamic>{
      ...context,
      key: value.sublist(value.length - keep),
    };
  }

  /// 裁剪工具结果里的长字符串正文。
  ///
  /// 按"任意长字符串"处理而不是逐个 key 枚举：文件读取走 `data.content`，命令输出
  /// 走 `data.stdout`，将来还会有别的 key——漏掉一个，那段上下文就永远不进收缩
  /// 范围，而它往往正是提示词里最大的一块。
  ///
  /// 两个例外必须原样保留：多模态 `content` 是 content-part 列表（不是字符串，
  /// 天然跳过），以及其中的图片数据 URI——按字符截断会把图片降级成文本，同时绕过
  /// 网关的视觉能力校验。
  static Map<String, dynamic> _clipToolResultTexts(
    Map<String, dynamic> context,
    int limit,
  ) {
    final results = context['recentToolResults'];
    if (results is! List) return context;
    var changed = false;
    final rebuilt = results.map<Object?>((entry) {
      if (entry is! Map) return entry;
      final clipped = _clipResultValue(entry, limit, 0);
      if (identical(clipped, entry)) return entry;
      changed = true;
      return clipped;
    }).toList(growable: false);
    if (!changed) return context;
    return <String, dynamic>{...context, 'recentToolResults': rebuilt};
  }

  /// 递归裁剪；没有实际改动时返回原对象，让调用方能用 [identical] 判断是否需要
  /// 重新度量——这决定了收缩是否会在每一步都白算一次提示词大小。
  static Object? _clipResultValue(Object? value, int limit, int depth) {
    if (value is String) {
      if (value.length <= limit || value.startsWith(_imageDataUriPrefix)) {
        return value;
      }
      return _clipText(value, limit);
    }
    if (depth > _maxResultDepth) return value;
    if (value is List) {
      var changed = false;
      final output = value.map<Object?>((item) {
        final clipped = _clipResultValue(item, limit, depth + 1);
        if (!identical(clipped, item)) changed = true;
        return clipped;
      }).toList(growable: false);
      return changed ? output : value;
    }
    if (value is Map) {
      var changed = false;
      final output = <String, Object?>{};
      for (final entry in value.entries) {
        final key = entry.key;
        // 图片载荷挂在 url 上，它的长度不反映 token 数。
        final clipped = key == 'url'
            ? entry.value
            : _clipResultValue(entry.value, limit, depth + 1);
        if (!identical(clipped, entry.value)) changed = true;
        output[key is String ? key : '$key'] = clipped;
      }
      return changed ? output : value;
    }
    return value;
  }

  /// 复用 [WorkContextBuilder] 既有的检查点收缩策略，只把字符预算调小。
  ///
  /// 不另写一套裁剪规则：那套策略的丢弃顺序（先诊断、最后才动 target / 队列 /
  /// 审批范围 / 产物路径）是重启与重试的恢复前提，重写一遍只会分叉。
  static Map<String, dynamic> _shrinkCheckpointSummary(
    Map<String, dynamic> context,
  ) {
    final raw = context['checkpointSummary'];
    if (raw is! String || raw.trim().isEmpty) return context;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return context;
      final snapshot = WorkContextSnapshot.fromJson(
        Map<String, dynamic>.from(decoded),
      );
      final encoded = const WorkContextBuilder(
        maxCharacters: _checkpointCharacters,
      ).clipToBudget(snapshot).toJsonString();
      if (encoded.length >= raw.length) return context;
      return <String, dynamic>{...context, 'checkpointSummary': encoded};
    } on Object {
      // 读不懂的检查点保持原样：它由任务的持久化状态负责修正，收缩器没有资格
      // 因为看不懂就把执行状态删掉。
      return context;
    }
  }

  static String _clipText(String text, int limit) {
    const marker = '\n…【上下文已按模型窗口收缩】…\n';
    if (text.length <= limit) return text;
    if (limit <= marker.length + 2) return text.substring(0, limit);
    final available = limit - marker.length;
    final head = (available / 2).ceil();
    return '${text.substring(0, head)}$marker'
        '${text.substring(text.length - (available - head))}';
  }
}

import 'package:chat_group/core/streaming/reported_token_usage.dart';
import 'package:chat_group/features/ai_governance/ai_governance_models.dart';

/// 一个字段的实报合计；请求数让“真实零值”和“未返回”保持可区分。
class ReportedTokenTotal {
  int tokens = 0;
  int requests = 0;

  void add(int? value) {
    if (value == null) return;
    tokens += value;
    requests++;
  }

  String get label => requests == 0 ? '未知' : '$tokens';
}

/// 只使用当前 taskId 的上游实报，预算估算与历史口径不混入合计。
class WorkTaskUsageSummary {
  final input = ReportedTokenTotal();
  final output = ReportedTokenTotal();
  final cached = ReportedTokenTotal();
  final cacheWrite = ReportedTokenTotal();
  final reasoning = ReportedTokenTotal();
  final uncached = ReportedTokenTotal();
  int requests = 0;
  int completeRequests = 0;
  int estimatedRequests = 0;
  int legacyRequests = 0;
  int invalidRequests = 0;
  int cacheRateRequests = 0;
  int _cacheRateInput = 0;
  int _cacheRateRead = 0;

  WorkTaskUsageSummary.forTask(
    String taskId,
    Iterable<UsageLedgerEntry> entries,
    Iterable<AiRequestDiagnostic> diagnostics,
  ) {
    final seen = <String>{};
    for (final entry in entries.where((e) => e.taskId == taskId)) {
      if (entry.requestId.isNotEmpty && !seen.add(entry.requestId)) continue;
      if (!entry.exactUsage && entry.status == 'success') estimatedRequests++;
      _add(entry.reportedUsage);
    }
    for (final entry in diagnostics.where((e) => e.taskId == taskId)) {
      if (entry.status == 'blocked') continue; // 请求未发出，不算未知消耗。
      if (entry.requestId.isNotEmpty && !seen.add(entry.requestId)) continue;
      _add(entry.reportedUsage);
    }
  }

  int get unknownRequests =>
      requests - completeRequests - legacyRequests - invalidRequests;
  bool get incomplete => completeRequests != requests;
  String get cacheHitRate => _cacheRateInput == 0
      ? '—'
      : '${(_cacheRateRead * 100 / _cacheRateInput).toStringAsFixed(1)}%';

  void _add(ReportedTokenUsage? usage) {
    requests++;
    if (usage == null) {
      legacyRequests++;
      return;
    }
    if (!usage.valid) {
      invalidRequests++;
      return;
    }
    if (usage.complete) completeRequests++;
    input.add(usage.inputTokens);
    output.add(usage.outputTokens);
    cached.add(usage.cachedTokens);
    cacheWrite.add(usage.cacheWriteTokens);
    reasoning.add(usage.reasoningTokens);
    uncached.add(usage.uncachedInputTokens);
    if (usage.inputTokens != null && usage.cachedTokens != null) {
      cacheRateRequests++;
      _cacheRateInput += usage.inputTokens!;
      _cacheRateRead += usage.cachedTokens!;
    }
  }
}

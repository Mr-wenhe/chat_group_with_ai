import '../models/api_protocol.dart';

/// 上游实报的请求累计值；null 表示未返回，绝不由文本长度补造。
class ReportedTokenUsage {
  final int? inputTokens;
  final int? outputTokens;
  final int? cachedTokens;
  final int? cacheWriteTokens;
  final int? reasoningTokens;
  final int? uncachedInputTokens;

  const ReportedTokenUsage({
    this.inputTokens,
    this.outputTokens,
    this.cachedTokens,
    this.cacheWriteTokens,
    this.reasoningTokens,
    this.uncachedInputTokens,
  });

  bool get hasValues => toMap().values.any((value) => value != null);
  bool get complete => inputTokens != null && outputTokens != null;
  bool get valid =>
      toMap().values.every((value) => value == null || value >= 0) &&
      (inputTokens == null ||
          (cachedTokens ?? 0) + (cacheWriteTokens ?? 0) <= inputTokens!) &&
      (outputTokens == null || (reasoningTokens ?? 0) <= outputTokens!);

  /// SSE usage 是累计快照；缺少字段不覆盖已经收到的实报值。
  ReportedTokenUsage merge(ReportedTokenUsage next) => ReportedTokenUsage(
        inputTokens: next.inputTokens ?? inputTokens,
        outputTokens: next.outputTokens ?? outputTokens,
        cachedTokens: next.cachedTokens ?? cachedTokens,
        cacheWriteTokens: next.cacheWriteTokens ?? cacheWriteTokens,
        reasoningTokens: next.reasoningTokens ?? reasoningTokens,
        uncachedInputTokens: next.uncachedInputTokens ?? uncachedInputTokens,
      );

  factory ReportedTokenUsage.fromMap(Map map) => ReportedTokenUsage(
        inputTokens: _read(map['promptTokens']),
        outputTokens: _read(map['completionTokens']),
        cachedTokens: _read(map['cachedTokens']),
        cacheWriteTokens: _read(map['cacheWriteTokens']),
        reasoningTokens: _read(map['reasoningTokens']),
        uncachedInputTokens: _read(map['uncachedInputTokens']),
      );

  factory ReportedTokenUsage.fromWire(Map usage, ApiProtocol protocol) {
    int? read(Object? value) => _read(value);
    Map detail(String name) =>
        usage[name] is Map ? usage[name] as Map : const {};
    final inputDetails = detail('input_tokens_details');
    final promptDetails = detail('prompt_tokens_details');
    if (protocol == ApiProtocol.anthropicMessages) {
      return _anthropicUsage(usage);
    }
    if (protocol == ApiProtocol.geminiGenerateContent) {
      return _geminiUsage(usage);
    }
    return ReportedTokenUsage(
      inputTokens: read(usage['input_tokens'] ?? usage['prompt_tokens']),
      outputTokens: read(usage['output_tokens'] ?? usage['completion_tokens']),
      // Aliases describe the same tokens, so never add them together.
      cachedTokens: read(inputDetails['cached_tokens'] ??
          promptDetails['cached_tokens'] ??
          inputDetails['cache_read'] ??
          usage['cached_tokens'] ??
          usage['prompt_cache_hit_tokens'] ??
          usage['cache_read_input_tokens']),
      cacheWriteTokens: read(inputDetails['cache_write_tokens'] ??
          promptDetails['cache_write_tokens'] ??
          usage['cache_creation_input_tokens']),
      reasoningTokens: read(
          detail('output_tokens_details')['reasoning_tokens'] ??
              detail('completion_tokens_details')['reasoning_tokens']),
    );
  }

  static ReportedTokenUsage _anthropicUsage(Map usage) {
    final input = _read(usage['input_tokens']);
    final cached = _read(usage['cache_read_input_tokens']);
    final written = _read(usage['cache_creation_input_tokens']);
    return ReportedTokenUsage(
      inputTokens: input == null || cached == null || written == null
          ? null
          : input + cached + written,
      uncachedInputTokens: input,
      outputTokens: _read(usage['output_tokens']),
      cachedTokens: cached,
      cacheWriteTokens: written,
    );
  }

  static ReportedTokenUsage _geminiUsage(Map usage) {
    final prompt = _read(usage['promptTokenCount']);
    final tool = _read(usage['toolUsePromptTokenCount']);
    final input = prompt == null ? null : prompt + (tool ?? 0);
    final total = _read(usage['totalTokenCount']);
    final candidates = _read(usage['candidatesTokenCount']);
    final thoughts = _read(usage['thoughtsTokenCount']);
    return ReportedTokenUsage(
      inputTokens: input,
      outputTokens: total != null && input != null
          ? total - input
          : candidates == null
              ? null
              : candidates + (thoughts ?? 0),
      cachedTokens: _read(usage['cachedContentTokenCount']),
      reasoningTokens: thoughts,
    );
  }

  Map<String, int?> toMap() => {
        'promptTokens': inputTokens,
        'completionTokens': outputTokens,
        'cachedTokens': cachedTokens,
        'cacheWriteTokens': cacheWriteTokens,
        'reasoningTokens': reasoningTokens,
        'uncachedInputTokens': uncachedInputTokens,
      };

  static int? _read(Object? value) =>
      value is num && value.isFinite && value == value.roundToDouble()
          ? value.toInt()
          : null;
}

import 'package:chat_group/features/ai_governance/ai_governance_models.dart';

/// 一条请求诊断在设置页里的摘要文本。
///
/// 失败记录会多出一行归因（异常类型与脱敏后的正文摘要）——`failureType` 只到
/// 「provider_error」这一层，一次上游丢包、一次响应体不是 JSON、一次证书被拒
/// 在它看来完全一样，排查时必须能直接读到这个字段。
String diagnosticSummaryText(AiRequestDiagnostic item) => [
      '${item.provider}/${item.model} · ${item.latencyMs}ms · '
          '重试 ${item.retryCount}',
      if (item.failureDetail != null) '失败原因：${item.failureDetail}',
    ].join('\n');

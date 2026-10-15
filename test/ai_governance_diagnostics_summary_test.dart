import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/settings/ai_governance_diagnostics_text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('诊断摘要带出失败原因，便于直接看出这次为什么失败', () {
    final text = diagnosticSummaryText(
      _diagnostic(
        status: 'failed',
        failureType: 'provider_error',
        failureDetail: 'DioException/unknown | FormatException: 响应不是 JSON',
      ),
    );

    expect(text, contains('DioException/unknown'));
    expect(text, contains('响应不是 JSON'));
  });

  test('成功记录不出现失败原因行', () {
    final text = diagnosticSummaryText(
      _diagnostic(status: 'success', failureType: null, failureDetail: null),
    );

    expect(text, isNot(contains('失败原因')));
  });
}

AiRequestDiagnostic _diagnostic({
  required String status,
  required String? failureType,
  required String? failureDetail,
}) =>
    AiRequestDiagnostic(
      requestId: 'req-1',
      rootRequestId: 'req-1',
      timestamp: DateTime.utc(2026, 10, 15, 12, 9),
      purpose: AiRequestPurpose.connectionTest,
      provider: 'custom',
      model: 'deepseek-flash',
      latencyMs: 206,
      retryCount: 0,
      inputTokens: null,
      cachedInputTokens: null,
      outputTokens: null,
      estimatedCostMicros: null,
      currency: null,
      status: status,
      failureType: failureType,
      failureDetail: failureDetail,
    );

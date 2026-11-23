part of 'desktop_web_service.dart';

/// 联网工具的安全失败：只暴露稳定的错误码与状态码，绝不带供应商正文。
class DesktopWebToolFailure implements Exception {
  const DesktopWebToolFailure({
    required this.code,
    this.sourceStatus,
    this.retryable = false,
  });

  factory DesktopWebToolFailure.fromFrame(Map<String, dynamic> frame) {
    final rawCode = frame['code'];
    final rawStatus = frame['sourceStatus'];
    return DesktopWebToolFailure(
      code: rawCode is String && RegExp(r'^[A-Z_]{1,64}$').hasMatch(rawCode)
          ? rawCode
          : 'REQUEST_FAILED',
      sourceStatus: rawStatus is int && rawStatus >= 100 && rawStatus <= 599
          ? rawStatus
          : null,
      retryable: frame['retryable'] == true,
    );
  }

  final String code;
  final int? sourceStatus;
  final bool retryable;

  String get safeCode =>
      RegExp(r'^[A-Z_]{1,64}$').hasMatch(code) ? code : 'REQUEST_FAILED';

  int? get safeSourceStatus =>
      sourceStatus != null && sourceStatus! >= 100 && sourceStatus! <= 599
          ? sourceStatus
          : null;

  String get safeMessage {
    if (safeCode == 'CONTENT_TYPE_MISMATCH') {
      return '下载返回的是网页 HTML，不能按原文件名保存；请选取原文件来源。';
    }
    final statusText =
        safeSourceStatus == null ? 'HTTP 状态码未知' : 'HTTP $safeSourceStatus';
    return '公开来源请求失败，未取得内容；$statusText。'
        '${retryable ? '可以重试或改用其他已登记来源。' : '请尝试其他已登记来源。'}';
  }

  Map<String, dynamic> toSafeMap() => {
        'code': safeCode,
        'retryable': retryable,
        if (safeSourceStatus != null) 'sourceStatus': safeSourceStatus,
      };

  @override
  String toString() => safeMessage;
}

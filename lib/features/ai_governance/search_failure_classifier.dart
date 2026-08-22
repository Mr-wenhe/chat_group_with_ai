import 'package:dio/dio.dart';

import 'package:chat_group/core/search/search_failure_type.dart';

/// Classifies a Dio failure without retaining the exception or its payload.
///
/// HTTP status is checked first because Dio can surface a response-bearing
/// failure with a transport-oriented type. The function is intentionally pure
/// so all callers produce the same audit and UI category.
SearchFailureType searchFailureTypeFromDioException(DioException error) {
  final statusCode = error.response?.statusCode;
  if (statusCode != null) {
    if (statusCode == 401) return SearchFailureType.unauthorized;
    if (statusCode == 403) return SearchFailureType.forbidden;
    if (statusCode == 402) return SearchFailureType.quotaExceeded;
    if (statusCode == 429) return SearchFailureType.rateLimited;
    if (statusCode == 408) return SearchFailureType.connectionTimeout;
    if (statusCode >= 500 && statusCode <= 599) {
      return SearchFailureType.providerUnavailable;
    }
    if (statusCode >= 400 && statusCode <= 499) {
      if (_looksLikeConfigurationFailure(error)) {
        return SearchFailureType.invalidConfiguration;
      }
      return SearchFailureType.invalidResponse;
    }
  }

  if (_looksLikeConfigurationFailure(error)) {
    return SearchFailureType.invalidConfiguration;
  }

  final underlyingError = error.error;
  final underlyingType = underlyingError?.runtimeType.toString() ?? '';
  if (underlyingType == 'HandshakeException') {
    return SearchFailureType.tls;
  }

  final errorText = [error.message, underlyingError?.toString()]
      .whereType<String>()
      .join(' ')
      .toLowerCase();
  if (_looksLikePermissionFailure(errorText)) {
    return SearchFailureType.permissionMissing;
  }
  if (_looksLikeDnsFailure(errorText)) return SearchFailureType.dns;
  if (_looksLikeOfflineFailure(errorText)) return SearchFailureType.offline;

  return switch (error.type) {
    DioExceptionType.connectionTimeout ||
    DioExceptionType.sendTimeout ||
    DioExceptionType.transformTimeout =>
      SearchFailureType.connectionTimeout,
    DioExceptionType.receiveTimeout => SearchFailureType.receiveTimeout,
    DioExceptionType.connectionError => SearchFailureType.connection,
    DioExceptionType.badCertificate => SearchFailureType.tls,
    DioExceptionType.cancel => SearchFailureType.cancelled,
    DioExceptionType.badResponse => SearchFailureType.invalidResponse,
    DioExceptionType.unknown => SearchFailureType.unknown,
  };
}

/// Returns a user-facing diagnostic that contains no transport detail.
String safeMessageForSearchFailure(SearchFailureType type) => switch (type) {
      SearchFailureType.offline => '设备当前似乎处于离线状态',
      SearchFailureType.connection => '无法连接搜索服务，请检查网络连接',
      SearchFailureType.permissionMissing => '应用缺少联网权限',
      SearchFailureType.dns => '无法解析搜索服务地址',
      SearchFailureType.tls => '搜索服务的安全连接验证失败',
      SearchFailureType.connectionTimeout => '连接搜索服务超时',
      SearchFailureType.receiveTimeout => '等待搜索服务响应超时',
      SearchFailureType.cancelled => '搜索请求已取消',
      SearchFailureType.unauthorized => '搜索服务拒绝了凭据，请检查配置',
      SearchFailureType.forbidden => '搜索服务拒绝了当前请求',
      SearchFailureType.quotaExceeded => '搜索服务配额已用尽',
      SearchFailureType.rateLimited => '搜索服务请求过于频繁，请稍后重试',
      SearchFailureType.providerUnavailable => '搜索服务暂时不可用，请稍后重试',
      SearchFailureType.invalidResponse => '搜索服务返回了无法识别的结果格式',
      SearchFailureType.invalidConfiguration => '搜索服务配置无效',
      SearchFailureType.unsafeQuery => '搜索内容未通过安全检查',
      SearchFailureType.noResults => '搜索服务没有返回可用结果',
      SearchFailureType.unknown => '联网搜索暂时失败，请稍后重试',
    };

bool _looksLikeConfigurationFailure(DioException error) {
  if (error.error is ArgumentError || error.error is StateError) return true;
  final text = [
    error.message,
    error.error?.toString(),
    error.response?.data?.toString(),
  ].whereType<String>().join(' ').toLowerCase();
  return RegExp(
    r'(invalid|missing|malformed|unsupported|empty).{0,32}'
    r'(config|configuration|baseurl|base url|endpoint|credential|api[-_ ]?key)',
  ).hasMatch(text);
}

bool _looksLikeDnsFailure(String text) =>
    text.contains('failed host lookup') ||
    text.contains('name or service not known') ||
    text.contains('nodename nor servname') ||
    text.contains('temporary failure in name resolution') ||
    text.contains('no address associated') ||
    text.contains('unknown host') ||
    text.contains('getaddrinfo') ||
    text.contains('dns lookup');

bool _looksLikeOfflineFailure(String text) =>
    text.contains('network is unreachable') ||
    text.contains('network is down') ||
    text.contains('no route to host') ||
    text.contains('not connected') ||
    text.contains('offline');

bool _looksLikePermissionFailure(String text) =>
    text.contains('permission denied') ||
    text.contains('operation not permitted') ||
    text.contains('network permission') ||
    text.contains('cleartext http traffic not permitted');

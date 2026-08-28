import 'package:chat_group/features/web_search/security/search_secret_scanner.dart';

/// Converts an arbitrary runner failure into text safe for task persistence.
///
/// Runner failures can contain HTTP bodies, command output, local paths or
/// credentials. The task record is durable and may be exported, so it must not
/// become a second raw-error log.
String sanitizeWorkTaskError(Object? error) {
  final raw = error?.toString().trim() ?? '';
  if (raw.isEmpty) return '任务执行失败';

  final lower = raw.toLowerCase();
  if (lower.contains('timeout') || raw.contains('超时')) return '任务执行超时';
  if (lower.contains('permission') || raw.contains('权限')) {
    return '任务权限不足';
  }
  if (lower.contains('connection') ||
      lower.contains('socket') ||
      raw.contains('网络')) {
    return '任务网络连接失败';
  }
  final status = RegExp(r'\bHTTP\s+(\d{3})\b', caseSensitive: false)
      .firstMatch(raw)
      ?.group(1);
  if (status != null) return '任务请求失败（HTTP $status）';

  var safe = const SearchSecretScanner().redact(
    raw,
    includeOpaqueTokens: true,
  );
  safe = safe.replaceAll(
    RegExp(r'https?://[^\s,;）)]+', caseSensitive: false),
    '[外部地址]',
  );
  safe = safe.replaceAll(
    RegExp(
      r'(?:(?:[A-Za-z]:[\\/])|/(?:Users|home|Volumes|private|tmp)/)[^\s,;）)]*',
    ),
    '[本地路径]',
  );
  safe = safe.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (safe.isEmpty) return '任务执行失败';
  const maximum = 600;
  return safe.length <= maximum ? safe : '${safe.substring(0, maximum - 1)}…';
}

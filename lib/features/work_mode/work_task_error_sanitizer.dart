import 'package:chat_group/features/web_search/security/search_secret_scanner.dart';

/// `Bad state: ` 这类前缀来自 Dart 对异常对象的字符串化，不是给用户看的文案。
///
/// 这里的返回值会直接拼在调用方自己的标签后面（「操作失败：…」），带着前缀
/// 出现时读起来像内部错误，而作者写的恰恰是给用户看的一句话。
final RegExp _dartExceptionPrefix = RegExp(
  r'^(?:Bad state|Exception|StateError|FormatException|ArgumentError|'
  r'UnsupportedError|TimeoutException):\s*',
);

/// Converts an arbitrary runner failure into text safe for task persistence.
///
/// Runner failures can contain HTTP bodies, command output, local paths or
/// credentials. The task record is durable and may be exported, so it must not
/// become a second raw-error log.
String sanitizeWorkTaskError(Object? error) {
  final raw = error?.toString().trim() ?? '';
  if (raw.isEmpty) return '任务执行失败';

  // 分类一律看完整字符串：`TimeoutException: Future not completed` 的正文里
  // 并没有「超时」二字，信号只在类型名上，先剥前缀会让超时被判成普通失败。
  // 前缀只在最终展示文案里剥掉。
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

  var safe = redactSensitiveText(raw);
  if (safe.isEmpty) return '任务执行失败';
  return safe;
}

/// 把任意文本压成一行可以进用户文案的内容。
///
/// 剥掉 Dart 异常前缀，遮掉密钥、外部地址与本地路径，折叠空白并截断。凡是
/// 要落进任务记录或聊天记录的自由文本都必须先过这里——这些记录是持久化的、
/// 会被导出的，不能变成第二份原始错误日志。
///
/// 返回值可能为空（原文只有前缀或空白），是否给兜底文案由调用方决定。
String redactSensitiveText(Object? value, {int maximum = 600}) {
  var safe =
      (value?.toString() ?? '').replaceFirst(_dartExceptionPrefix, '').trim();
  if (safe.isEmpty) return '';
  safe = const SearchSecretScanner().redact(
    safe,
    includeOpaqueTokens: true,
  );
  safe = safe.replaceAll(
    RegExp(r'https?://[^\s,;）)]+', caseSensitive: false),
    '[外部地址]',
  );
  safe = safe.replaceAll(
    RegExp(
      r'(?:(?:[A-Za-z]:[\\/])|(?:\\\\|//)|/(?:Users|home|Volumes|private|tmp|var|etc|usr|opt|bin|sbin|Applications|System|Library|Desktop|Documents|Downloads)/)[^\s,;）)]*',
    ),
    '[本地路径]',
  );
  safe = safe.replaceAll(RegExp(r'\s+'), ' ').trim();
  // maximum <= 0 时 substring 的下标会越界。目前没有调用方会传这么小，
  // 但这是一个纯函数边界，按"截断到 0 个字符"处理而不是抛 RangeError。
  if (maximum <= 0) return '';
  if (safe.length <= maximum) return safe;
  return '${safe.substring(0, maximum - 1)}…';
}

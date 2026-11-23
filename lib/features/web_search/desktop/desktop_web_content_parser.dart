part of 'desktop_web_service.dart';

/// 下载落盘前的内容类型校验：网页 HTML 不能按原文件名保存。
///
/// 这是"下载的是网页不是文件"的现场：服务端返回 `text/html`，扩展名却是
/// `.pdf`，直接落盘会得到一个打不开的坏文件。
void _validateDownloadContentType(String fileName, String contentType) {
  final mimeType = contentType.split(';').first.trim().toLowerCase();
  if (mimeType != 'text/html' && mimeType != 'application/xhtml+xml') return;
  final extension = p.extension(fileName).toLowerCase();
  if (extension == '.html' || extension == '.htm' || extension == '.xhtml') {
    return;
  }
  throw const DesktopWebToolFailure(code: 'CONTENT_TYPE_MISMATCH');
}

/// 查询里的 `site:` 限制是否覆盖这个来源。
///
/// 搜索引擎会返回站点外的结果；不在这里拦一次，模型拿到的"官方站点"其实是
/// 二手转载页。
bool _matchesSiteSearchRestriction(String query, String sourceUrl) {
  final filters = RegExp(r'(?:^|\s)site:([^\s]+)', caseSensitive: false)
      .allMatches(query)
      .map((match) => match.group(1)!)
      .toList(growable: false);
  if (filters.isEmpty) return true;

  final source = Uri.tryParse(sourceUrl);
  if (source == null || source.host.isEmpty) return false;
  for (final filter in filters) {
    final site =
        Uri.tryParse(filter.contains('://') ? filter : 'https://$filter');
    if (site == null || site.host.isEmpty) continue;
    final host = source.host.toLowerCase();
    final siteHost = site.host.toLowerCase();
    if (host != siteHost && !host.endsWith('.$siteHost')) continue;
    final sitePath = site.pathSegments.where((segment) => segment.isNotEmpty);
    final sourcePath = source.pathSegments;
    var pathMatches = true;
    var index = 0;
    for (final segment in sitePath) {
      if (index >= sourcePath.length || sourcePath[index] != segment) {
        pathMatches = false;
        break;
      }
      index++;
    }
    if (pathMatches) return true;
  }
  return false;
}

/// 需要文档解析器处理的格式（pdf / docx / xlsx），其余返回 null。
String? _documentFormatFor(Uri url, String contentType) {
  final mime = contentType.split(';').first.trim().toLowerCase();
  final format = const {
    'application/pdf': 'pdf',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document':
        'docx',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet': 'xlsx',
  }[mime];
  if (format != null) return format;
  if (mime.startsWith('text/')) return null;
  final extension = p.extension(url.path).toLowerCase().replaceFirst('.', '');
  return const {'pdf', 'docx', 'xlsx'}.contains(extension) ? extension : null;
}

/// 按固定页长切出一段正文，并保证不切断 UTF-16 代理对。
Map<String, dynamic> _textPageOf(String text, int section) {
  const pageLength = 12000;
  var start = section * pageLength;
  if (start > text.length || (start == text.length && section > 0)) {
    throw StateError('文档没有可读取的该段正文。');
  }
  var end = (start + pageLength).clamp(0, text.length);
  // Keep UTF-16 surrogate pairs together across adjacent pages.
  if (start > 0 &&
      start < text.length &&
      text.codeUnitAt(start) >= 0xdc00 &&
      text.codeUnitAt(start) <= 0xdfff) {
    start++;
  }
  if (end < text.length &&
      text.codeUnitAt(end - 1) >= 0xd800 &&
      text.codeUnitAt(end - 1) <= 0xdbff) {
    end++;
  }
  return {
    'text': text.substring(start, end),
    'startSection': section,
    'nextSection': end < text.length ? section + 1 : null,
  };
}

/// 从一个 HTML 页面里能抽出来的三样东西。
class _HtmlPageContent {
  const _HtmlPageContent({
    required this.body,
    required this.links,
    required this.rankingItems,
    required this.officialRanking,
  });

  /// 去掉脚本/样式/表单后的可见正文。
  final String body;

  /// 页面内的普通链接（官方榜单页不抽，榜单本身就是来源）。
  final List<_HtmlLink> links;

  /// 百度热搜官方榜单条目；`officialRanking` 为 false 时为空。
  final List<Map<String, dynamic>> rankingItems;

  final bool officialRanking;
}

class _HtmlLink {
  const _HtmlLink({required this.url, required this.title});

  final Uri url;
  final String title;
}

/// 纯解析：不注册来源、不写证据，调用方决定这些副作用。
_HtmlPageContent _parseHtmlPage(String text, Uri url) {
  final document = html.parse(text);
  final officialRanking = url.host == 'top.baidu.com' &&
      url.path == '/board' &&
      (url.queryParameters['tab'] ?? 'realtime') == 'realtime';
  final rankingItems =
      officialRanking ? parseBaiduRealtimeTopTen(text) : <Map<String, dynamic>>[];
  final links = <_HtmlLink>[];
  if (!officialRanking) {
    final seen = <String>{};
    for (final anchor in document.querySelectorAll('a[href]')) {
      if (links.length >= 20) break;
      try {
        final target = url.resolve(anchor.attributes['href']!);
        if (!seen.add(target.toString())) continue;
        links.add(_HtmlLink(url: target, title: anchor.text.trim()));
      } on Object {
        continue;
      }
    }
  }
  document
      .querySelectorAll('script,style,noscript,template,svg,iframe,form')
      .forEach((element) => element.remove());
  return _HtmlPageContent(
    body: document.body?.text ?? '',
    links: links,
    rankingItems: rankingItems,
    officialRanking: officialRanking,
  );
}

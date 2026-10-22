import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

/// 用 Flutter 自己渲染 HTML 附件，替代内嵌 WebView 平台视图。
///
/// 为什么不用内嵌 WebView：macOS 上 WKWebView 作为 Flutter 平台视图时收不到
/// 鼠标指针事件（滚轮、拖选、点击全部失效，Dart 层也拿不到事件），同一份 HTML
/// 在原生 WKWebView 里却能正常滚动 —— 问题在平台视图而不是文档。改用 Flutter
/// 渲染后，滚动、文本选择、缩放全部由 Flutter 负责，不再依赖原生视图的事件转发。
///
/// 离线预览边界与原 WebView 方案一致：
/// - 不执行脚本（flutter_html 只解析 DOM）；
/// - 不发起网络请求：非 `data:` 图片直接换成占位文字，移除文档自带 CSS；
/// - 链接只展示不导航。
class FlutterHtmlPreview extends StatefulWidget {
  const FlutterHtmlPreview({super.key, required this.html});

  final String html;

  @override
  State<FlutterHtmlPreview> createState() => _FlutterHtmlPreviewState();
}

class _FlutterHtmlPreviewState extends State<FlutterHtmlPreview> {
  static const double _minZoom = .7;
  static const double _maxZoom = 2.5;
  static const double _zoomStep = .1;

  /// 超大文档先截断再解析，避免一次性构建过深的 RenderObject 树卡住 UI。
  static const int _maxRenderCharacters = 2 * 1024 * 1024;

  late final String _document = sanitizeHtmlForPreview(
    widget.html,
    maxCharacters: _maxRenderCharacters,
  );
  double _zoom = 1;

  void _changeZoom(double delta) {
    final next = (_zoom + delta).clamp(_minZoom, _maxZoom);
    if (next == _zoom) return;
    setState(() => _zoom = next);
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Row(mainAxisAlignment: MainAxisAlignment.end, children: [
        IconButton(
            tooltip: '缩小',
            onPressed: () => _changeZoom(-_zoomStep),
            icon: const Icon(Icons.zoom_out)),
        IconButton(
            tooltip: '放大',
            onPressed: () => _changeZoom(_zoomStep),
            icon: const Icon(Icons.zoom_in)),
      ]),
      const Divider(height: 1),
      Expanded(
        child: ColoredBox(
          color: Colors.white,
          // SelectionArea 让 Flutter 渲染的正文恢复"可以拖选文字"。
          child: SelectionArea(
            child: SingleChildScrollView(
              child: Html(
                data: _document,
                onLinkTap: (_, __, ___) {},
                // 双保险：即便还有漏网的网络图也不会真的发出请求。
                extensions: [
                  _offlineImages(),
                  // flutter_html 3.0 内置不渲染 <table>（单元格会整块消失），
                  // 而 XLSX 预览完全依赖表格，必须自带一份渲染。
                  _offlineTables(_zoom),
                ],
                style: _styles(),
              ),
            ),
          ),
        ),
      ),
    ]);
  }

  Map<String, Style> _styles() => {
        'html': Style(
          color: const Color(0xFF1F2328),
          backgroundColor: Colors.white,
          fontSize: FontSize(15 * _zoom),
          margin: Margins.zero,
          padding: HtmlPaddings.all(0),
        ),
        'body': Style(
          margin: Margins.zero,
          padding: HtmlPaddings.all(20 * _zoom),
        ),
        'pre': Style(
          backgroundColor: const Color(0xFFF6F8FA),
          padding: HtmlPaddings.all(12 * _zoom),
        ),
        'code': Style(
          fontFamily: 'monospace',
          fontSize: FontSize(13 * _zoom),
        ),
        'blockquote': Style(
          margin: Margins.only(left: 16 * _zoom),
          padding: HtmlPaddings.only(left: 12 * _zoom),
        ),
      };
}

const String _blockedImageText = '[图片未加载：离线预览]';

/// 把附件 HTML 收敛成"只能静态展示"的文档。
///
/// 只保留有意义的排版结构：可执行标签（script / iframe / object / embed）与
/// 会触发外部加载的标签（link / base / meta refresh）全部移除；非 `data:`
/// 图片换成占位文字；链接去掉 `href`；移除文档 CSS，使用统一的阅读排版。
@visibleForTesting
String sanitizeHtmlForPreview(String source, {int? maxCharacters}) {
  var input = source;
  if (maxCharacters != null && input.length > maxCharacters) {
    input = input.substring(0, maxCharacters);
  }
  final document = html_parser.parse(input);
  for (final tag in const [
    'script',
    'iframe',
    'object',
    'embed',
    'link',
    'base',
    'noscript',
  ]) {
    document.querySelectorAll(tag).forEach((element) => element.remove());
  }
  for (final meta in document.querySelectorAll('meta')) {
    final equiv = (meta.attributes['http-equiv'] ?? '').toLowerCase();
    if (equiv == 'refresh') meta.remove();
  }
  _normalizeTables(document);
  for (final image in document.querySelectorAll('img')) {
    final src = image.attributes['src'] ?? '';
    if (!src.startsWith('data:')) {
      image.replaceWith(dom.Element.tag('span')..text = _blockedImageText);
    }
  }
  for (final anchor in document.querySelectorAll('a')) {
    anchor.attributes.remove('href');
  }
  // 阅读模式不套用网页 CSS：Flex、百分比宽度与渐变并非 Flutter HTML 的能力。
  document.querySelectorAll('style').forEach((element) => element.remove());
  for (final element in document.querySelectorAll('[style]')) {
    element.attributes.remove('style');
  }
  return document.outerHtml;
}

/// 浏览器会自动把 `table > tr` 补进 `tbody`，DOM 解析器不会。
///
/// flutter_html 只在 `tbody` 下收集行，不补这一层的话整张表会渲染成空白
/// （LibreOffice 转出来的表格 HTML 与手写文档都可能有裸 `tr`）。
void _normalizeTables(dom.Document document) {
  for (final table in document.querySelectorAll('table')) {
    final looseRows =
        table.children.where((element) => element.localName == 'tr').toList();
    if (looseRows.isEmpty) continue;
    final body = dom.Element.tag('tbody');
    // 把裸行按原顺序搬进新 tbody，插到第一个裸行原来的位置。
    for (final row in looseRows) {
      body.append(row);
    }
    table.append(body);
  }
}

/// 表格里的一格；`colspan` 用"占位空格"表达，Flutter 的 Table 不支持合并单元格。
class _HtmlTableCell {
  const _HtmlTableCell(this.text,
      {this.html, this.header = false, this.colspan = 1, this.background});
  final String? html;
  final String text;
  final bool header;
  final int colspan;
  final Color? background;
}

class _HtmlTableRow {
  const _HtmlTableRow(this.cells, {required this.header});
  final List<_HtmlTableCell> cells;
  final bool header;
}

class _ExtractedTable {
  const _ExtractedTable(this.rows, this.columns, this.hiddenRows);
  final List<_HtmlTableRow> rows;
  final int columns;
  final int hiddenRows;
}

/// flutter_html 3.0 不渲染 `<table>`（整张表会变成空白），这里补一份够用的表格渲染。
///
/// 取舍：按列数均分可用宽度、合并单元格用空占位、长文本自动换行。超长表只渲染
/// 前 [_HtmlTable.maxRows] 行，避免一次性构建上千行把预览卡住。
class _HtmlTable extends StatelessWidget {
  const _HtmlTable({required this.element, required this.zoom, this.depth = 0});

  static const int maxRows = 400;
  static const int maxNesting = 4;
  static const int maxColumns = 64;
  static const int maxCells = 8000;
  static const double _cellPadding = 6;
  static const Color _borderColor = Color(0xFFD0D7DE);
  static const Color _headerBackground = Color(0xFFF6F8FA);

  final dom.Element element;
  final double zoom;
  final int depth;

  @override
  Widget build(BuildContext context) {
    final table = _extract();
    if (table == null) {
      return const Text('表格超过预览上限，请用系统应用打开查看。');
    }
    if (table.rows.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(builder: (context, constraints) {
      final available =
          constraints.maxWidth.isFinite && constraints.maxWidth > 0
              ? constraints.maxWidth
              : 640.0;
      // 边框会额外占位，均分时留 1px 余量，避免在 WidgetSpan 里溢出。
      final columnWidth = (available - 1) / table.columns;
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: (columnWidth < 24 ? 24.0 : columnWidth) * table.columns,
            child: Table(
              defaultColumnWidth:
                  FixedColumnWidth(columnWidth < 24 ? 24 : columnWidth),
              border: TableBorder.all(color: _borderColor, width: .5),
              children: [
                for (final row in table.rows) _row(row, table.columns)
              ],
            ),
          ),
        ),
        if (table.hiddenRows > 0)
          Padding(
            padding: EdgeInsets.only(top: 8 * zoom),
            child: Text(
              '表格较长，仅显示前 ${table.rows.length} 行，其余 ${table.hiddenRows} 行请用系统应用打开查看。',
              style: TextStyle(
                  fontSize: 12 * zoom, color: const Color(0xFF57606A)),
            ),
          ),
      ]);
    });
  }

  TableRow _row(_HtmlTableRow row, int columns) {
    final widgets = <Widget>[];
    for (final cell in row.cells) {
      widgets.add(_cell(cell));
      // 合并单元格：其余列补空位，保证对齐。
      for (var index = 1; index < cell.colspan; index++) {
        widgets.add(const SizedBox.shrink());
      }
    }
    while (widgets.length < columns) {
      widgets.add(const SizedBox.shrink());
    }
    return TableRow(
      decoration:
          row.header ? const BoxDecoration(color: _headerBackground) : null,
      children: widgets,
    );
  }

  Widget _cell(_HtmlTableCell cell) => ColoredBox(
      color: cell.background ?? Colors.transparent,
      child: Padding(
        padding: EdgeInsets.all(_cellPadding * zoom),
        child: cell.html != null
            ? Html(
                data: cell.html,
                onLinkTap: (_, __, ___) {},
                extensions: [
                  _offlineImages(),
                  _offlineTables(zoom, depth: depth + 1)
                ],
                style: {
                  'body': Style(
                      margin: Margins.zero,
                      padding: HtmlPaddings.all(0),
                      color: const Color(0xFF1F2328),
                      fontSize: FontSize(13 * zoom))
                },
              )
            : Text(
                cell.text,
                style: TextStyle(
                  fontSize: 13 * zoom,
                  fontWeight: cell.header ? FontWeight.w600 : FontWeight.normal,
                  color: const Color(0xFF1F2328),
                ),
              ),
      ));

  _ExtractedTable? _extract() {
    final all = <_HtmlTableRow>[];
    final occupied = List<int>.filled(maxColumns, 0);
    var columns = 0;
    var hiddenRows = 0;
    for (final row in _rowElements()) {
      if (all.length == maxRows) {
        hiddenRows++;
        continue;
      }
      final cells = <_HtmlTableCell>[];
      var column = 0;
      for (final child in row.children) {
        final name = child.localName;
        if (name != 'td' && name != 'th') continue;
        while (column < maxColumns && occupied[column] > 0) {
          cells.add(const _HtmlTableCell(''));
          column++;
        }
        final colspan = _positiveInt(child.attributes['colspan']);
        final rowspan = _positiveInt(child.attributes['rowspan']);
        if (colspan > maxColumns - column || rowspan > maxRows) return null;
        for (var index = column; index < column + colspan; index++) {
          if (occupied[index] > 0) return null;
          occupied[index] = rowspan;
        }
        cells.add(_HtmlTableCell(
          child.text.replaceAll(RegExp(r'\s+'), ' ').trim(),
          html: child.children.isEmpty ? null : child.innerHtml,
          header: name == 'th',
          colspan: colspan,
          background: _background(child),
        ));
        column += colspan;
      }
      final lastOccupied = occupied.lastIndexWhere((span) => span > 0) + 1;
      while (column < lastOccupied) {
        cells.add(const _HtmlTableCell(''));
        column++;
      }
      for (var index = 0; index < occupied.length; index++) {
        if (occupied[index] > 0) occupied[index]--;
      }
      if (cells.isEmpty) continue;
      if (column > columns) columns = column;
      if ((all.length + 1) * columns > maxCells) return null;
      all.add(_HtmlTableRow(cells, header: cells.any((cell) => cell.header)));
    }
    return _ExtractedTable(all, columns == 0 ? 1 : columns, hiddenRows);
  }

  /// 只收集属于当前表格的行，嵌套表格由它自己的渲染分支处理。
  Iterable<dom.Element> _rowElements() sync* {
    for (final child in element.children) {
      switch (child.localName) {
        case 'tr':
          yield child;
        case 'thead':
        case 'tbody':
        case 'tfoot':
          for (final row in child.children) {
            if (row.localName == 'tr') yield row;
          }
      }
    }
  }

  int _positiveInt(String? raw) {
    final parsed = int.tryParse((raw ?? '').trim()) ?? 1;
    return parsed < 1 ? 1 : parsed;
  }

  // Calc 用 bgcolor 搭配 font color 输出白字表头，底色必须与文字一起保留。
  Color? _background(dom.Element cell) {
    dom.Element? current = cell;
    while (current != null) {
      final raw = current.attributes['bgcolor']?.trim() ?? '';
      if (RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(raw)) {
        return Color(0xFF000000 | int.parse(raw.substring(1), radix: 16));
      }
      if (identical(current, element)) break;
      current = current.parent;
    }
    return null;
  }
}

TagExtension _offlineImages() => TagExtension(
      tagsToExtend: {'img'},
      builder: (context) {
        try {
          final data = Uri.tryParse(context.attributes['src'] ?? '')?.data;
          if (data == null || !data.mimeType.startsWith('image/')) {
            return const Text(_blockedImageText);
          }
          return Image.memory(data.contentAsBytes(),
              errorBuilder: (_, __, ___) => const Text('[图片无法预览]'));
        } on Object {
          return const Text('[图片无法预览]');
        }
      },
    );

TagExtension _offlineTables(double zoom, {int depth = 0}) => TagExtension(
      tagsToExtend: {'table'},
      builder: (context) {
        final element = context.element;
        if (element == null) return const SizedBox.shrink();
        if (depth >= _HtmlTable.maxNesting) {
          return const Text('表格嵌套超过预览上限，请用系统应用打开查看。');
        }
        return _HtmlTable(element: element, zoom: zoom, depth: depth);
      },
    );

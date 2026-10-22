import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:chat_group/core/text/entity_labels.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 读取上限。详情留档自身有 1 MiB 的落盘上限，但磁盘上的文件在应用外部
/// 可被改动，所以读取侧再收一道，失败与卡顿的规模因此有界。
const int maxReadableJsonBytes = 256 * 1024;

/// 显示上限。美化后的 JSON 行数与字符数都远大于原文件，整份塞进
/// `SelectableText` 会拖垮一帧；超出部分提示后省略，全文仍可复制。
const int maxReadableJsonCharacters = 100 * 1000;

/// 打开一份内部留档 JSON 的可读视图。
///
/// [prettifyJson] 为 false 时按纯文本处理：不尝试 JSON 美化，也不会提示
/// "内容不是合法 JSON"。纯文本附件（md / txt 等）走这条路径。
Future<void> showReadableJsonDialog(
  BuildContext context, {
  required String title,
  required String path,
  bool prettifyJson = true,
  bool structuredWorkPlan = false,
  bool renderMarkdown = false,
  bool showRawSource = false,
  EntityLabels? entityLabels,
}) =>
    showDialog<void>(
      context: context,
      builder: (_) => ReadableJsonDialog(
        title: title,
        path: path,
        prettifyJson: prettifyJson,
        structuredWorkPlan: structuredWorkPlan,
        renderMarkdown: renderMarkdown,
        showRawSource: showRawSource,
        entityLabels: entityLabels,
      ),
    );

/// 内部留档 JSON（以及纯文本附件）的只读呈现：等宽、可滚动、可复制全文。
///
/// 只吃「标题 + 路径」，不认识 Message / MediaAttachment 之类的业务对象，
/// 所以放在 core/widgets 而不进某个 feature。
///
/// 读取是同步的：这是一次用户点击触发的、本地 app-support 目录内、上限
/// 1 MiB 的单次读取，没有需要并发的其它工作；同步读同时消掉了加载态，
/// 于是不存在"读到一半被关掉"的中间状态。
class ReadableJsonDialog extends StatefulWidget {
  const ReadableJsonDialog({
    super.key,
    required this.title,
    required this.path,
    this.prettifyJson = true,
    this.structuredWorkPlan = false,
    this.renderMarkdown = false,
    this.showRawSource = false,
    this.entityLabels,
  });

  final String title;
  final String path;

  /// 是否按 JSON 美化显示。纯文本附件（md / txt 等）传 false。
  final bool prettifyJson;

  /// Only enabled for recognized work-mode detail attachments in group chat.
  /// Unknown JSON falls back to the ordinary formatted read-only view.
  final bool structuredWorkPlan;
  final bool renderMarkdown;
  final bool showRawSource;
  final EntityLabels? entityLabels;

  @override
  State<ReadableJsonDialog> createState() => _ReadableJsonDialogState();
}

class _ReadableJsonDialogState extends State<ReadableJsonDialog> {
  late final _DetailBody _body;
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _body = _readDetail(
      widget.path,
      prettifyJson: widget.prettifyJson,
      structuredWorkPlan: widget.structuredWorkPlan,
      renderMarkdown: widget.renderMarkdown,
      showRawSource: widget.showRawSource,
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _copyAll() async {
    await Clipboard.setData(ClipboardData(text: _body.copyable));
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: math.min(760, size.width * 0.9),
        height: math.min(560, size.height * 0.8),
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: _content(context),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _body.isError ? null : _copyAll,
          // 读取被截断时能复制的也只有读到的那一段，文案不能再说"全文"。
          child: Text(
            _body.copyTruncated
                ? '复制已读取部分'
                : _body.workPlan != null || widget.showRawSource
                    ? '复制原文'
                    : '复制全文',
          ),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  Widget _content(BuildContext context) {
    if (_body.isError) {
      return Center(
        child: Text(
          _body.error,
          textAlign: TextAlign.center,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      );
    }
    if (_body.workPlan != null) {
      return _WorkPlanJsonContent(
        controller: _scrollController,
        entityLabels: widget.entityLabels,
        plan: _body.workPlan!,
        raw: _body.raw,
      );
    }
    if (_body.markdown) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_body.notes.isNotEmpty) ...[
            Text(
              _body.notes.join('\n'),
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
          ],
          Expanded(
            child: _ReadableMarkdownContent(
              controller: _scrollController,
              text: _body.display,
              raw: _body.raw,
            ),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_body.notes.isNotEmpty) ...[
          Text(
            _body.notes.join('\n'),
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
        ],
        Expanded(
          child: Scrollbar(
            controller: _scrollController,
            thumbVisibility: true,
            child: SingleChildScrollView(
              controller: _scrollController,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(
                    _body.display,
                    style:
                        const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  ),
                  if (widget.prettifyJson && widget.showRawSource)
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      title: const Text('技术详情（原始 JSON）'),
                      children: [
                        Align(
                          alignment: Alignment.centerLeft,
                          child: SelectableText(
                            _body.raw,
                            style: const TextStyle(
                                fontFamily: 'monospace', fontSize: 11),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 渲染一份详情所需的全部信息：可显示正文、可复制全文、以及省略说明。
class _DetailBody {
  const _DetailBody({
    this.display = '',
    this.copyable = '',
    this.notes = const [],
    this.error = '',
    this.copyTruncated = false,
    this.raw = '',
    this.workPlan,
    this.markdown = false,
  });

  final String display;
  final String copyable;
  final List<String> notes;
  final String error;

  /// 读取本身被 [maxReadableJsonBytes] 截断：此时 [copyable] 也只是读到的那一段。
  final bool copyTruncated;
  final String raw;
  final Map<String, dynamic>? workPlan;
  final bool markdown;

  bool get isError => error.isNotEmpty;
}

_DetailBody _readDetail(
  String path, {
  bool prettifyJson = true,
  bool structuredWorkPlan = false,
  bool renderMarkdown = false,
  bool showRawSource = false,
}) {
  final String raw;
  final bool readTruncated;
  try {
    (raw, readTruncated) = _readBounded(path);
  } on Object {
    return const _DetailBody(error: '读取失败。这份文件可能已被清理或无法访问。');
  }
  final notes = <String>[];
  var text = raw;
  final plan = structuredWorkPlan ? _asWorkPlan(raw) : null;
  if (readTruncated) {
    notes.add('内容过大，仅读取前 ${maxReadableJsonBytes ~/ 1024} KB。');
  } else if (plan == null && prettifyJson) {
    try {
      text = const JsonEncoder.withIndent('  ').convert(jsonDecode(raw));
    } on Object {
      // 结构不是本应用写的（例如被外部改过），按原文显示而不是报错：
      // 能读到比读不到有用，何况原文本身可能就是有效的半成品。
      notes.add('内容不是合法 JSON，按原文显示。');
    }
  }
  final copyable = plan != null || showRawSource ? raw : text;
  if (text.length > maxReadableJsonCharacters) {
    text = text.substring(0, maxReadableJsonCharacters);
    // 读取本身被截断时，能复制的也只是读到的那一段。
    notes.add(readTruncated
        ? '内容过长，仅显示前 ${maxReadableJsonCharacters ~/ 10000} 万字符；可复制已读取部分。'
        : '内容过长，仅显示前 ${maxReadableJsonCharacters ~/ 10000} 万字符；可复制全文。');
  }
  return _DetailBody(
    display: text,
    copyable: copyable,
    notes: notes,
    copyTruncated: readTruncated,
    raw: raw,
    workPlan: plan,
    markdown: renderMarkdown && !readTruncated,
  );
}

Map<String, dynamic>? _asWorkPlan(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return null;
    final root = Map<String, dynamic>.from(decoded);
    final nested = root['proposal'];
    final proposal = nested is Map ? Map<String, dynamic>.from(nested) : root;
    final knownWorkShape = proposal['scope'] is String &&
        proposal['plan'] is String &&
        proposal['artifactContract'] is Map &&
        proposal['workItems'] is List &&
        proposal['acceptances'] is List;
    final knownCollaborationShape = proposal['artifactContract'] is Map &&
        proposal['issues'] is List &&
        proposal['acceptances'] is List;
    if (!knownWorkShape && !knownCollaborationShape) return null;
    return <String, dynamic>{
      ...root,
      'proposal': proposal,
      '_proposalEnvelope': nested is Map,
    };
  } on Object {
    return null;
  }
}

class _WorkPlanJsonContent extends StatelessWidget {
  const _WorkPlanJsonContent(
      {required this.plan,
      required this.raw,
      required this.controller,
      this.entityLabels});

  final ScrollController controller;

  final Map<String, dynamic> plan;
  final EntityLabels? entityLabels;
  final String raw;

  String _labelForDisplay(Object? value, String fallback) {
    final text = value?.toString() ?? fallback;
    return entityLabels?.resolveOrNull(text) ??
        entityLabels?.humanize(text) ??
        text;
  }

  @override
  Widget build(BuildContext context) {
    final proposal = plan['proposal'] as Map<String, dynamic>;
    final contract = proposal['artifactContract'] is Map
        ? Map<String, dynamic>.from(proposal['artifactContract'] as Map)
        : <String, dynamic>{};
    final workItems = _records(proposal['workItems']);
    final issues = _records(proposal['issues'] ?? plan['issues']);
    final acceptances = _records(proposal['acceptances']);
    final pendingProposal = issues.any((issue) =>
        issue['kind'] == 'idea' &&
        issue['status'] == 'open' &&
        (issue['resolution']?.toString() ?? '').startsWith('等待全员审阅'));
    final planTitle = pendingProposal
        ? '提案方案（尚未采纳）'
        : plan['_proposalEnvelope'] == true
            ? '方案内容'
            : '最终方案';
    final files = _stringList(contract['files']);
    final children = <Widget>[
      _detailSection(context, '目标', proposal['scope']),
      _detailSection(context, planTitle, proposal['plan']),
      if (contract.isNotEmpty)
        _detailSection(
          context,
          '交付位置与文件',
          <String>[
            for (final key in const [
              'type',
              'format',
              'location',
              'revisionTarget'
            ])
              if (contract[key] is String &&
                  (contract[key] as String).isNotEmpty)
                '${_workPlanLabel(key)}：${contract[key]}',
            if (files.isNotEmpty) '文件：${files.join('、')}',
          ].join('\n'),
        ),
      if (workItems.isNotEmpty)
        _detailSection(
          context,
          '分工',
          workItems.map((item) {
            final ownerId = item['ownerId']?.toString() ?? '';
            final owner = ownerId.isEmpty
                ? '待定'
                : entityLabels?.labelFor(ownerId) ?? ownerId;
            final status = item['status']?.toString();
            return '• ${_labelForDisplay(item['id'], '工作项')}：$owner${status == null ? '' : '（${_workPlanStatus(status)}）'}';
          }).join('\n'),
        ),
      if (issues.isNotEmpty)
        _detailSection(
          context,
          '问题与解决状态',
          issues.map((item) {
            final status = item['status']?.toString() ?? '待处理';
            final body =
                item['problem']?.toString() ?? item['title']?.toString() ?? '';
            final resolution = item['resolution']?.toString() ?? '';
            return '• ${_labelForDisplay(item['id'], '问题')}：$body\n  状态：${_workPlanStatus(status)}${resolution.isEmpty ? '' : '\n  解决方案：$resolution'}';
          }).join('\n'),
        ),
      if (acceptances.isNotEmpty)
        _detailSection(
          context,
          '验收标准',
          acceptances.map((item) {
            final status = item['status']?.toString();
            return '• ${_labelForDisplay(item['id'], '验收项')}：${item['method'] ?? ''}'
                '${status == null ? '' : '（${_workPlanStatus(status)}）'}';
          }).join('\n'),
        ),
      _detailSection(context, '版本', _versionSummary(plan)),
      const SizedBox(height: 8),
      ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: const Text('技术详情（原始 JSON）'),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: SelectableText(
              raw,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
          ),
        ],
      ),
    ];
    // 大段可选文本高度差异很大，懒加载会反复修正总高度，让滑块跳动。
    return Scrollbar(
      controller: controller,
      thumbVisibility: true,
      child: SingleChildScrollView(
        controller: controller,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }
}

String _versionSummary(Map<String, dynamic> plan) {
  final values = <String>[
    for (final key in const [
      'requestRevision',
      'teamRevision',
      'verificationRevision',
    ])
      if (plan[key] != null) '${_workPlanLabel(key)}：${plan[key]}',
  ];
  return values.isEmpty ? '此详情未包含版本字段。' : values.join(' · ');
}

Widget _detailSection(BuildContext context, String title, Object? value) =>
    _SectionEntry(
      title: title,
      value: value?.toString().trim().isNotEmpty == true
          ? value.toString()
          : '未记录',
    );

class _SectionEntry extends StatelessWidget {
  const _SectionEntry({required this.title, required this.value});
  final String title;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 3),
            SelectableText(value),
          ],
        ),
      );
}

List<Map<String, dynamic>> _records(Object? value) => value is List
    ? value.whereType<Map>().map(Map<String, dynamic>.from).toList()
    : <Map<String, dynamic>>[];

List<String> _stringList(Object? value) => value is List
    ? value.whereType<String>().toList(growable: false)
    : <String>[];

String _workPlanLabel(String key) => switch (key) {
      'type' => '类型',
      'format' => '格式',
      'location' => '位置',
      'revisionTarget' => '修订目标',
      'requestRevision' => '需求版本',
      'teamRevision' => '团队版本',
      'verificationRevision' => '验收版本',
      _ => key,
    };

String _workPlanStatus(String status) => switch (status) {
      'open' || 'pending' => '待处理',
      'resolved' || 'passed' || 'done' => '已解决',
      'failed' => '失败',
      'deferred' => '已暂缓',
      'waived' => '已豁免',
      'manual' => '人工记录',
      'rejected' => '未采纳',
      _ => status,
    };

class _ReadableMarkdownContent extends StatelessWidget {
  const _ReadableMarkdownContent(
      {required this.text, required this.raw, required this.controller});
  final ScrollController controller;

  final String text;
  final String raw;

  @override
  Widget build(BuildContext context) {
    final lines = text.split('\n');
    final blocks = <Widget>[];
    var index = 0;
    while (index < lines.length) {
      final line = lines[index].replaceFirst(RegExp(r'\r$'), '');
      if (line.trim().isEmpty) {
        index++;
        continue;
      }
      if (RegExp(r'^\s*```').hasMatch(line)) {
        index++;
        final code = <String>[];
        while (index < lines.length &&
            !RegExp(r'^\s*```').hasMatch(lines[index])) {
          code.add(lines[index].replaceFirst(RegExp(r'\r$'), ''));
          index++;
        }
        if (index < lines.length) index++;
        blocks.add(_MarkdownCodeBlock(text: code.join('\n')));
        continue;
      }
      if (line.trimLeft().startsWith('|') &&
          index + 1 < lines.length &&
          RegExp(r'^\s*\|?\s*:?-{3,}').hasMatch(lines[index + 1])) {
        final rows = <List<String>>[_markdownCells(line)];
        index += 2;
        while (
            index < lines.length && lines[index].trimLeft().startsWith('|')) {
          rows.add(_markdownCells(lines[index]));
          index++;
        }
        blocks.add(_MarkdownTable(rows: rows));
        continue;
      }
      final heading =
          RegExp(r'^\s{0,3}(#{1,6})\s+(.+?)\s*#*\s*$').firstMatch(line);
      if (heading != null) {
        final level = (heading.group(1) ?? '#').length;
        final style = switch (level) {
          1 => Theme.of(context).textTheme.headlineSmall,
          2 => Theme.of(context).textTheme.titleLarge,
          3 => Theme.of(context).textTheme.titleMedium,
          _ => Theme.of(context).textTheme.titleSmall,
        };
        blocks.add(Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 4),
          child: SelectableText.rich(
            _inlineMarkdown(heading.group(2) ?? '', context),
            style: style?.copyWith(fontWeight: FontWeight.w700),
          ),
        ));
        index++;
        continue;
      }
      final list = RegExp(r'^\s{0,3}([-+*]|\d+[.)])\s+(.+)$').firstMatch(line);
      if (list != null) {
        final marker = list.group(1)!;
        blocks.add(Padding(
          padding: const EdgeInsets.only(left: 8, bottom: 3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 25,
                child: Text(
                  RegExp(r'^\d').hasMatch(marker) ? marker : '•',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              Expanded(
                child: SelectableText.rich(
                  _inlineMarkdown(list.group(2) ?? '', context),
                ),
              ),
            ],
          ),
        ));
        index++;
        continue;
      }
      if (RegExp(r'^\s{0,3}([-*_]\s*){3,}$').hasMatch(line)) {
        blocks.add(const Divider(height: 16));
        index++;
        continue;
      }
      final paragraph = <String>[line];
      index++;
      while (index < lines.length && lines[index].trim().isNotEmpty) {
        final next = lines[index];
        if (RegExp(r'^\s*```|^\s{0,3}#{1,6}\s|^\s{0,3}([-+*]|\d+[.)])\s+')
                .hasMatch(next) ||
            next.trimLeft().startsWith('|')) {
          break;
        }
        paragraph.add(next.replaceFirst(RegExp(r'\r$'), ''));
        index++;
      }
      blocks.add(Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: SelectableText.rich(
          _inlineMarkdown(paragraph.join('\n'), context),
        ),
      ));
    }
    blocks.add(
      ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: const Text('技术详情（原始 Markdown）'),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: SelectableText(
              raw,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
          ),
        ],
      ),
    );
    return Scrollbar(
      controller: controller,
      thumbVisibility: true,
      child: ListView(
          controller: controller, padding: EdgeInsets.zero, children: blocks),
    );
  }
}

class _MarkdownCodeBlock extends StatelessWidget {
  const _MarkdownCodeBlock({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        margin: const EdgeInsets.symmetric(vertical: 5),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
        ),
        child: SelectableText(
          text,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
      );
}

class _MarkdownTable extends StatelessWidget {
  const _MarkdownTable({required this.rows});
  final List<List<String>> rows;

  @override
  Widget build(BuildContext context) {
    final width =
        rows.fold<int>(0, (value, row) => math.max(value, row.length));
    if (width == 0) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Table(
        defaultColumnWidth: const IntrinsicColumnWidth(),
        border: TableBorder.all(color: colors.outlineVariant),
        children: [
          for (var rowIndex = 0; rowIndex < rows.length; rowIndex++)
            TableRow(
              decoration: BoxDecoration(
                color: rowIndex == 0
                    ? colors.surfaceContainerHighest
                    : Colors.transparent,
              ),
              children: [
                for (var column = 0; column < width; column++)
                  Padding(
                    padding: const EdgeInsets.all(6),
                    child: SelectableText(
                      column < rows[rowIndex].length
                          ? rows[rowIndex][column]
                          : '',
                      style: TextStyle(
                        fontWeight:
                            rowIndex == 0 ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

List<String> _markdownCells(String line) {
  var value = line.trim();
  if (value.startsWith('|')) value = value.substring(1);
  if (value.endsWith('|')) value = value.substring(0, value.length - 1);
  return value.split('|').map((cell) => cell.trim()).toList(growable: false);
}

TextSpan _inlineMarkdown(String text, BuildContext context) {
  final pattern = RegExp(
    r'(\[[^\]]+\]\([^)]+\)|`[^`]+`|\*\*[^*]+\*\*|__[^_]+__|~~[^~]+~~|\*[^*]+\*|_[^_]+_)',
  );
  final spans = <InlineSpan>[];
  var offset = 0;
  for (final match in pattern.allMatches(text)) {
    if (match.start > offset) {
      spans.add(TextSpan(text: text.substring(offset, match.start)));
    }
    final token = match.group(0)!;
    if (token.startsWith('[')) {
      final split = token.indexOf('](');
      final label = token.substring(1, split);
      final url = token.substring(split + 2, token.length - 1);
      spans.add(TextSpan(
        text: '$label ($url)',
        style: TextStyle(
          color: Theme.of(context).colorScheme.primary,
          decoration: TextDecoration.underline,
        ),
      ));
    } else if (token.startsWith('`')) {
      spans.add(TextSpan(
        text: token.substring(1, token.length - 1),
        style: TextStyle(
          fontFamily: 'monospace',
          backgroundColor:
              Theme.of(context).colorScheme.surfaceContainerHighest,
        ),
      ));
    } else if (token.startsWith('~~')) {
      spans.add(TextSpan(
        text: token.substring(2, token.length - 2),
        style: const TextStyle(decoration: TextDecoration.lineThrough),
      ));
    } else if (token.startsWith('**') || token.startsWith('__')) {
      spans.add(TextSpan(
        text: token.substring(2, token.length - 2),
        style: const TextStyle(fontWeight: FontWeight.w700),
      ));
    } else {
      spans.add(TextSpan(
        text: token.substring(1, token.length - 1),
        style: const TextStyle(fontStyle: FontStyle.italic),
      ));
    }
    offset = match.end;
  }
  if (offset < text.length) spans.add(TextSpan(text: text.substring(offset)));
  return TextSpan(children: spans);
}

(String, bool) _readBounded(String path) {
  final file = File(path);
  final length = file.lengthSync();
  if (length <= maxReadableJsonBytes) return (file.readAsStringSync(), false);
  final handle = file.openSync();
  try {
    final head = handle.readSync(maxReadableJsonBytes);
    return (utf8.decode(head, allowMalformed: true), true);
  } finally {
    handle.closeSync();
  }
}

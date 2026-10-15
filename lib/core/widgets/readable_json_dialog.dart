import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

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
}) =>
    showDialog<void>(
      context: context,
      builder: (_) => ReadableJsonDialog(
        title: title,
        path: path,
        prettifyJson: prettifyJson,
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
  });

  final String title;
  final String path;

  /// 是否按 JSON 美化显示。纯文本附件（md / txt 等）传 false。
  final bool prettifyJson;

  @override
  State<ReadableJsonDialog> createState() => _ReadableJsonDialogState();
}

class _ReadableJsonDialogState extends State<ReadableJsonDialog> {
  late final _DetailBody _body;

  @override
  void initState() {
    super.initState();
    _body = _readDetail(widget.path, prettifyJson: widget.prettifyJson);
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
        child: _content(context),
      ),
      actions: [
        TextButton(
          onPressed: _body.isError ? null : _copyAll,
          // 读取被截断时能复制的也只有读到的那一段，文案不能再说"全文"。
          child: Text(_body.copyTruncated ? '复制已读取部分' : '复制全文'),
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
            child: SingleChildScrollView(
              child: SelectableText(
                _body.display,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
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
  });

  final String display;
  final String copyable;
  final List<String> notes;
  final String error;

  /// 读取本身被 [maxReadableJsonBytes] 截断：此时 [copyable] 也只是读到的那一段。
  final bool copyTruncated;

  bool get isError => error.isNotEmpty;
}

_DetailBody _readDetail(String path, {bool prettifyJson = true}) {
  final String raw;
  final bool readTruncated;
  try {
    (raw, readTruncated) = _readBounded(path);
  } on Object {
    return const _DetailBody(error: '读取失败。这份文件可能已被清理或无法访问。');
  }
  final notes = <String>[];
  var text = raw;
  if (readTruncated) {
    notes.add('内容过大，仅读取前 ${maxReadableJsonBytes ~/ 1024} KB。');
  } else if (prettifyJson) {
    try {
      text = const JsonEncoder.withIndent('  ').convert(jsonDecode(raw));
    } on Object {
      // 结构不是本应用写的（例如被外部改过），按原文显示而不是报错：
      // 能读到比读不到有用，何况原文本身可能就是有效的半成品。
      notes.add('内容不是合法 JSON，按原文显示。');
    }
  }
  final copyable = text;
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
  );
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

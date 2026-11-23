import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import '../../chat_group/message_action_item.dart';
import '../../chat_group/widgets/message_selectable_text.dart';
import '../../chat_group/widgets/wecom_chat_components.dart';
import '../application/search_context_formatter.dart';
import '../models/search_models.dart';

/// Source-backed text keeps the existing selection and message action menu.
class InlineSearchReply extends StatefulWidget {
  const InlineSearchReply(
      {super.key,
      required this.content,
      required this.snapshot,
      required this.style,
      required this.mentionNames,
      this.messageActions,
      this.onOpenSource,
      this.selectionMode = false,
      this.onTap});
  final String content;
  final Map<dynamic, dynamic> snapshot;
  final TextStyle style;
  final Iterable<String> mentionNames;
  final List<MessageActionItem> Function()? messageActions;
  final ValueChanged<Uri>? onOpenSource;
  final bool selectionMode;
  final VoidCallback? onTap;
  @override
  State<InlineSearchReply> createState() => _InlineSearchReplyState();
}

class _InlineSearchReplyState extends State<InlineSearchReply> {
  bool _expanded = false;
  final _recognizers = <String, TapGestureRecognizer>{};

  @override
  void dispose() {
    for (final recognizer in _recognizers.values) {
      recognizer.dispose();
    }
    super.dispose();
  }

  List<MapEntry<String, WebSearchResult>> _sources() {
    final primary = WebSearchSnapshot.fromMap(widget.snapshot);
    final extra = widget.snapshot['networkSources'];
    final secondary = extra is Map ? WebSearchSnapshot.fromMap(extra) : null;
    const formatter = SearchContextFormatter();
    final entries = [
      if (primary != null) ...formatter.sourceEntriesForSnapshot(primary),
      if (secondary != null) ...formatter.sourceEntriesForSnapshot(secondary),
    ];
    entries.sort((a, b) {
      final family = a.key[0].compareTo(b.key[0]);
      return family != 0
          ? family
          : (int.tryParse(a.key.substring(1)) ?? 0)
              .compareTo(int.tryParse(b.key.substring(1)) ?? 0);
    });
    return entries;
  }

  TextSpan _link(String text, WebSearchResult? source, TextStyle style) {
    final uri = source == null ? null : tryValidateSearchUrl(source.url);
    if (uri == null || widget.selectionMode || widget.onOpenSource == null) {
      return TextSpan(text: text, style: style);
    }
    final recognizer =
        _recognizers.putIfAbsent(uri.toString(), TapGestureRecognizer.new);
    recognizer.onTap = () => widget.onOpenSource?.call(uri);
    return TextSpan(
        text: text,
        style: style.copyWith(
            color: Theme.of(context).colorScheme.primary,
            decoration: TextDecoration.underline),
        recognizer: recognizer,
        mouseCursor: SystemMouseCursors.click);
  }

  List<InlineSpan> _spans(List<MapEntry<String, WebSearchResult>> sources) {
    final byUrl = {
      for (final entry in sources) entry.value.url.toString(): entry.value
    };
    final byTitle = {
      for (final entry in sources) entry.value.title: entry.value
    };
    final pattern = RegExp(
        r'\[([^\]\n]+)\]\((https://[^\s)]+)\)|(https://[^\s<>\]\)。，！？]+)|\*\*([^*\n]+)\*\*');
    final spans = <InlineSpan>[];
    var cursor = 0;
    void plain(String text) => spans.addAll(buildWeComMentionSpans(text,
        mentionNames: widget.mentionNames, baseStyle: widget.style));
    for (final match in pattern.allMatches(widget.content)) {
      plain(widget.content.substring(cursor, match.start));
      final url = match.group(2) ?? match.group(3);
      if (url != null) {
        final source = byUrl[Uri.tryParse(url)?.toString()];
        spans.add(_link(
            match.group(1) ?? (source == null ? url : source.displayHost),
            source,
            widget.style));
      } else {
        final title = match.group(4)!;
        spans.add(_link(title, byTitle[title],
            widget.style.copyWith(fontWeight: FontWeight.w600)));
      }
      cursor = match.end;
    }
    plain(widget.content.substring(cursor));
    return spans;
  }

  @override
  Widget build(BuildContext context) {
    final sources = _sources();
    final retrieved = sources.any((entry) => entry.value.provider != '官方公开入口');
    return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MessageSelectableText(
              content: widget.content,
              style: widget.style,
              spans: _spans(sources),
              messageActions: widget.messageActions,
              enableSelection: !widget.selectionMode,
              onTap: widget.onTap),
          TextButton.icon(
            onPressed: widget.selectionMode
                ? null
                : () => setState(() => _expanded = !_expanded),
            icon: Icon(_expanded ? Icons.expand_less : Icons.public, size: 16),
            label: Text(sources.isEmpty
                ? '未取得联网来源'
                : '${retrieved ? '已联网' : '已找到入口'} · ${sources.length} 个来源'),
          ),
          if (_expanded) ...[
            const Divider(height: 12),
            for (final entry in sources) _sourceTile(entry),
          ],
        ]);
  }

  Widget _sourceTile(MapEntry<String, WebSearchResult> entry) {
    final uri = tryValidateSearchUrl(entry.value.url);
    final title = entry.value.provider == '官方公开入口'
        ? entry.value.title.split('（').first
        : entry.value.title;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text('[${entry.key}] $title'),
      subtitle: Text(entry.value.displayHost),
      trailing: uri == null ? null : const Icon(Icons.open_in_new, size: 16),
      onTap: widget.selectionMode || widget.onOpenSource == null || uri == null
          ? null
          : () => widget.onOpenSource!(uri),
    );
  }
}

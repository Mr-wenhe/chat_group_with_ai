import 'dart:convert';

/// Parent CSP is inherited by srcdoc and cannot be relaxed by attachment markup.
/// The opaque sandbox has no native bridge, local file access, forms or popups.
String offlinePreviewHtml(String source, {bool mediaPlayback = false}) {
  final escaped = const HtmlEscape(HtmlEscapeMode.attribute).convert(source);
  return '''<!doctype html><html><head><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; media-src data: blob:; font-src data:; frame-src about:; connect-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; worker-src 'none'">
<style>html,body{margin:0;height:100%;overflow:hidden;background:white}iframe{display:block;border:0;width:100%;height:100%}</style>
</head><body><iframe sandbox="allow-scripts" allow="${mediaPlayback ? 'autoplay; ' : ''}camera 'none'; microphone 'none'; geolocation 'none'; clipboard-read 'none'; clipboard-write 'none'" srcdoc="$escaped"></iframe></body></html>''';
}

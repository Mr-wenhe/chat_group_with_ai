// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:html' as html;

Future<bool> openDataAttachment(String dataUri, String fileName) async {
  final anchor = html.AnchorElement(href: dataUri)
    ..download = fileName
    ..style.display = 'none';
  html.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  return true;
}

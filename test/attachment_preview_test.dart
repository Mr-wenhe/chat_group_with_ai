import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:chat_group/core/models/media_attachment.dart';
import 'package:chat_group/features/document/attachment_preview_dialog.dart';
import 'package:chat_group/features/document/attachment_preview_format.dart';
import 'package:chat_group/features/document/office_preview_session.dart';
import 'package:chat_group/features/document/offline_preview_html.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:syncfusion_flutter_pdf/pdf.dart';

void main() {
  test('common desktop formats include legacy Office and exclude archives', () {
    expect(attachmentPreviewFormat('unnamed', mediaType: 'image'),
        AttachmentPreviewFormat.image);
    expect(attachmentPreviewFormat('unnamed', mimeType: 'audio/wav'),
        AttachmentPreviewFormat.audio);
    for (final name in [
      'x.doc',
      'x.DOCX',
      'x.ppt',
      'x.pptx',
      'x.xls',
      'x.xlsx',
      'x.md',
      'x.txt',
      'x.pdf',
      'x.html',
      'x.py',
      'x.png',
      'x.mp3',
      'x.mp4',
      'x.MOV',
      'x.m4a'
    ]) {
      expect(attachmentPreviewFormat(name),
          isNot(AttachmentPreviewFormat.unsupported),
          reason: name);
    }
    for (final name in ['x.zip', 'x.rar', 'x.7z', 'x.exe']) {
      expect(
          attachmentPreviewFormat(name), AttachmentPreviewFormat.unsupported);
    }
  });

  test('attachment HTML stays in one opaque sandbox under parent CSP', () {
    const attack =
        '''</iframe><script>parent.location='https://example.com';fetch('file:///etc/passwd')</script><img src="https://example.com/track">''';
    final document = html.parse(offlinePreviewHtml(attack));
    final frame = document.querySelector('iframe')!;
    expect(frame.attributes['srcdoc'], attack);
    expect(frame.attributes['sandbox'], 'allow-scripts');
    expect(document.querySelectorAll('iframe'), hasLength(1));
    expect(document.querySelectorAll('script'), isEmpty);
    final csp = document
        .querySelector('meta[http-equiv="Content-Security-Policy"]')!
        .attributes['content']!;
    for (final directive in [
      "default-src 'none'",
      "connect-src 'none'",
      "object-src 'none'",
      "form-action 'none'",
      "frame-src about:"
    ]) {
      expect(csp, contains(directive));
    }
    expect(csp, isNot(contains('https:')));
  });

  test('worksheets keep names, styles, spans and omit nested tables as sheets',
      () {
    final sheets = parsePreviewSheets(
        '<style>td{color:red}</style><table><caption><a name="收入">收入</a></caption><tr><td colspan="2">42<table><tr><td>nested</td></tr></table></td></tr></table><table><caption>支出</caption><tr><td>7</td></tr></table>');
    expect(sheets.map((s) => s.name), ['收入', '支出']);
    expect(sheets.first.html, contains('colspan="2"'));
    expect(sheets.first.html, contains('color:red'));
    expect(() => parsePreviewSheets('<p>broken</p>'),
        throwsA(isA<AttachmentPreviewException>()));
  });

  test(
      'bounded text reads decode UTF-8 and UTF-16 and reject oversize/invalid data',
      () async {
    final directory = await Directory.systemTemp.createTemp('preview-test-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/text');
    await file.writeAsString('中文');
    expect(await readPreviewText(file), '中文');
    await file.writeAsBytes([0xff, 0xfe, 0x2d, 0x4e, 0x87, 0x65]);
    expect(await readPreviewText(file), '中文');
    await expectLater(readPreviewText(file, limit: 3),
        throwsA(isA<AttachmentPreviewException>()));
    await file.writeAsBytes([0xff, 0x33]);
    await expectLater(
        readPreviewText(file), throwsA(isA<AttachmentPreviewException>()));
  });

  test('spreadsheet images cannot escape the conversion directory', () async {
    final root = await Directory.systemTemp.createTemp('preview-images-');
    addTearDown(() => root.delete(recursive: true));
    final converted = await Directory('${root.path}/converted').create();
    await File('${root.path}/secret.png').writeAsBytes([9, 8, 7]);
    await File('${converted.path}/pixel.png').writeAsBytes([1, 2, 3]);
    final file = await File('${converted.path}/source.html').writeAsString(
        '<table><tr><td><img src="pixel.png"><img src="../secret.png"><img src="https://example.com/image.png"></td></tr></table>');
    final sheet = (await loadPreviewSheets(file)).single.html;
    expect(sheet, contains('data:image/png;base64,AQID'));
    expect(sheet, isNot(contains('data:image/png;base64,CQgH')));
    expect(sheet, contains('../secret.png'));
  });

  testWidgets(
      'Markdown is formatted and viewer retains external-open/save fallbacks',
      (tester) async {
    final directory = Directory.systemTemp.createTempSync('preview-widget-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/report.md')
      ..writeAsStringSync('# 标题\n\n|列|值|\n|--|--|\n|甲|一|');
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
          home: AttachmentPreviewDialog(
              attachment: MediaAttachment(
                  type: 'file', localPath: file.path, fileName: 'report.md'))));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    expect(find.byType(Markdown), findsOneWidget);
    expect(find.text('用系统应用打开'), findsOneWidget);
    expect(find.text('另存为'), findsOneWidget);
    expect(find.text('复制全文'), findsOneWidget);
  });

  testWidgets(
      'missing files show an actionable error instead of an endless spinner',
      (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(
          home: AttachmentPreviewDialog(
              attachment: MediaAttachment(
                  type: 'file',
                  localPath: '/missing-preview-file',
                  fileName: 'report.docx'))));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    expect(find.textContaining('附件文件不存在'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  test(
      'installed LibreOffice converts Word and Excel without altering originals',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('preview-conversion-test-');
    addTearDown(() => directory.delete(recursive: true));
    final archive = Archive();
    void part(String name, String content) {
      final bytes = utf8.encode(content);
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }

    part('[Content_Types].xml',
        '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/></Types>');
    part('_rels/.rels',
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>');
    part('xl/workbook.xml',
        '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="收入" sheetId="1" r:id="rId1"/><sheet name="支出" sheetId="2" r:id="rId2"/></sheets></workbook>');
    part('xl/_rels/workbook.xml.rels',
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/></Relationships>');
    for (var i = 1; i <= 2; i++) {
      part('xl/worksheets/sheet$i.xml',
          '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>工作表$i</t></is></c><c r="B1"><v>$i</v></c></row></sheetData></worksheet>');
    }
    final source = await File('${directory.path}/example.xlsx')
        .writeAsBytes(ZipEncoder().encode(archive));
    final original = await source.readAsBytes();
    final session = OfficePreviewSession();
    addTearDown(session.close);
    final converted = await session.convert(source, spreadsheet: true);
    final sheets = parsePreviewSheets(await readPreviewText(converted));
    expect(sheets, hasLength(2));
    expect(sheets.map((s) => s.name), ['收入', '支出']);
    expect(sheets.first.html, contains('工作表1'));
    expect(await source.readAsBytes(), original);
    await session.close();
    expect(await converted.exists(), isFalse);

    final rtf = await File('${directory.path}/word.rtf')
        .writeAsString(r'{\rtf1\ansi Preview test\par Second line}');
    final word = OfficePreviewSession();
    addTearDown(word.close);
    final pdf = await word.convert(rtf, spreadsheet: false);
    expect(utf8.decode(await pdf.openRead(0, 4).first), '%PDF');

    for (final name in ['sample.docx', 'sample.pptx']) {
      final source = File('test/fixtures/attachment_preview/$name');
      final original = await source.readAsBytes();
      final preview = OfficePreviewSession();
      addTearDown(preview.close);
      final pdf = await preview.convert(source, spreadsheet: false);
      expect(utf8.decode(await pdf.openRead(0, 4).first), '%PDF');
      final document = PdfDocument(inputBytes: await pdf.readAsBytes());
      try {
        expect(document.pages.count, 2);
        final text = PdfTextExtractor(document).extractText();
        expect(text, contains('中文预览'));
        expect(text, contains('第二页'));
      } finally {
        document.dispose();
      }
      expect(await source.readAsBytes(), original);
      await preview.close();
    }
  },
      skip: OfficePreviewSession.findOfficeExecutable() == null
          ? 'LibreOffice not installed'
          : false,
      timeout: const Timeout(Duration(seconds: 30)));
}

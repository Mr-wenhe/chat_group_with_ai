import 'dart:convert';
import 'dart:io';

import 'package:chat_group/features/document/attachment_pdf_preview.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfx/pdfx.dart';
import 'package:pdfx/src/renderer/interfaces/platform.dart';
import 'package:pdfx/src/renderer/io/platform_method_channel.dart';

void main() {
  testWidgets('PDF navigation and zoom share bounded state', (tester) async {
    final originalPlatform = PdfxPlatform.instance;
    PdfxPlatform.instance = PdfxPlatformMethodChannel();
    addTearDown(() => PdfxPlatform.instance = originalPlatform);
    final directory = Directory.systemTemp.createTempSync('pdf-widget-test-');
    addTearDown(() => directory.deleteSync(recursive: true));
    var imageNumber = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('io.scer.pdf_renderer'),
            (call) async {
      switch (call.method) {
        case 'open.document.file':
          return {'id': 'document', 'pagesCount': 3};
        case 'open.page':
          return {'id': 'page', 'width': 600.0, 'height': 800.0};
        case 'render':
          final image = File('${directory.path}/${imageNumber++}.png');
          image.writeAsBytesSync(base64Decode(
              'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII='));
          return {'width': 1, 'height': 1, 'path': image.path};
      }
      return null;
    });
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: AttachmentPdfPreview(file: File('/test.pdf')))));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump(const Duration(milliseconds: 300));
    final viewer =
        tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));
    final transform = viewer.transformationController!;
    await tester.tap(find.byTooltip('放大'));
    expect(transform.value.getMaxScaleOnAxis(), 1.25);
    await tester.tap(find.byTooltip('缩小'));
    expect(transform.value.getMaxScaleOnAxis(), 1);
    final pdf = tester.widget<PdfView>(find.byType(PdfView));
    expect(pdf.controller.pagesCount, 3);
    await tester.tap(find.byTooltip('上一页'));
    expect(pdf.controller.page, 1);
    await tester.tap(find.byTooltip('放大'));
    await tester.tap(find.byTooltip('下一页'));
    expect(transform.value.getMaxScaleOnAxis(), 1);
    await tester.pump(const Duration(milliseconds: 300));
    // 动画起始帧之后推进时间，避免把首次 pump 当成动画结束。
    await tester.pump(const Duration(milliseconds: 300));
    expect(pdf.controller.page, 2);
    expect(tester.takeException(), isNull);
  });
}

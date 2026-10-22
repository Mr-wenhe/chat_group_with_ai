import 'dart:io';

import 'package:flutter/material.dart';
import 'package:pdfx/pdfx.dart';

class AttachmentPdfPreview extends StatefulWidget {
  const AttachmentPdfPreview({super.key, required this.file});
  final File file;
  @override
  State<AttachmentPdfPreview> createState() => _AttachmentPdfPreviewState();
}

class _AttachmentPdfPreviewState extends State<AttachmentPdfPreview> {
  late final _controller =
      PdfController(document: PdfDocument.openFile(widget.file.path));

  final _zoomController = TransformationController();

  @override
  void dispose() {
    _zoomController.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _page(int delta) {
    if (_controller.pagesCount == null) return;
    final page = _controller.page + delta;
    if (page < 1 || page > _controller.pagesCount!) return;
    _zoomController.value = Matrix4.identity();
    _controller.animateToPage(page,
        duration: const Duration(milliseconds: 200), curve: Curves.easeInOut);
  }

  void _zoom(double factor) {
    if (_controller.pagesCount == null) return;
    final scale = _zoomController.value.getMaxScaleOnAxis();
    final target = (scale * factor).clamp(1.0, 8.0);
    _zoomController.value = _zoomController.value.clone()
      ..scale(target / scale);
  }

  @override
  Widget build(BuildContext context) => Column(children: [
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          IconButton(
              tooltip: '上一页',
              onPressed: () => _page(-1),
              icon: const Icon(Icons.chevron_left)),
          PdfPageNumber(
              controller: _controller,
              builder: (_, __, page, count) => Text('$page / ${count ?? "…"}')),
          IconButton(
              tooltip: '下一页',
              onPressed: () => _page(1),
              icon: const Icon(Icons.chevron_right)),
          IconButton(
              tooltip: '缩小',
              onPressed: () => _zoom(.8),
              icon: const Icon(Icons.zoom_out)),
          IconButton(
              tooltip: '放大',
              onPressed: () => _zoom(1.25),
              icon: const Icon(Icons.zoom_in)),
        ]),
        Expanded(
            child: InteractiveViewer(
                transformationController: _zoomController,
                minScale: 1,
                maxScale: 8,
                child: PdfView(
                    controller: _controller,
                    builders: PdfViewBuilders<DefaultBuilderOptions>(
                        options: const DefaultBuilderOptions(),
                        documentLoaderBuilder: (_) =>
                            const Center(child: CircularProgressIndicator()),
                        pageLoaderBuilder: (_) =>
                            const Center(child: CircularProgressIndicator()),
                        errorBuilder: (_, __) => const Center(
                            child: Text('PDF 无法显示，文件可能已损坏或需要密码。')))))),
      ]);
}

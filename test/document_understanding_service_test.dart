import 'dart:typed_data';
import 'dart:ui';

import 'package:archive/archive.dart';
import 'package:chat_group/core/models/attachment_data_uri.dart';
import 'package:chat_group/core/models/media_attachment.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/features/chat_group/multimodal_content.dart';
import 'package:chat_group/features/document/document_understanding_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

void main() {
  setUp(DocumentUnderstandingService.clearCache);

  test('retrieves relevant Markdown chunks and injects traceable sources',
      () async {
    final attachment = MediaAttachment(
      id: 'doc1',
      type: 'file',
      localPath: '/tmp/spec.md',
      fileName: 'spec.md',
      fileSize: 180,
      mimeType: 'text/markdown',
    );

    final context = await DocumentUnderstandingService.buildPromptContext(
      query: '发布日期是什么时候',
      attachments: [attachment],
      readText: (_) async => '# 背景\n\n项目用于内部协作。\n\n发布日期是 7 月 30 日。',
    );

    expect(context, contains('发布日期是 7 月 30 日'));
    expect(context, contains('[来源：spec.md · 段落 3]'));
    expect(DocumentUnderstandingService.statusLabel(attachment), '已解析 · 可引用');
  });

  test('normal chat content sends only document context with citation rules',
      () async {
    final attachment = MediaAttachment(
      id: 'doc1',
      type: 'file',
      localPath: '/tmp/notes.txt',
      fileName: 'notes.txt',
      fileSize: 80,
      mimeType: 'text/plain',
    );
    final message = Message(
      groupId: 'g1',
      senderId: 'user',
      senderType: 'user',
      content: '负责人是谁？',
      media: [attachment],
    );

    final content = await prepareUserMessageContent(
      message,
      supportsVision: false,
      documentTextReader: (_) async => '负责人是小薇。\n\n预算另行确认。',
    );

    expect(content, isA<String>());
    expect(content, contains('负责人是小薇'));
    expect(content, contains('[来源：notes.txt · 段落 1]'));
  });

  test('CSV chunks retain row ranges for citations', () async {
    final attachment = MediaAttachment(
      type: 'file',
      localPath: '/tmp/budget.csv',
      fileName: 'budget.csv',
      fileSize: 80,
      mimeType: 'text/csv',
    );

    final context = await DocumentUnderstandingService.buildPromptContext(
      query: '设计预算',
      attachments: [attachment],
      readText: (_) async => '项目,预算\n设计,1200\n开发,3000',
    );

    expect(context, contains('设计,1200'));
    expect(context, contains('[来源：budget.csv · 行 1-3]'));
  });

  test('splits an oversized CSV row without losing its source line', () async {
    final attachment = MediaAttachment(
      type: 'file',
      localPath: '/tmp/long.csv',
      fileName: 'long.csv',
      fileSize: 2000,
      mimeType: 'text/csv',
    );

    final result = await DocumentUnderstandingService.parse(
      attachment,
      readText: (_) async => List.filled(1500, 'x').join(),
    );

    expect(result.status, DocumentParseStatus.ready);
    expect(result.chunks, hasLength(2));
    expect(
      result.chunks.every(
        (chunk) =>
            chunk.text.length <= DocumentUnderstandingService.maxChunkChars &&
            chunk.source.lineStart == 1 &&
            chunk.source.lineEnd == 1,
      ),
      isTrue,
    );
  });

  test('oversize, damaged JSON and cancellation fail without hanging',
      () async {
    final tooLarge = MediaAttachment(
      type: 'file',
      localPath: '/tmp/large.txt',
      fileName: 'large.txt',
      fileSize: DocumentUnderstandingService.maxDocumentBytes + 1,
    );
    expect(
      (await DocumentUnderstandingService.parse(tooLarge)).status,
      DocumentParseStatus.tooLarge,
    );

    final damaged = MediaAttachment(
      type: 'file',
      localPath: '/tmp/broken.json',
      fileName: 'broken.json',
      fileSize: 10,
    );
    expect(
      (await DocumentUnderstandingService.parse(
        damaged,
        readText: (_) async => '{broken',
      ))
          .status,
      DocumentParseStatus.failed,
    );

    final token = DocumentProcessingToken()..cancel();
    final cancelled = MediaAttachment(
      type: 'file',
      localPath: '/tmp/cancelled.md',
      fileName: 'cancelled.md',
      fileSize: 10,
    );
    final result = await DocumentUnderstandingService.parse(
      cancelled,
      cancelToken: token,
      readText: (_) async => '不应读取',
    );
    expect(result.error, '解析已取消');
  });

  test('bounds text returned by an injected reader before chunking', () async {
    final attachment = MediaAttachment(
      type: 'file',
      localPath: '/tmp/injected-large.txt',
      fileName: 'injected-large.txt',
      fileSize: 1,
    );
    final result = await DocumentUnderstandingService.parse(
      attachment,
      readText: (_) async => List.filled(
        DocumentUnderstandingService.maxDocumentBytes + 1,
        'x',
      ).join(),
    );

    expect(result.status, DocumentParseStatus.tooLarge);
    expect(result.error, contains('超过解析上限'));
  });

  test('rejects oversized and damaged binary documents safely', () async {
    final tooLarge = MediaAttachment(
      type: 'file',
      localPath: '/tmp/large.pdf',
      fileName: 'large.pdf',
      fileSize: DocumentUnderstandingService.maxBinaryDocumentBytes + 1,
      mimeType: 'application/pdf',
    );
    final damagedDocx = createDataUriAttachment(
      bytes: const [1, 2, 3, 4],
      fileName: 'broken.docx',
      mimeType:
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    );

    expect(
      (await DocumentUnderstandingService.parse(tooLarge)).status,
      DocumentParseStatus.tooLarge,
    );
    final damagedResult = await DocumentUnderstandingService.parse(damagedDocx);
    expect(damagedResult.status, DocumentParseStatus.failed);
    expect(damagedResult.error, contains('Open XML 文件签名无效'));
  });

  test('extracts PDF pages with page citations', () async {
    final document = PdfDocument();
    document.pages.add().graphics.drawString(
          'Release date is July 30.',
          PdfStandardFont(PdfFontFamily.helvetica, 12),
          bounds: const Rect.fromLTWH(20, 20, 300, 40),
        );
    final bytes = await document.save();
    document.dispose();
    final attachment = createDataUriAttachment(
      bytes: bytes,
      fileName: 'release.pdf',
      mimeType: 'application/pdf',
    );

    final context = await DocumentUnderstandingService.buildPromptContext(
      query: 'release date',
      attachments: [attachment],
    );

    expect(context, contains('Release date is July 30'));
    expect(context, contains('[来源：release.pdf · 第 1 页]'));
  });

  test('extracts DOCX paragraphs and XLSX sheet rows', () async {
    final docx = createDataUriAttachment(
      bytes: _zip({
        'word/document.xml': '''
          <w:document xmlns:w="word"><w:body>
            <w:p><w:r><w:t>项目负责人是小薇</w:t></w:r></w:p>
            <w:p><w:r><w:t>上线日期是 7 月 30 日</w:t></w:r></w:p>
          </w:body></w:document>
        ''',
      }),
      fileName: 'plan.docx',
      mimeType:
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    );
    final xlsx = createDataUriAttachment(
      bytes: _zip({
        'xl/workbook.xml': '''
          <workbook xmlns:r="rel"><sheets>
            <sheet name="预算" r:id="rId1"/>
          </sheets></workbook>
        ''',
        'xl/_rels/workbook.xml.rels': '''
          <Relationships><Relationship Id="rId1"
            Target="worksheets/sheet1.xml"/></Relationships>
        ''',
        'xl/sharedStrings.xml': '''
          <sst><si><t>设计</t></si></sst>
        ''',
        'xl/worksheets/sheet1.xml': '''
          <worksheet><sheetData><row r="1">
            <c r="A1" t="s"><v>0</v></c><c r="B1"><v>1200</v></c>
          </row></sheetData></worksheet>
        ''',
      }),
      fileName: 'budget.xlsx',
      mimeType:
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    );

    final docxContext = await DocumentUnderstandingService.buildPromptContext(
      query: '项目负责人',
      attachments: [docx],
    );
    final xlsxContext = await DocumentUnderstandingService.buildPromptContext(
      query: '设计预算',
      attachments: [xlsx],
    );

    expect(docxContext, contains('项目负责人是小薇'));
    expect(docxContext, contains('[来源：plan.docx · 段落 1]'));
    expect(xlsxContext, contains('A1: 设计 | B1: 1200'));
    expect(xlsxContext, contains('[来源：budget.xlsx · 工作表 预算 · 行 1]'));
  });

  test('cleared document cache rebuilds from the source attachment', () async {
    var reads = 0;
    final attachment = MediaAttachment(
      type: 'file',
      localPath: '/tmp/rebuild.txt',
      fileName: 'rebuild.txt',
      fileSize: 20,
    );
    Future<String> read(String _) async {
      reads++;
      return '可重建的事实来源';
    }

    await DocumentUnderstandingService.buildPromptContext(
      query: '事实来源',
      attachments: [attachment],
      readText: read,
    );
    DocumentUnderstandingService.clearCache();
    await DocumentUnderstandingService.buildPromptContext(
      query: '事实来源',
      attachments: [attachment],
      readText: read,
    );

    expect(reads, 2);
  });

  test('path eviction is targeted and the document cache stays bounded',
      () async {
    var firstReads = 0;
    var secondReads = 0;
    final first = MediaAttachment(
      id: 'first',
      type: 'file',
      localPath: '/tmp/first.txt',
      fileName: 'first.txt',
      fileSize: 10,
    );
    final second = MediaAttachment(
      id: 'second',
      type: 'file',
      localPath: '/tmp/second.txt',
      fileName: 'second.txt',
      fileSize: 10,
    );
    await DocumentUnderstandingService.parse(
      first,
      readText: (_) async {
        firstReads++;
        return '第一份文档';
      },
    );
    await DocumentUnderstandingService.parse(
      second,
      readText: (_) async {
        secondReads++;
        return '第二份文档';
      },
    );

    DocumentUnderstandingService.evictPaths([first.localPath]);
    expect(DocumentUnderstandingService.statusFor(first),
        DocumentParseStatus.pending);
    expect(DocumentUnderstandingService.statusFor(second),
        DocumentParseStatus.ready);
    await DocumentUnderstandingService.parse(
      first,
      readText: (_) async {
        firstReads++;
        return '第一份文档';
      },
    );
    await DocumentUnderstandingService.parse(
      second,
      readText: (_) async {
        secondReads++;
        return '第二份文档';
      },
    );
    expect((firstReads, secondReads), (2, 1));

    for (var index = 0;
        index < DocumentUnderstandingService.maxCacheEntries;
        index++) {
      await DocumentUnderstandingService.parse(
        MediaAttachment(
          id: 'bounded-$index',
          type: 'file',
          localPath: '/tmp/bounded-$index.txt',
          fileName: 'bounded-$index.txt',
          fileSize: 1,
        ),
        readText: (_) async => 'x',
      );
    }
    expect(
      DocumentUnderstandingService.cachedDocumentCount,
      DocumentUnderstandingService.maxCacheEntries,
    );
  });
}

Uint8List _zip(Map<String, String> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.add(ArchiveFile.string(entry.key, entry.value));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/features/agentic/tool_request.dart';
import 'package:chat_group/features/ai_governance/model_capability_registry.dart';
import 'package:chat_group/features/chat_group/multimodal_content.dart';
import 'package:chat_group/features/document/document_understanding_service.dart';
import 'package:chat_group/features/document/binary_document_parser.dart';
import 'package:chat_group/features/document/document_page_renderer.dart';
import 'package:chat_group/features/work_mode/agent_decision.dart';
import 'package:chat_group/features/work_mode/work_document_tool.dart';
import 'package:chat_group/features/work_mode/work_task_coordinator.dart';
import 'package:chat_group/features/work_mode/work_tool_registry.dart';
import 'package:chat_group/features/work_mode/workspace_path_policy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

void main() {
  late Directory root;
  late WorkspacePathPolicy pathPolicy;
  final capabilities = ModelCapabilityRegistry();

  setUp(() async {
    root = await Directory.systemTemp.createTemp('work-document-tool-test-');
    pathPolicy = WorkspacePathPolicy(
      authorizedRoots: [root.path],
      isWindows: false,
    );
    DocumentUnderstandingService.clearCache();
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
    DocumentUnderstandingService.clearCache();
  });

  WorkDocumentTool tool({bool vision = false}) => WorkDocumentTool(
        pathPolicy: pathPolicy,
        modelCapability: capabilities.resolve(
          provider: ApiProvider.qwen,
          modelId: vision ? 'qwen-vl-max' : 'qwen-plus',
        ),
      );

  AgentTask task(String request) => AgentTask(
        groupId: 'group-1',
        characterId: 'character-1',
        userRequest: request,
        workModeTask: true,
      );

  Future<WorkToolResult> runTool(
    WorkDocumentTool documentTool,
    String path, {
    String query = '',
    AgentTask? owner,
    Map<String, dynamic> arguments = const {},
  }) {
    final currentTask = owner ?? task(query.isEmpty ? '读取文件' : query);
    return documentTool.execute(
      WorkToolInvocation(
        task: currentTask,
        call: AgentToolCall(
          name: AgentToolName.workspaceDocument,
          arguments: {'path': path, 'query': query, ...arguments},
        ),
        context: WorkToolExecutionContext(task: currentTask),
      ),
    );
  }

  test(
      'reads txt, markdown, json and multiple code formats with relevant chunks',
      () async {
    final files = <String, String>{
      'notes.txt': '无关背景说明。\n\n负责人是小薇。',
      'guide.md': '# 发布\n\n发布日期是 7 月 30 日。',
      'config.json': '{"owner":"小薇","unrelated":"omit"}',
      'sample.dart': 'void main() { print("dart-marker"); }',
      'sample.py': 'print("python-marker")',
      'sample.ts': 'const marker: string = "typescript-marker";',
      'sample.js': 'console.log("javascript-marker");',
    };
    for (final entry in files.entries) {
      await File('${root.path}/${entry.key}').writeAsString(entry.value);
    }

    final notes = await runTool(tool(), '${root.path}/notes.txt', query: '负责人');
    expect(notes.status, WorkToolResultStatus.success);
    expect(notes.data['content'], contains('负责人是小薇'));
    expect(notes.data['content'], isNot(contains('发布日期')));
    expect(notes.message, contains('notes.txt'));
    expect(notes.message, contains('段落'));
    expect(notes.message, isNot(contains(root.path)));

    final relativeTool = WorkDocumentTool(
      pathPolicy: pathPolicy,
      workspaceRoot: root.path,
      modelCapability: capabilities.resolve(
        provider: ApiProvider.qwen,
        modelId: 'qwen-plus',
      ),
    );
    final relative = await runTool(relativeTool, 'notes.txt', query: '负责人');
    expect(relative.status, WorkToolResultStatus.success);
    expect(relative.data['content'], contains('负责人是小薇'));

    final markdown =
        await runTool(tool(), '${root.path}/guide.md', query: '发布日期');
    expect(markdown.status, WorkToolResultStatus.success);
    expect(markdown.data['content'], contains('发布日期是 7 月 30 日'));
    expect(markdown.data['content'], contains('[来源：guide.md'));

    final json =
        await runTool(tool(), '${root.path}/config.json', query: 'owner');
    expect(json.status, WorkToolResultStatus.success);
    expect(json.data['content'], contains('小薇'));

    const markers = {
      'dart': 'dart-marker',
      'py': 'python-marker',
      'ts': 'typescript-marker',
      'js': 'javascript-marker',
    };
    for (final entry in markers.entries) {
      final result = await runTool(
        tool(),
        '${root.path}/sample.${entry.key}',
        query: entry.value,
      );
      expect(result.status, WorkToolResultStatus.success,
          reason: '${entry.key}: ${result.message}');
      expect(result.data['content'], contains(entry.value));
    }
  });

  test('preserves PDF page, DOCX paragraph, and XLSX sheet/cell locations',
      () async {
    final pdf = PdfDocument();
    pdf.pages.add().graphics.drawString(
          'Release date is July 30.',
          PdfStandardFont(PdfFontFamily.helvetica, 12),
          bounds: const Rect.fromLTWH(20, 20, 300, 40),
        );
    final pdfBytes = await pdf.save();
    pdf.dispose();
    final pdfPath = '${root.path}/release.pdf';
    await File(pdfPath).writeAsBytes(pdfBytes);

    final docxPath = '${root.path}/plan.docx';
    await File(docxPath).writeAsBytes(_zip({
      'word/document.xml': '''
        <w:document xmlns:w="word"><w:body>
          <w:p><w:r><w:t>项目负责人是小薇</w:t></w:r></w:p>
          <w:p><w:r><w:t>上线日期是 7 月 30 日</w:t></w:r></w:p>
        </w:body></w:document>
      ''',
    }));

    final xlsxPath = '${root.path}/budget.xlsx';
    await File(xlsxPath).writeAsBytes(_zip({
      'xl/workbook.xml': '''
        <workbook xmlns:r="rel"><sheets>
          <sheet name="预算" r:id="rId1"/>
        </sheets></workbook>
      ''',
      'xl/_rels/workbook.xml.rels': '''
        <Relationships><Relationship Id="rId1"
          Target="worksheets/sheet1.xml"/></Relationships>
      ''',
      'xl/sharedStrings.xml': '<sst><si><t>设计</t></si></sst>',
      'xl/worksheets/sheet1.xml': '''
        <worksheet><sheetData><row r="1">
          <c r="A1" t="s"><v>0</v></c><c r="B1"><v>1200</v></c>
        </row></sheetData></worksheet>
      ''',
    }));

    final pdfResult = await runTool(tool(), pdfPath, query: 'release date');
    expect(pdfResult.status, WorkToolResultStatus.success);
    expect(pdfResult.data['content'], contains('Release date is July 30'));
    expect(pdfResult.message, contains('release.pdf'));
    expect(pdfResult.message, contains('第 1 页'));
    expect(pdfResult.message, isNot(contains(root.path)));

    final docxResult = await runTool(tool(), docxPath, query: '项目负责人');
    expect(docxResult.status, WorkToolResultStatus.success);
    expect(docxResult.data['content'], contains('项目负责人是小薇'));
    expect(
        docxResult.data['path'], await File(docxPath).resolveSymbolicLinks());
    expect(docxResult.data['truncated'], isTrue);
    final complete = await tool().execute(WorkToolInvocation(
        task: task('完整核对'),
        call: AgentToolCall(
            name: AgentToolName.workspaceDocument,
            arguments: {'path': docxPath, 'startChunk': 0}),
        context: WorkToolExecutionContext(task: task('完整核对'))));
    expect(complete.data['chunkStart'], 0);
    expect(complete.data['chunkCount'], complete.data['totalChunkCount']);
    expect(complete.data['truncated'], isFalse);
    expect(docxResult.message, contains('plan.docx'));
    expect(docxResult.message, contains('段落 1'));

    final xlsxResult = await runTool(tool(), xlsxPath, query: '设计预算');
    expect(xlsxResult.status, WorkToolResultStatus.success);
    expect(xlsxResult.data['content'], contains('A1: 设计 | B1: 1200'));
    expect(xlsxResult.message, contains('预算'));
    expect(xlsxResult.message, contains('行 1'));
  });

  test('reads the font declarations used by DOCX render coverage', () {
    final bytes = _zip({
      'word/styles.xml': '''
        <w:styles xmlns:w="word">
          <w:rPr><w:rFonts w:ascii="Aptos" w:eastAsia="Noto Sans CJK SC"/></w:rPr>
        </w:styles>
      ''',
    });

    expect(BinaryDocumentParser.declaredDocxFonts(bytes),
        ['Aptos', 'Noto Sans CJK SC']);
  });

  test('正文显式字体覆盖未使用的样式和编号字体声明', () {
    final bytes = _zip({
      'word/document.xml': '''
        <w:document xmlns:w="word">
          <w:body><w:p><w:r><w:rPr>
            <w:rFonts w:ascii="PingFang SC" w:eastAsia="PingFang SC"/>
          </w:rPr><w:t>正文</w:t></w:r></w:p></w:body>
        </w:document>
      ''',
      'word/styles.xml': '''
        <w:styles xmlns:w="word">
          <w:rPr><w:rFonts w:ascii="Courier"/></w:rPr>
        </w:styles>
      ''',
      'word/numbering.xml': '''
        <w:numbering xmlns:w="word">
          <w:rPr><w:rFonts w:ascii="Symbol"/></w:rPr>
        </w:numbering>
      ''',
    });

    expect(BinaryDocumentParser.declaredDocxFonts(bytes), ['PingFang SC']);
  });

  test('混用直接字体与实际引用样式时同时返回两种正文字体', () {
    final bytes = _zip({
      'word/document.xml': '''
        <w:document xmlns:w="word"><w:body>
          <w:p><w:r><w:rPr>
            <w:rFonts w:ascii="Arial"/>
          </w:rPr><w:t>直接字体</w:t></w:r></w:p>
          <w:p><w:pPr><w:pStyle w:val="MissingStyle"/></w:pPr>
            <w:r><w:t>继承字体</w:t></w:r>
          </w:p>
          <w:p><w:pPr><w:numPr>
            <w:ilvl w:val="0"/><w:numId w:val="7"/>
          </w:numPr></w:pPr><w:r><w:t>编号字体</w:t></w:r></w:p>
        </w:body></w:document>
      ''',
      'word/styles.xml': '''
        <w:styles xmlns:w="word">
          <w:style w:type="paragraph" w:styleId="MissingStyle">
            <w:rPr><w:rFonts w:ascii="ChatGroupMissingFontReview3"/></w:rPr>
          </w:style>
          <w:style w:type="paragraph" w:styleId="UnusedStyle">
            <w:rPr><w:rFonts w:ascii="UnusedFontReview3"/></w:rPr>
          </w:style>
        </w:styles>
      ''',
      'word/numbering.xml': '''
        <w:numbering xmlns:w="word">
          <w:abstractNum w:abstractNumId="42">
            <w:lvl w:ilvl="0"><w:rPr>
              <w:rFonts w:ascii="ChatGroupListFontReview3"/>
            </w:rPr></w:lvl>
          </w:abstractNum>
          <w:abstractNum w:abstractNumId="43">
            <w:lvl w:ilvl="0"><w:rPr>
              <w:rFonts w:ascii="UnusedListFontReview3"/>
            </w:rPr></w:lvl>
          </w:abstractNum>
          <w:num w:numId="7"><w:abstractNumId w:val="42"/></w:num>
          <w:num w:numId="8"><w:abstractNumId w:val="43"/></w:num>
        </w:numbering>
      ''',
    });

    expect(BinaryDocumentParser.declaredDocxFonts(bytes),
        ['Arial', 'ChatGroupListFontReview3', 'ChatGroupMissingFontReview3']);
  });

  test(
      'render returns one candidate page, extractive summary and saved manifest',
      () async {
    final bytes = _zip({
      'word/document.xml': '''
        <w:document xmlns:w="word"><w:body>
          <w:p><w:r><w:t>方案摘要：跨页表格的日期被遮挡。</w:t></w:r></w:p>
        </w:body></w:document>
      ''',
    });
    final path = '${root.path}/candidate.docx';
    await File(path).writeAsBytes(bytes);
    final renderer = _FakeDocumentPageRenderer();
    final savedEvidence = <String, List<int>>{};
    var evidenceNumber = 0;
    final visual = WorkDocumentTool(
      pathPolicy: pathPolicy,
      modelCapability: capabilities.resolve(
        provider: ApiProvider.qwen,
        modelId: 'qwen-vl-max',
      ),
      pageRenderer: renderer,
      writeEvidence: (task, extension, value) async {
        final ref = 'document:$extension:${++evidenceNumber}';
        savedEvidence[ref] = value;
        return ref;
      },
    );

    final result = await runTool(visual, path,
        arguments: {'operation': 'render', 'page': 1});

    expect(result.status, WorkToolResultStatus.success);
    expect(renderer.pages, [1]);
    expect(result.data['pageNumber'], 1);
    expect(result.data['pageCount'], 2);
    final canonicalPath = await File(path).resolveSymbolicLinks();
    expect(result.data['path'], canonicalPath);
    expect(result.data['documentDigest'], sha256.convert(bytes).toString());
    final manifest = result.data['manifest'] as Map;
    expect(manifest['documentPath'], canonicalPath);
    expect(manifest['documentSummary'], contains('跨页表格的日期被遮挡'));
    expect(manifest['summaryKind'], 'extractedTextPreview');
    expect(manifest['renderEngine'], 'fake-boundary-test');
    expect(manifest['fontCoverage']['status'], 'resolved');
    expect(
        savedEvidence.keys, containsAll(['document:png:1', 'document:json:2']));
    expect(savedEvidence['document:json:2'], isNotEmpty);
    final content = result.data['content'] as List;
    expect(content.where((part) => part['type'] == 'image_url'), hasLength(1));
    expect((content.last['image_url'] as Map)['url'],
        startsWith('data:image/png;base64,'));
  });

  test('render refuses missing vision model and an out of range page',
      () async {
    final path = '${root.path}/plan.docx';
    await File(path).writeAsBytes(_zip({
      'word/document.xml':
          '<w:document xmlns:w="word"><w:body><w:p><w:r><w:t>计划</w:t></w:r></w:p></w:body></w:document>',
    }));
    final renderer = _FakeDocumentPageRenderer();
    final current = WorkDocumentTool(
      pathPolicy: pathPolicy,
      modelCapability: capabilities.resolve(
        provider: ApiProvider.qwen,
        modelId: 'qwen-plus',
      ),
      pageRenderer: renderer,
    );
    final noVision = await runTool(current, path,
        arguments: {'operation': 'render', 'page': 1});
    expect(noVision.failureCode, 'visionModelRequired');
    expect(renderer.pages, isEmpty);

    final vision = WorkDocumentTool(
      pathPolicy: pathPolicy,
      modelCapability: capabilities.resolve(
        provider: ApiProvider.qwen,
        modelId: 'qwen-vl-max',
      ),
      pageRenderer: renderer,
    );
    final invalid = await runTool(vision, path,
        arguments: {'operation': 'render', 'page': 0});
    expect(invalid.failureCode, 'invalidInput');
    expect(renderer.pages, isEmpty);
  });

  test('retains size limits and reports damaged documents without hanging',
      () async {
    final oversizedPath = '${root.path}/large.txt';
    await File(oversizedPath).writeAsBytes(
      Uint8List(DocumentUnderstandingService.maxDocumentBytes + 1),
    );
    final oversized = await runTool(tool(), oversizedPath);
    expect(oversized.status, WorkToolResultStatus.failed);
    expect(oversized.failureCode, 'documentTooLarge');
    expect(oversized.data['unsupportedMedia'], isFalse);

    final damagedPath = '${root.path}/broken.json';
    await File(damagedPath).writeAsString('{broken');
    final damaged = await runTool(tool(), damagedPath, query: 'broken');
    expect(damaged.status, WorkToolResultStatus.failed);
    expect(damaged.failureCode, 'documentParseFailed');
    expect(damaged.message, contains('json'));
  });

  test('rejects an Open XML entry whose declared expansion exceeds the bound',
      () {
    final bytes = _zip({'word/document.xml': '<w:document/>'});
    final centralDirectory =
        _signatureIndex(bytes, const [0x50, 0x4b, 0x01, 0x02]);
    expect(centralDirectory, greaterThanOrEqualTo(0));
    // The central-directory uncompressed-size field starts 24 bytes after
    // the signature. This changes only the hostile declaration; no large
    // fixture needs to be allocated or decompressed by the test.
    const declaredTooLarge = 8 * 1024 * 1024 + 1;
    for (var byte = 0; byte < 4; byte++) {
      bytes[centralDirectory + 24 + byte] =
          (declaredTooLarge >> (byte * 8)) & 0xff;
    }

    expect(
      () => BinaryDocumentParser.parse('docx', bytes),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects paths outside WorkspacePathPolicy before reading', () async {
    final outside =
        await Directory.systemTemp.createTemp('work-document-outside-');
    addTearDown(() async {
      if (await outside.exists()) await outside.delete(recursive: true);
    });
    final outsidePath = '${outside.path}/secret.txt';
    await File(outsidePath).writeAsString('must not be read');

    final result = await runTool(tool(), outsidePath, query: 'secret');
    expect(result.status, WorkToolResultStatus.pathRejected);
    expect(result.failureCode, 'pathRejected');
    expect(result.data['content'], isNull);
  });

  test('allows only the exact referenced chat attachment outside workspace',
      () async {
    final outside =
        await Directory.systemTemp.createTemp('work-document-attachment-');
    addTearDown(() async {
      if (await outside.exists()) await outside.delete(recursive: true);
    });
    final imagePath = '${outside.path}/upload.png';
    await File(imagePath).writeAsBytes([137, 80, 78, 71]);
    final attachmentTool = WorkDocumentTool(
      pathPolicy: pathPolicy,
      modelCapability: capabilities.resolve(
        provider: ApiProvider.qwen,
        modelId: 'qwen-vl-max',
      ),
      attachmentPaths: {imagePath},
    );

    final result = await runTool(attachmentTool, imagePath, query: '分析上传图片');
    expect(result.status, WorkToolResultStatus.success);
    expect(result.data['content'], isA<List>());

    final unlisted = await runTool(attachmentTool, '${outside.path}/other.png');
    expect(unlisted.status, WorkToolResultStatus.pathRejected);
  });

  test('blocks sensitive files until the exact read is approved', () async {
    final path = '${root.path}/.env';
    await File(path).writeAsString('TOKEN=must-not-leak');
    final sensitiveTool = WorkDocumentTool(
      pathPolicy: pathPolicy,
      modelCapability: capabilities.resolve(
        provider: ApiProvider.qwen,
        modelId: 'qwen-plus',
      ),
      isSensitivePath: (_) => true,
    );

    final result = await runTool(sensitiveTool, path, query: 'TOKEN');
    expect(result.status, WorkToolResultStatus.waitingForApproval);
    expect(result.failureCode, 'userActionRequired');
    expect(result.data['requiresApproval'], isTrue);
    expect(result.data['sensitive'], isTrue);
    expect(result.data['content'], isNull);
  });

  test('sends images only when the current role model supports vision',
      () async {
    final imagePath = '${root.path}/diagram.png';
    await File(imagePath).writeAsBytes(Uint8List.fromList([137, 80, 78, 71]));

    final vision = await runTool(tool(vision: true), imagePath, query: '分析图');
    expect(vision.status, WorkToolResultStatus.success);
    expect(vision.data['content'], isA<List>());
    final parts = vision.data['content'] as List;
    expect(parts.any((part) => part['type'] == 'image_url'), isTrue);
    expect(vision.message, contains('diagram.png'));
    expect(vision.message, isNot(contains(root.path)));

    final nonVision = await runTool(tool(), imagePath, query: '分析图');
    expect(nonVision.status, WorkToolResultStatus.paused);
    expect(nonVision.failureCode, 'visionModelRequired');
    expect(nonVision.data['requiresModelSelection'], isTrue);
    expect(nonVision.data['content'], isNull);
    expect(nonVision.message, contains('不支持图片输入'));
    expect(nonVision.message, contains('不会自动切换'));
  });

  test('bounds bytes returned by an injected image reader', () async {
    final imagePath = '${root.path}/injected.png';
    await File(imagePath).writeAsBytes([137, 80, 78, 71]);
    final injected = WorkDocumentTool(
      pathPolicy: pathPolicy,
      modelCapability: capabilities.resolve(
        provider: ApiProvider.qwen,
        modelId: 'qwen-vl-max',
      ),
      readBytes: (_) async => Uint8List(defaultMaxInlineImageBytes + 1),
    );

    final result = await runTool(injected, imagePath, query: '分析图');

    expect(result.status, WorkToolResultStatus.failed);
    expect(result.failureCode, 'imageReadFailed');
    expect(result.data['content'], isNull);
  });

  test('keeps the MIME type for HEIC, HEIF, and AVIF images', () async {
    for (final extension in const ['heic', 'heif', 'avif']) {
      final path = '${root.path}/diagram.$extension';
      await File(path).writeAsBytes(Uint8List.fromList([1, 2, 3, 4]));

      final result = await runTool(tool(vision: true), path, query: '分析图');
      expect(result.status, WorkToolResultStatus.success,
          reason: '$extension: ${result.message}');
      final parts = result.data['content'] as List;
      final imagePart = parts.firstWhere(
        (part) => part['type'] == 'image_url',
      ) as Map;
      expect(
        (imagePart['image_url'] as Map)['url'],
        startsWith('data:image/$extension;base64,'),
      );
    }
  });

  test('returns structured unsupportedMedia for audio and video', () async {
    final audioPath = '${root.path}/voice.mp3';
    final videoPath = '${root.path}/clip.mp4';
    await File(audioPath).writeAsBytes([1, 2, 3]);
    await File(videoPath).writeAsBytes([1, 2, 3]);

    for (final path in [audioPath, videoPath]) {
      final result = await runTool(tool(), path, query: '分析');
      expect(result.status, WorkToolResultStatus.failed);
      expect(result.failureCode, 'unsupportedMedia');
      expect(result.data['unsupportedMedia'], isTrue);
      expect(result.data['content'], isNull);
      expect(result.message, contains('不支持'));
    }
  });

  test('cancellation stops document work before model content is returned',
      () async {
    final path = '${root.path}/cancelled.md';
    await File(path).writeAsString('不会返回');
    final currentTask = task('读取');
    final cancellation = WorkTaskCancellation()..cancel();
    final result = await tool().execute(
      WorkToolInvocation(
        task: currentTask,
        call: AgentToolCall(
          name: AgentToolName.workspaceDocument,
          arguments: {'path': path, 'query': '不会'},
        ),
        context: WorkToolExecutionContext(
          task: currentTask,
          cancellation: cancellation,
        ),
      ),
    );
    expect(result.status, WorkToolResultStatus.paused);
    expect(result.data['content'], isNull);
  });

  test('registers the document tool as read-only and validates its schema', () {
    final registry = WorkToolRegistry(definitions: [
      WorkDocumentTool.definition(
        pathPolicy: pathPolicy,
        modelCapability: capabilities.resolve(
          provider: ApiProvider.qwen,
          modelId: 'qwen-plus',
        ),
      ),
    ]);
    final definition = registry.definitionFor(AgentToolName.workspaceDocument);
    expect(definition, isNotNull);
    expect(definition!.isReadOnly, isTrue);
    expect(
      registry
          .validate(AgentToolCall(
            name: AgentToolName.workspaceDocument,
            arguments: {'path': '${root.path}/notes.txt'},
          ))
          .isValid,
      isTrue,
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

int _signatureIndex(Uint8List bytes, List<int> signature) {
  for (var index = 0; index <= bytes.length - signature.length; index++) {
    var matches = true;
    for (var offset = 0; offset < signature.length; offset++) {
      if (bytes[index + offset] != signature[offset]) {
        matches = false;
        break;
      }
    }
    if (matches) return index;
  }
  return -1;
}

class _FakeDocumentPageRenderer extends DocumentPageRenderer {
  final pages = <int>[];

  @override
  Future<RenderedDocumentPage> render({
    required File source,
    required int page,
    required bool Function() isCancelled,
  }) async {
    pages.add(page);
    final bytes = await source.readAsBytes();
    return RenderedDocumentPage(
      png: Uint8List.fromList([137, 80, 78, 71]),
      manifest: {
        'schemaVersion': 1,
        'fileName': source.uri.pathSegments.last,
        'documentSha256': sha256.convert(bytes).toString(),
        'format': 'docx',
        'pageNumber': page,
        'pageCount': 2,
        'renderEngine': 'fake-boundary-test',
        'fontCoverage': {'status': 'resolved'},
      },
    );
  }
}

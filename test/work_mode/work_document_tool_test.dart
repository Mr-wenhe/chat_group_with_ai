import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:archive/archive.dart';
import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/features/agentic/tool_request.dart';
import 'package:chat_group/features/ai_governance/model_capability_registry.dart';
import 'package:chat_group/features/chat_group/multimodal_content.dart';
import 'package:chat_group/features/document/document_understanding_service.dart';
import 'package:chat_group/features/document/binary_document_parser.dart';
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
  }) {
    final currentTask = owner ?? task(query.isEmpty ? '读取文件' : query);
    return documentTool.execute(
      WorkToolInvocation(
        task: currentTask,
        call: AgentToolCall(
          name: AgentToolName.workspaceDocument,
          arguments: {'path': path, 'query': query},
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
    expect(docxResult.message, contains('plan.docx'));
    expect(docxResult.message, contains('段落 1'));

    final xlsxResult = await runTool(tool(), xlsxPath, query: '设计预算');
    expect(xlsxResult.status, WorkToolResultStatus.success);
    expect(xlsxResult.data['content'], contains('A1: 设计 | B1: 1200'));
    expect(xlsxResult.message, contains('预算'));
    expect(xlsxResult.message, contains('行 1'));
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

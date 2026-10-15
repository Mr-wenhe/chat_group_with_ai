import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/features/document/document_page_renderer.dart';
import 'package:chat_group/features/agentic/tool_request.dart';
import 'package:chat_group/features/ai_governance/model_capability_registry.dart';
import 'package:chat_group/features/work_mode/agent_decision.dart';
import 'package:chat_group/features/work_mode/work_document_tool.dart';
import 'package:chat_group/features/work_mode/work_tool_registry.dart';
import 'package:chat_group/features/work_mode/workspace_path_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const sources = {
    'before-docx': 'review-before.docx',
    'after-docx': 'review-after.docx',
    'before-pdf': 'review-before.pdf',
    'after-pdf': 'review-after.pdf',
  };

  for (final entry in sources.entries) {
    test(
      'P3 renders every ${entry.key} page with verified fonts',
      () async {
        final generated = Directory(
          '${Directory.current.path}/docs/autonomous_group_work/'
          'p3-evidence/generated',
        );
        final file = File('${generated.path}/${entry.value}');
        expect(await file.exists(), isTrue, reason: file.path);

        var activePage = 0;
        final evidence = Directory('${generated.path}/tool-render');
        await evidence.create(recursive: true);
        final capability = ModelCapabilityRegistry().resolve(
          provider: ApiProvider.qwen,
          modelId: 'qwen-vl-max',
        );
        final task = AgentTask(
          groupId: 'p3-document-review',
          characterId: 'visual-reviewer',
          userRequest: '逐页检查修复前后文档的排版与字形。',
          workModeTask: true,
        );
        final tool = WorkDocumentTool(
          pathPolicy: WorkspacePathPolicy(authorizedRoots: [generated.path]),
          workspaceRoot: generated.path,
          modelCapability: capability,
          writeEvidence: (owner, extension, bytes) async {
            final directory = Directory('${evidence.path}/${entry.key}');
            await directory.create(recursive: true);
            final name = 'page-$activePage.$extension';
            await File('${directory.path}/$name')
                .writeAsBytes(bytes, flush: true);
            return 'tool-render/${entry.key}/$name';
          },
        );

        Future<Map<String, dynamic>> render(int page) async {
          activePage = page;
          final result = await tool.execute(WorkToolInvocation(
            task: task,
            call: AgentToolCall(
              name: AgentToolName.workspaceDocument,
              arguments: {
                'path': file.path,
                'operation': 'render',
                'page': page,
              },
            ),
            context: WorkToolExecutionContext(task: task),
          ));
          expect(result.status, WorkToolResultStatus.success,
              reason: '${entry.key} page $page: ${result.message}');
          final manifest =
              (result.data['manifest'] as Map).cast<String, dynamic>();
          expect(manifest['pageNumber'], page);
          expect(manifest['imageWidthLimit'], 1600);
          expect(manifest['renderEngine'], isNotEmpty);
          expect(manifest['popplerVersion'], isNotEmpty);
          if (entry.key.endsWith('docx')) {
            expect(manifest['libreOfficeVersion'], isNotEmpty);
          }
          expect(manifest['fontCoverage']['status'], 'resolved',
              reason: '${entry.key} page $page: ${manifest['fontCoverage']}');
          final content = (result.data['content'] as List)
              .whereType<Map>()
              .where((item) => item['type'] == 'image_url')
              .toList();
          expect(content, hasLength(1));
          final uri = (content.single['image_url'] as Map)['url'] as String;
          expect(uri, startsWith('data:image/png;base64,'));
          expect(base64Decode(uri.split(',').last), isNotEmpty);
          expect(result.data['imageRef'],
              'tool-render/${entry.key}/page-$page.png');
          expect(result.data['manifestRef'],
              'tool-render/${entry.key}/page-$page.json');
          return manifest;
        }

        final firstPage = await render(1);
        final pageCount = firstPage['pageCount'] as int;
        expect(pageCount, greaterThanOrEqualTo(3));
        for (var page = 2; page <= pageCount; page++) {
          await render(page);
        }
      },
      skip: !Platform.isMacOS,
      timeout: const Timeout(Duration(seconds: 30)),
    );
  }

  test(
    'missing DOCX run font cannot be reported as resolved after renderer substitution',
    () async {
      const missingFont = 'ChatGroupMissingFontReview99999';
      final source = await File(
        '${Directory.current.path}/docs/autonomous_group_work/'
        'p3-evidence/generated/review-before.docx',
      ).readAsBytes();
      final input = _replaceDocumentFont(source, missingFont);
      final directory = await Directory.systemTemp
          .createTemp('chat-group-missing-source-font-');
      try {
        final file = File('${directory.path}/missing-font.docx');
        await file.writeAsBytes(input, flush: true);
        final rendered = await const DocumentPageRenderer().render(
          source: file,
          page: 1,
          isCancelled: () => false,
        );
        final fonts = rendered.manifest['fontCoverage'] as Map;
        expect(fonts['sourceFonts'], contains(missingFont));
        expect(fonts['status'], isNot('resolved'));
      } finally {
        await directory.delete(recursive: true);
      }
    },
    skip: !Platform.isMacOS,
    timeout: const Timeout(Duration(seconds: 30)),
  );
}

Uint8List _replaceDocumentFont(Uint8List source, String replacement) {
  final archive = ZipDecoder().decodeBytes(source);
  final updated = Archive();
  for (final file in archive.files) {
    final content = file.content as List<int>;
    final bytes = file.name == 'word/document.xml'
        ? utf8
            .encode(utf8.decode(content).replaceAll('PingFang SC', replacement))
        : content;
    updated.addFile(ArchiveFile(file.name, bytes.length, bytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(updated));
}

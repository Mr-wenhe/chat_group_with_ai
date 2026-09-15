import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/features/work_mode/work_artifact_delivery_guard.dart';
import 'package:chat_group/features/work_mode/work_mode_policy.dart';
import 'package:chat_group/features/work_mode/workspace_path_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('source creation without a real artifact fails explicitly', () {
    const request = '请生成一个可运行的 Python 脚本 script.py';

    expect(
      WorkArtifactDeliveryGuard.requiresSourceArtifact(request),
      isTrue,
    );
    expect(
      WorkArtifactDeliveryGuard.failureFor(
        request: request,
        hasReadableArtifact: false,
      ),
      WorkArtifactDeliveryGuard.missingArtifactMessage,
    );
  });

  test('source review without a write request is not treated as delivery', () {
    const request = '请分析并解释现有 Python 脚本的错误';

    expect(
      WorkArtifactDeliveryGuard.requiresSourceArtifact(request),
      isFalse,
    );
    expect(
      WorkArtifactDeliveryGuard.failureFor(
        request: request,
        hasReadableArtifact: false,
      ),
      isNull,
    );
  });

  test('ordinary text containing password is not misclassified as a file', () {
    expect(
      WorkArtifactDeliveryGuard.requiresFileArtifact(
        '生成一个 password 提示并在聊天中说明',
      ),
      isFalse,
    );
  });

  test('Markdown document creation without a real artifact fails explicitly',
      () {
    const request = '帮我生成一份MD文档，记录未来7天的天气';

    expect(
      WorkArtifactDeliveryGuard.requiresFileArtifact(request),
      isTrue,
    );
    expect(
      WorkArtifactDeliveryGuard.failureFor(
        request: request,
        hasReadableArtifact: false,
      ),
      WorkArtifactDeliveryGuard.missingArtifactMessage,
    );
  });

  test('Markdown to Word conversion is a strict DOCX delivery request', () {
    const request = '把 proposal.md 转换成 Word 并保存到桌面';

    expect(
      WorkArtifactDeliveryGuard.requiresDocxArtifact(request),
      isTrue,
    );
    expect(
      WorkArtifactDeliveryGuard.failureFor(
        request: request,
        hasReadableArtifact: false,
      ),
      WorkArtifactDeliveryGuard.docxContractMessage,
    );
  });

  test('durable Word contract survives a terse execution continuation', () {
    expect(
      WorkArtifactDeliveryGuard.requiresDocxArtifact(
        '继续执行',
        contractFormat: 'docx',
      ),
      isTrue,
    );
    expect(
      WorkArtifactDeliveryGuard.requiresDocxArtifact(
        '请查看现有 Word 文档',
        contractFormat: 'docx',
      ),
      isFalse,
    );
    expect(
      WorkArtifactDeliveryGuard.failureFor(
        request: '继续执行',
        contractFormat: 'docx',
        hasReadableArtifact: false,
      ),
      WorkArtifactDeliveryGuard.docxContractMessage,
    );
  });

  test('a readable source artifact allows completion', () {
    const request = '请把这个 TypeScript 文件修复并保存';

    expect(
      WorkArtifactDeliveryGuard.failureFor(
        request: request,
        hasReadableArtifact: true,
      ),
      isNull,
    );
  });

  test('fresh minimal DOCX passes the real Word contract', () async {
    final root = await Directory.systemTemp.createTemp('s6-docx-');
    addTearDown(() => root.delete(recursive: true));
    final path = '${root.path}/report.docx';
    await File(path).writeAsBytes(_minimalDocx('项目方案正文'));
    final task = _wordTask(path, root.path);

    final result = await WorkArtifactDeliveryGuard.validateTask(
      task: task,
      pathPolicy: WorkspacePathPolicy(authorizedRoots: [root.path]),
    );

    expect(result.valid, isTrue, reason: result.message);
    expect(result.path, endsWith('/report.docx'));
  });

  test('rejects fake Word namespace and missing OPC root relationship',
      () async {
    final root = await Directory.systemTemp.createTemp('invalid-opc-');
    addTearDown(() => root.delete(recursive: true));
    final path = '${root.path}/report.docx';
    for (final bytes in [
      _minimalDocx('正文', validNamespace: false),
      _minimalDocx('正文', rootRelationship: false)
    ]) {
      await File(path).writeAsBytes(bytes);
      final result = await WorkArtifactDeliveryGuard.validateTask(
          task: _wordTask(path, root.path),
          pathPolicy: WorkspacePathPolicy(authorizedRoots: [root.path]));
      expect(result.valid, isFalse);
    }
  });

  test(
      'separate sections need not repeat literal natural language instructions',
      () async {
    final root = await Directory.systemTemp.createTemp('semantic-docx-');
    addTearDown(() => root.delete(recursive: true));
    final path = '${root.path}/report.docx';
    await File(path).writeAsBytes(_minimalDocx('背景：现状。目标：预期结果。'));
    final task = _wordTask(path, root.path)
      ..userRequest = '生成 Word，内容包括背景和目标，最后由 @产品经理 输出';
    final result = await WorkArtifactDeliveryGuard.validateTask(
        task: task,
        pathPolicy: WorkspacePathPolicy(authorizedRoots: [root.path]));
    expect(result.valid, isTrue, reason: result.message);
  });

  test('ZIP-looking text is not accepted as a DOCX', () async {
    final root = await Directory.systemTemp.createTemp('s6-fake-docx-');
    addTearDown(() => root.delete(recursive: true));
    final path = '${root.path}/report.docx';
    await File(path)
        .writeAsBytes(Uint8List.fromList(<int>[0x50, 0x4b, 0x03, 0x04]));
    final result = await WorkArtifactDeliveryGuard.validateTask(
      task: _wordTask(path, root.path),
      pathPolicy: WorkspacePathPolicy(authorizedRoots: [root.path]),
    );

    expect(result.valid, isFalse);
    expect(result.code, 'docxInvalidOrStale');
  });

  test('DOCX without a non-empty body is rejected', () async {
    final root = await Directory.systemTemp.createTemp('s6-empty-docx-');
    addTearDown(() => root.delete(recursive: true));
    final path = '${root.path}/report.docx';
    await File(path).writeAsBytes(_minimalDocx(''));
    final result = await WorkArtifactDeliveryGuard.validateTask(
      task: _wordTask(path, root.path),
      pathPolicy: WorkspacePathPolicy(authorizedRoots: [root.path]),
    );

    expect(result.valid, isFalse);
    expect(result.code, 'docxInvalidOrStale');
  });

  test('stale DOCX, wrong directory and Markdown source cannot pass', () async {
    final root = await Directory.systemTemp.createTemp('s6-path-');
    final other = await Directory.systemTemp.createTemp('s6-other-');
    addTearDown(() async {
      await root.delete(recursive: true);
      await other.delete(recursive: true);
    });
    final stale = '${root.path}/stale.docx';
    await File(stale).writeAsBytes(_minimalDocx('旧正文'));
    final staleTime = DateTime.now().subtract(const Duration(minutes: 5));
    await File(stale).setLastModified(staleTime);
    final staleTask = _wordTask(stale, root.path);
    expect(
      (await WorkArtifactDeliveryGuard.validateTask(
        task: staleTask,
        pathPolicy: WorkspacePathPolicy(authorizedRoots: [root.path]),
      ))
          .valid,
      isFalse,
    );

    final wrong = '${other.path}/report.docx';
    await File(wrong).writeAsBytes(_minimalDocx('正文'));
    final wrongTask = _wordTask(wrong, root.path);
    expect(
      (await WorkArtifactDeliveryGuard.validateTask(
        task: wrongTask,
        pathPolicy: WorkspacePathPolicy(authorizedRoots: [root.path]),
      ))
          .valid,
      isFalse,
    );

    final markdown = '${root.path}/report.md';
    await File(markdown).writeAsString('# 正文');
    final markdownTask = _wordTask(markdown, root.path);
    expect(
      (await WorkArtifactDeliveryGuard.validateTask(
        task: markdownTask,
        pathPolicy: WorkspacePathPolicy(authorizedRoots: [root.path]),
      ))
          .valid,
      isFalse,
    );
  });

  test('explicit target location is matched after normalization', () async {
    final root = await Directory.systemTemp.createTemp('s6-location-');
    addTearDown(() => root.delete(recursive: true));
    final path = '${root.path}/expected.docx';
    await File(path).writeAsBytes(_minimalDocx('核心正文'));
    final task = _wordTask(path, root.path, location: 'other.docx');
    final result = await WorkArtifactDeliveryGuard.validateTask(
      task: task,
      pathPolicy: WorkspacePathPolicy(authorizedRoots: [root.path]),
    );
    expect(result.valid, isFalse);
  });

  test('relative target location is resolved from the task workspace',
      () async {
    final root = await Directory.systemTemp.createTemp('s6-workspace-root-');
    final workspace = Directory('${root.path}/conversations/group-s6');
    await workspace.create(recursive: true);
    addTearDown(() => root.delete(recursive: true));
    final path = '${workspace.path}/report.docx';
    await File(path).writeAsBytes(_minimalDocx('核心正文'));

    final task = _wordTask(path, root.path, location: 'report.docx');
    final result = await WorkArtifactDeliveryGuard.validateTask(
      task: task,
      pathPolicy: WorkspacePathPolicy(authorizedRoots: [root.path]),
      workspaceRoot: workspace.path,
    );

    expect(result.valid, isTrue, reason: result.message);
    expect(result.path, endsWith('/report.docx'));
  });

  test('desktop-prefixed target is resolved relative to the desktop workspace',
      () async {
    final root = await Directory.systemTemp.createTemp('s6-desktop-root-');
    final desktop = Directory('${root.path}/Desktop');
    await desktop.create(recursive: true);
    addTearDown(() => root.delete(recursive: true));
    final path = '${desktop.path}/需求文档.docx';
    await File(path).writeAsBytes(_minimalDocx('核心正文'));

    final task = _wordTask(path, desktop.path, location: '需求文档.docx');
    final result = await WorkArtifactDeliveryGuard.validateTask(
      task: task,
      pathPolicy: WorkspacePathPolicy(authorizedRoots: [root.path]),
      workspaceRoot: desktop.path,
    );

    expect(result.valid, isTrue, reason: result.message);
    expect(result.path, endsWith('/Desktop/需求文档.docx'));
  });

  test('legacy desktop-prefixed contract remains compatible', () async {
    final root = await Directory.systemTemp.createTemp('s6-desktop-legacy-');
    final desktop = Directory('${root.path}/Desktop');
    await desktop.create(recursive: true);
    addTearDown(() => root.delete(recursive: true));
    final path = '${desktop.path}/需求文档.docx';
    await File(path).writeAsBytes(_minimalDocx('核心正文'));

    final task = _wordTask(path, desktop.path, location: '桌面/需求文档.docx');
    final result = await WorkArtifactDeliveryGuard.validateTask(
      task: task,
      pathPolicy: WorkspacePathPolicy(authorizedRoots: [root.path]),
      workspaceRoot: desktop.path,
    );

    expect(result.valid, isTrue, reason: result.message);
  });

  test('absolute target location follows macOS /var path aliases', () async {
    final root = await Directory.systemTemp.createTemp('s6-absolute-alias-');
    addTearDown(() => root.delete(recursive: true));
    final path = '${root.path}/report.docx';
    await File(path).writeAsBytes(_minimalDocx('核心正文'));
    final alias = root.path.startsWith('/var/')
        ? root.path.replaceFirst('/var/', '/private/var/')
        : root.path.replaceFirst('/private/var/', '/var/');
    final result = await WorkArtifactDeliveryGuard.validateTask(
      task: _wordTask(path, root.path, location: '$alias/report.docx'),
      pathPolicy: WorkspacePathPolicy(authorizedRoots: [root.path]),
    );

    expect(result.valid, isTrue, reason: result.message);
  });

  test('paragraphs outside the Word body do not satisfy delivery', () async {
    final root = await Directory.systemTemp.createTemp('s6-docx-body-');
    addTearDown(() => root.delete(recursive: true));
    final path = '${root.path}/outside.docx';
    await File(path).writeAsBytes(_docxWithOutsideParagraph());

    final result = await WorkArtifactDeliveryGuard.validateTask(
      task: _wordTask(path, root.path),
      pathPolicy: WorkspacePathPolicy(authorizedRoots: [root.path]),
    );

    expect(result.valid, isFalse);
    expect(result.code, 'docxInvalidOrStale');
  });

  test('Word skill and policy refuse automatic Markdown downgrade', () {
    final policy = WorkModePolicy.planningContext(_character());
    expect(policy, contains('禁止自动改为 .md'));
    expect(policy, contains('自动授权'));
    expect(policy, contains('保留原任务检查点'));
  });
}

AgentTask _wordTask(String path, String root, {String? location}) {
  final now = DateTime.now();
  return AgentTask(
    groupId: 'group-s6',
    characterId: 'executor',
    userRequest: '生成一份 Word 文档并保存到 ${location ?? 'report.docx'}',
    workModeTask: true,
    createdAt: now,
    startedAt: now.subtract(const Duration(milliseconds: 200)),
    lastArtifactPaths: [path],
    executionStateJson: location == null
        ? ''
        : '{"discussionState":{"schemaVersion":1,"conversationId":"group-s6",'
            '"phase":"ready","requestRevision":1,"coordinatorId":"c",'
            '"executorId":"executor","candidateCharacterIds":["executor"],'
            '"participants":[],"round":1,"understandingPercent":100,'
            '"understandingEvidence":[],"openQuestions":[],"blockers":[],'
            '"deliverableContract":{"deliverableType":"document","format":"docx",'
            '"location":"$location","contentScope":"生成 Word 文档","explicitExecutorId":"executor",'
            '"revisionTarget":"","requestRevision":1},"decisionSummary":"ok"}}',
  );
}

Uint8List _minimalDocx(String text,
    {bool validNamespace = true, bool rootRelationship = true}) {
  final escaped = text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
  final archive = Archive();
  if (rootRelationship) {
    archive.add(ArchiveFile.string(
        '_rels/.rels',
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
            '</Relationships>'));
  }
  archive
    ..add(ArchiveFile.string(
      '[Content_Types].xml',
      '<?xml version="1.0" encoding="UTF-8"?>'
          '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
          '<Override PartName="/word/document.xml" '
          'ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
          '</Types>',
    ))
    ..add(ArchiveFile.string(
      'word/document.xml',
      '<w:document xmlns:w="${validNamespace ? 'http://schemas.openxmlformats.org/wordprocessingml/2006/main' : 'word'}"><w:body><w:p>'
          '${escaped.isEmpty ? '' : '<w:r><w:t>$escaped</w:t></w:r>'}'
          '</w:p></w:body></w:document>',
    ));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Uint8List _docxWithOutsideParagraph() {
  final archive = Archive()
    ..add(ArchiveFile.string(
      '[Content_Types].xml',
      '<?xml version="1.0" encoding="UTF-8"?>'
          '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
          '<Override PartName="/word/document.xml" '
          'ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
          '</Types>',
    ))
    ..add(ArchiveFile.string(
      'word/document.xml',
      '<w:document xmlns:w="word"><w:p><w:r><w:t>错误位置正文</w:t></w:r></w:p>'
          '<w:body/></w:document>',
    ));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

// Only role metadata is used by WorkModePolicy in this test.
AICharacter _character() => AICharacter(
      name: '执行人',
      avatar: '',
      age: 30,
      role: '文档执行人',
      personalityTags: const [],
      systemPrompt: '按审批流程执行',
      apiKey: '',
      apiProvider: 'custom',
    );

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/features/work_mode/work_artifact_delivery_guard.dart';
import 'package:chat_group/features/work_mode/work_artifact_delivery_notice.dart';
import 'package:chat_group/features/work_mode/work_discussion_state.dart';
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

  test('declared output formats drive which files can be delivered', () {
    // 回归：请求点名了格式时，中间文件不能顶替交付物——“生成一份 xlsx 排名表”
    // 曾在其生成脚本写好后就被判为完成。
    AgentTask taskFor(String request) => AgentTask(
          id: 'format-task',
          groupId: 'format-group',
          characterId: 'worker',
          userRequest: request,
          workModeTask: true,
        );

    expect(
      WorkArtifactDeliveryGuard.declaredOutputFormats(
        taskFor('从网上取数并生成一份 xlsx 大模型排名表'),
      ),
      equals(<String>{'xlsx'}),
    );
    expect(
      WorkArtifactDeliveryGuard.declaredOutputFormats(
          taskFor('生成 ranking.PDF')),
      equals(<String>{'pdf'}),
    );
    expect(
      WorkArtifactDeliveryGuard.declaredOutputFormats(
        taskFor('把报告转成 Word 文档'),
      ),
      equals(<String>{'docx'}),
    );
    expect(
      WorkArtifactDeliveryGuard.declaredOutputFormats(taskFor('生成 report.md')),
      equals(<String>{'md'}),
    );
    // 版本号不是格式：`v2.10` 曾被当成格式 "10"，从而拒绝真正的交付物。
    expect(
      WorkArtifactDeliveryGuard.declaredOutputFormats(taskFor('生成 v2.10 版的报告')),
      isEmpty,
    );
    expect(
      WorkArtifactDeliveryGuard.declaredOutputFormats(
        taskFor('生成本月 3.15 促销分析报告'),
      ),
      isEmpty,
    );
    // 没有点名格式的普通任务不限制交付范围。
    expect(
      WorkArtifactDeliveryGuard.declaredOutputFormats(
        taskFor('整理一下工作区里的文件'),
      ),
      isEmpty,
    );
  });

  test('a durable contract format maps to the real file extension', () {
    // 回归：讨论契约写的是 `markdown`，而交付物是 `report.md`。契约权威且必须
    // 归一化，否则合法产物会被判为 stale、整个任务交付失败。
    AgentTask contracted(String format) {
      final state = WorkDiscussionState(
        conversationId: 'contract-format-group',
        phase: WorkDiscussionPhase.ready,
        requestRevision: 1,
        executorId: 'worker',
        candidateCharacterIds: const ['worker'],
        participants: const [WorkDiscussionParticipant(characterId: 'worker')],
        round: 1,
        understandingPercent: 100,
        understandingEvidence: const ['已确认交付合同。'],
        blockers: const [],
        deliverableContract: {
          'deliverableType': 'document',
          'format': format,
          'location': 'workspace',
          'contentScope': '完成任务',
          'explicitExecutorId': 'worker',
          'revisionTarget': '',
          'requestRevision': 1,
        },
      );
      return AgentTask(
        id: 'contract-format-task',
        groupId: 'contract-format-group',
        characterId: 'worker',
        userRequest: '生成一份报告',
        workModeTask: true,
        executionStateJson: jsonEncode({
          WorkDiscussionState.jsonKey: state.toJson(),
        }),
      );
    }

    expect(
      WorkArtifactDeliveryGuard.declaredOutputFormats(contracted('markdown')),
      equals(<String>{'md'}),
    );
    expect(
      WorkArtifactDeliveryGuard.declaredOutputFormats(contracted('html')),
      equals(<String>{'html'}),
    );
    expect(
      WorkArtifactDeliveryGuard.declaredOutputFormats(
          contracted('unspecified')),
      isEmpty,
    );
  });

  test('spreadsheet, slide deck and PDF requests are file deliverables', () {
    // 回归：扩展名白名单漏了 Office/PDF，导致“生成一份 xlsx 排名表”不算产物
    // 任务，跳过完成校验（而 docx 算）。三者都必须建立产物契约。
    const requests = <String>[
      '从网上取数并生成一份 xlsx 大模型排名表',
      '生成一份 xlsx 文件',
      '制作一个 pptx 汇报',
      '导出一份报告 pdf',
      '生成 ranking.xlsx',
      '生成 deck.pptx',
      '生成 report.pdf',
    ];

    for (final request in requests) {
      expect(
        WorkArtifactDeliveryGuard.requiresFileArtifact(request),
        isTrue,
        reason: request,
      );
      expect(
        WorkArtifactDeliveryGuard.failureFor(
          request: request,
          hasReadableArtifact: false,
        ),
        WorkArtifactDeliveryGuard.missingArtifactMessage,
        reason: request,
      );
    }
  });

  test('reading an existing spreadsheet is not a delivery request', () {
    // 反向：只读/分析既有表格不得被当成产物契约，否则正常分析会被判失败。
    const requests = <String>[
      '读取并分析 budget.xlsx',
      '查看这份 report.pdf',
      '分析现有 pptx 的内容',
    ];

    for (final request in requests) {
      expect(
        WorkArtifactDeliveryGuard.requiresFileArtifact(request),
        isFalse,
        reason: request,
      );
      expect(
        WorkArtifactDeliveryGuard.failureFor(
          request: request,
          hasReadableArtifact: false,
        ),
        isNull,
        reason: request,
      );
    }
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

  test('an explicit HTML contract ignores negative DOCX mentions', () {
    const request = '生成斗地主 HTML 页面；不产出 DOCX、不产出测试报告，只交付 html';

    expect(
      WorkArtifactDeliveryGuard.requiresDocxArtifact(
        request,
        contractFormat: 'html',
      ),
      isFalse,
    );
    expect(
      WorkArtifactDeliveryGuard.failureFor(
        request: request,
        contractFormat: 'html',
        hasReadableArtifact: false,
      ),
      WorkArtifactDeliveryGuard.missingArtifactMessage,
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

  test('HTML creation requires and validates a complete readable document',
      () async {
    final root = await Directory.systemTemp.createTemp('html-contract-');
    addTearDown(() => root.delete(recursive: true));
    final path = '${root.path}/page.html';
    await File(path).writeAsString(
      '<!doctype html><html><body><button>开始</button></body></html>',
    );
    final task = AgentTask(
      groupId: 'html-contract',
      characterId: 'executor',
      userRequest: '生成一个 HTML 页面并保存到 page.html',
      workModeTask: true,
      createdAt: DateTime.now(),
      startedAt: DateTime.now().subtract(const Duration(milliseconds: 100)),
      lastArtifactPaths: [path],
    );

    final valid = await WorkArtifactDeliveryGuard.validateTask(
      task: task,
      pathPolicy: WorkspacePathPolicy(authorizedRoots: [root.path]),
    );

    expect(valid.valid, isTrue, reason: valid.message);
    expect(
      WorkArtifactDeliveryGuard.requiresFileArtifact(task.userRequest),
      isTrue,
    );

    await File(path).writeAsString('<html><body><button>开始</button></html>');
    final missingBodyClose = await WorkArtifactDeliveryGuard.validateTask(
      task: task,
      pathPolicy: WorkspacePathPolicy(authorizedRoots: [root.path]),
    );
    expect(missingBodyClose.valid, isFalse);
    expect(missingBodyClose.code, 'htmlInvalidOrStale');

    await File(path).writeAsString('<div>fragment only</div>');
    final invalid = await WorkArtifactDeliveryGuard.validateTask(
      task: task,
      pathPolicy: WorkspacePathPolicy(authorizedRoots: [root.path]),
    );
    expect(invalid.valid, isFalse);
    expect(invalid.code, 'htmlInvalidOrStale');
  });

  test('revision completion fails when no content change was recorded',
      () async {
    final root = await Directory.systemTemp.createTemp('unchanged-revision-');
    addTearDown(() => root.delete(recursive: true));
    final path = '${root.path}/page.html';
    await File(path).writeAsString(
      '<html><body><main>旧页面</main></body></html>',
    );
    final now = DateTime.now();
    final task = AgentTask(
      groupId: 'revision-contract',
      characterId: 'executor',
      userRequest: '优化一下',
      workModeTask: true,
      createdAt: now,
      startedAt: now.subtract(const Duration(milliseconds: 100)),
      lastArtifactPaths: [path],
      executionStateJson: jsonEncode({
        'followUpKind': 'reviseArtifact',
        'revisionTargetPath': path,
      }),
    );

    final result = await WorkArtifactDeliveryGuard.validateTask(
      task: task,
      pathPolicy: WorkspacePathPolicy(authorizedRoots: [root.path]),
    );

    expect(result.valid, isFalse);
    expect(result.code, 'artifactUnchanged');
    expect(result.message, WorkArtifactDeliveryGuard.unchangedRevisionMessage);
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

  test('project-relative directory contract accepts a DOCX inside it',
      () async {
    final root = await Directory.systemTemp.createTemp('s6-project-dir-');
    final directory = Directory('${root.path}/doc/需求优化文档');
    await directory.create(recursive: true);
    addTearDown(() => root.delete(recursive: true));
    final path = '${directory.path}/需求优化文档.docx';
    await File(path).writeAsBytes(_minimalDocx('项目需求正文'));

    final task = _wordTask(
      path,
      root.path,
      location: '项目下doc/需求优化文档/',
    );
    final result = await WorkArtifactDeliveryGuard.validateTask(
      task: task,
      pathPolicy: WorkspacePathPolicy(authorizedRoots: [root.path]),
      workspaceRoot: root.path,
    );

    expect(result.valid, isTrue, reason: result.message);
    expect(result.path, endsWith('/doc/需求优化文档/需求优化文档.docx'));
  });

  test('directory contract ignores its final confirmation annotation',
      () async {
    final root = await Directory.systemTemp.createTemp('s6-contract-note-');
    final directory = Directory('${root.path}/doc/需求优化文档');
    await directory.create(recursive: true);
    addTearDown(() => root.delete(recursive: true));
    final path = '${directory.path}/需求优化文档.docx';
    await File(path).writeAsBytes(_minimalDocx('项目需求正文'));

    final task = _wordTask(
      path,
      root.path,
      location: '项目下doc/需求优化文档/（待群内最终确认）',
    );
    final result = await WorkArtifactDeliveryGuard.validateTask(
      task: task,
      pathPolicy: WorkspacePathPolicy(authorizedRoots: [root.path]),
      workspaceRoot: root.path,
    );

    expect(result.valid, isTrue, reason: result.message);
  });

  test('explicit file contract does not widen for a same-named directory',
      () async {
    final root = await Directory.systemTemp.createTemp('s6-file-contract-');
    final directory = Directory('${root.path}/report.docx');
    await directory.create(recursive: true);
    final path = '${directory.path}/nested.docx';
    await File(path).writeAsBytes(_minimalDocx('不应被接受'));
    addTearDown(() => root.delete(recursive: true));

    final task = _wordTask(path, root.path, location: 'report.docx');
    final result = await WorkArtifactDeliveryGuard.validateTask(
      task: task,
      pathPolicy: WorkspacePathPolicy(authorizedRoots: [root.path]),
      workspaceRoot: root.path,
    );

    expect(result.valid, isFalse);
    expect(result.code, 'docxInvalidOrStale');
  });

  test('relative recorded artifact resolves from the task workspace', () async {
    final root = await Directory.systemTemp.createTemp('s6-relative-artifact-');
    final directory = Directory('${root.path}/doc/需求优化文档');
    await directory.create(recursive: true);
    addTearDown(() => root.delete(recursive: true));
    final path = '${directory.path}/需求优化文档.docx';
    await File(path).writeAsBytes(_minimalDocx('项目需求正文'));

    final task = _wordTask(
      'doc/需求优化文档/需求优化文档.docx',
      root.path,
      location: '项目下doc/需求优化文档/',
    );
    final result = await WorkArtifactDeliveryGuard.validateTask(
      task: task,
      pathPolicy: WorkspacePathPolicy(authorizedRoots: [root.path]),
      workspaceRoot: root.path,
    );

    expect(result.valid, isTrue, reason: result.message);
    expect(result.path, endsWith('/doc/需求优化文档/需求优化文档.docx'));
  });

  test('relative artifact traversal is rejected before authorization',
      () async {
    final root = await Directory.systemTemp.createTemp('s6-traversal-');
    final workspace = Directory('${root.path}/workspace');
    await workspace.create(recursive: true);
    final path = '${root.path}/outside.docx';
    await File(path).writeAsBytes(_minimalDocx('越界正文'));
    addTearDown(() => root.delete(recursive: true));

    final task = _wordTask('../outside.docx', root.path);
    final result = await WorkArtifactDeliveryGuard.validateTask(
      task: task,
      pathPolicy: WorkspacePathPolicy(authorizedRoots: [root.path]),
      workspaceRoot: workspace.path,
    );

    expect(result.valid, isFalse);
    expect(result.code, 'docxInvalidOrStale');
  });

  test('resumed task keeps an artifact created before its latest start fresh',
      () async {
    final root = await Directory.systemTemp.createTemp('s6-resumed-artifact-');
    addTearDown(() => root.delete(recursive: true));
    final path = '${root.path}/需求优化文档.docx';
    await File(path).writeAsBytes(_minimalDocx('重试正文'));

    final task = _wordTask(path, root.path)
      ..createdAt = DateTime.now().subtract(const Duration(minutes: 1))
      ..startedAt = DateTime.now();
    final result = await WorkArtifactDeliveryGuard.validateTask(
      task: task,
      pathPolicy: WorkspacePathPolicy(authorizedRoots: [root.path]),
    );

    expect(result.valid, isTrue, reason: result.message);
  });

  test('redacted target location falls back to the authorized workspace',
      () async {
    final root = await Directory.systemTemp.createTemp('s6-redacted-location-');
    addTearDown(() => root.delete(recursive: true));
    final path = '${root.path}/docs/report.docx';
    await Directory('${root.path}/docs').create(recursive: true);
    await File(path).writeAsBytes(_minimalDocx('核心正文'));

    final task = _wordTask(path, root.path, location: '[REDACTED].docx');
    final result = await WorkArtifactDeliveryGuard.validateTask(
      task: task,
      pathPolicy: WorkspacePathPolicy(authorizedRoots: [root.path]),
      workspaceRoot: root.path,
    );

    expect(result.valid, isTrue, reason: result.message);
    expect(result.path, endsWith('/docs/report.docx'));
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

  test('a generator script cannot stand in for the requested deliverable',
      () async {
    // 回归：契约不带格式约束时（泛指文档类、源码类请求），本次运行写出的生成
    // 脚本曾可以直接充当交付物——“生成一份分析报告”把 build_report.py 当成报告
    // 交付给用户。
    final root = await Directory.systemTemp.createTemp('source-substitute-');
    addTearDown(() => root.delete(recursive: true));
    final script = File('${root.path}/build_report.py');
    await script.writeAsString('print("report")');
    final deckScript = File('${root.path}/make_cover.py');
    await deckScript.writeAsString('print("cover")');

    for (final entry in <String, String>{
      '生成一份分析报告': script.path,
      '生成一张封面图 png': deckScript.path,
      '生成 demo.mp4 视频': deckScript.path,
    }.entries) {
      final result = await WorkArtifactDeliveryGuard.validateTask(
        task: _craftedTask(request: entry.key, path: entry.value),
        pathPolicy: WorkspacePathPolicy(authorizedRoots: [root.path]),
      );
      expect(result.valid, isFalse, reason: entry.key);
    }
  });

  test('a source request is still satisfied by the code it asked for',
      () async {
    final root = await Directory.systemTemp.createTemp('source-request-');
    addTearDown(() => root.delete(recursive: true));
    final script = File('${root.path}/script.py');
    await script.writeAsString('print("ok")');

    final result = await WorkArtifactDeliveryGuard.validateTask(
      task: _craftedTask(
        request: '生成一个可运行的 Python 脚本',
        path: script.path,
      ),
      pathPolicy: WorkspacePathPolicy(authorizedRoots: [root.path]),
    );

    expect(result.valid, isTrue, reason: result.message);
  });

  test('every registered format constrains its own deliverable', () async {
    // 覆盖矩阵：每一类都必须建立产物契约，并且只有当请求点名了格式时才能用
    // 对应类型的真实文件交付——生成脚本在任何一类下都不得顶替。
    final root = await Directory.systemTemp.createTemp('format-matrix-');
    addTearDown(() => root.delete(recursive: true));
    final script = File('${root.path}/build_artifact.py');
    await script.writeAsString('print("build")');
    const realHtml =
        '<!doctype html><html><body><main>真实网页</main></body></html>';

    const matrix = <String, String>{
      '生成一张封面图 png': 'cover.png',
      '生成 chart.svg 矢量图': 'chart.svg',
      '生成 demo.mp4 视频': 'demo.mp4',
      '生成 voice.mp3 音频': 'voice.mp3',
      '生成 archive.zip 压缩包': 'archive.zip',
      '生成 report.rtf': 'report.rtf',
      '生成 report.odt': 'report.odt',
      '生成 book.epub': 'book.epub',
      '生成 macro.xlsm 表格': 'macro.xlsm',
      '生成 deck.pptm': 'deck.pptm',
      '生成一个网页并保存到工作区': 'page.html',
      '生成一份演示文稿': 'deck.pptx',
      '生成一份幻灯片': 'slides.pptx',
    };

    for (final entry in matrix.entries) {
      expect(
        WorkArtifactDeliveryGuard.requiresFileArtifact(entry.key),
        isTrue,
        reason: '未建立产物契约：${entry.key}',
      );
      final deliverable = File('${root.path}/${entry.value}');
      await deliverable.writeAsString(
        entry.value.endsWith('.html') ? realHtml : 'placeholder',
      );
      final valid = await WorkArtifactDeliveryGuard.validateTask(
        task: _craftedTask(request: entry.key, path: deliverable.path),
        pathPolicy: WorkspacePathPolicy(authorizedRoots: [root.path]),
      );
      expect(valid.valid, isTrue,
          reason: '真实交付物被拒：${entry.key} → ${entry.value}');
      final substituted = await WorkArtifactDeliveryGuard.validateTask(
        task: _craftedTask(request: entry.key, path: script.path),
        pathPolicy: WorkspacePathPolicy(authorizedRoots: [root.path]),
      );
      expect(substituted.valid, isFalse, reason: '生成脚本顶替了交付物：${entry.key}');
    }
  });

  test('a format mentioned as an ingredient does not constrain the output', () {
    // 反向保护：请求里顺带提到的格式（“包含 png 图表”“把 chart.png 转成 pdf”）
    // 如果被当成交付格式，反而会把用户真正要的那份文件判为无效。
    expect(
      WorkArtifactDeliveryGuard.declaredOutputFormats(
        _craftedTask(request: '生成一份报告，包含 png 图表', path: '/tmp/x'),
      ),
      isEmpty,
    );
    expect(
      WorkArtifactDeliveryGuard.declaredOutputFormats(
        _craftedTask(request: '把 chart.png 转成 pdf', path: '/tmp/x'),
      ),
      equals(<String>{'pdf'}),
    );
    expect(
      WorkArtifactDeliveryGuard.declaredOutputFormats(
        _craftedTask(request: '从 report.md 生成 docx', path: '/tmp/x'),
      ),
      equals(<String>{'docx'}),
    );
    expect(
      WorkArtifactDeliveryGuard.declaredOutputFormats(
        _craftedTask(request: '生成一张封面图 png', path: '/tmp/x'),
      ),
      equals(<String>{'png'}),
    );
  });

  test('a source request names its language as the deliverable format', () {
    <String, Set<String>>{
      '生成一个可运行的 Python 脚本': {'py'},
      '生成 main.dart 应用': {'dart'},
      '生成一个 shell 脚本': {'sh'},
      '生成 query.sql': {'sql'},
      '生成一个网页并保存到工作区': {'html'},
    }.forEach((request, formats) {
      expect(
        WorkArtifactDeliveryGuard.declaredOutputFormats(
          _craftedTask(request: request, path: '/tmp/x'),
        ),
        equals(formats),
        reason: request,
      );
    });

    // `go`/`c`/`rs` 只在扩展名形式下才算格式：单独出现时它们在普通文本里更像
    // 普通单词，认成格式会平白把交付物判无效。
    expect(
      WorkArtifactDeliveryGuard.declaredOutputFormats(
        _craftedTask(request: '生成一份 go 语言服务报告', path: '/tmp/x'),
      ),
      isEmpty,
    );
    expect(
      WorkArtifactDeliveryGuard.declaredOutputFormats(
        _craftedTask(request: '生成 main.go', path: '/tmp/x'),
      ),
      equals(<String>{'go'}),
    );
  });

  test('a python request does not accept an unrelated document', () async {
    final root = await Directory.systemTemp.createTemp('python-contract-');
    addTearDown(() => root.delete(recursive: true));
    final notes = File('${root.path}/notes.md');
    await notes.writeAsString('# notes');

    final result = await WorkArtifactDeliveryGuard.validateTask(
      task: _craftedTask(
        request: '生成一个可运行的 Python 脚本',
        path: notes.path,
      ),
      pathPolicy: WorkspacePathPolicy(authorizedRoots: [root.path]),
    );

    expect(result.valid, isFalse);
  });

  test('source extensions are recognized under every alias spelling', () async {
    // 回归：过滤只看扩展名的原始拼写，`.mjs`、`.cjs`、`.pyw`、`.bash`、`.kts`
    // 等别名不被认作源码，也就挡不住生成脚本顶替交付物；同一个判定还用于命令
    // 失败时的源码定位，漏判会直接丢掉可修复的目标文件。
    const aliases = <String>[
      'build_report.mjs',
      'build_report.cjs',
      'build_report.pyw',
      'build_report.py3',
      'build_report.bash',
      'build_report.zsh',
      'build_report.fish',
      'build_report.kts',
      'build_report.cc',
      'build_report.cxx',
    ];
    for (final name in aliases) {
      expect(
        WorkArtifactDeliveryGuard.isSourceArtifactPath(name),
        isTrue,
        reason: name,
      );
    }
    for (final name in <String>[
      'report.md',
      'report.xlsx',
      'report.docx',
      'slides.pptx',
      'cover.png',
    ]) {
      expect(
        WorkArtifactDeliveryGuard.isSourceArtifactPath(name),
        isFalse,
        reason: name,
      );
    }

    final root = await Directory.systemTemp.createTemp('source-alias-');
    addTearDown(() => root.delete(recursive: true));
    final script = File('${root.path}/build_report.mjs');
    await script.writeAsString('console.log("report")');

    final result = await WorkArtifactDeliveryGuard.validateTask(
      task: _craftedTask(request: '生成一份分析报告', path: script.path),
      pathPolicy: WorkspacePathPolicy(authorizedRoots: [root.path]),
    );
    expect(result.valid, isFalse, reason: '别名生成脚本顶替了交付物');
  });

  test('a language name in a document title is a topic, not the format',
      () async {
    // 回归：「生成一份 Python 学习报告」曾被解析成 {py}，于是真正的 report.md
    // 被格式约束拒之门外，任务只能判失败。
    final root = await Directory.systemTemp.createTemp('language-topic-');
    addTearDown(() => root.delete(recursive: true));
    final report = File('${root.path}/report.md');
    await report.writeAsString('# Python 学习报告');

    final task = _craftedTask(
      request: '生成一份 Python 学习报告',
      path: report.path,
    );
    expect(
      WorkArtifactDeliveryGuard.declaredOutputFormats(task),
      isEmpty,
      reason: '报告标题里的语言名不该约束输出格式',
    );
    expect(
      WorkArtifactDeliveryGuard.requiresSourceArtifact('生成一份 Python 学习报告'),
      isFalse,
      reason: '报告主题里的语言名不该让源码顶替交付物',
    );

    final result = await WorkArtifactDeliveryGuard.validateTask(
      task: task,
      pathPolicy: WorkspacePathPolicy(authorizedRoots: [root.path]),
    );
    expect(result.valid, isTrue, reason: result.message);
  });

  test('a category word in a document title is a topic, not the format',
      () async {
    // 同一类错误的另一条路径：泛化的类别词（网页/页面/前端）也不该压过文档主题，
    // 否则一份网页性能分析报告必须交付 html。
    final root = await Directory.systemTemp.createTemp('category-topic-');
    addTearDown(() => root.delete(recursive: true));
    final report = File('${root.path}/report.md');
    await report.writeAsString('# 网页性能分析');
    final generator = File('${root.path}/build_report.py');
    await generator.writeAsString('print("report")');

    final task = _craftedTask(
      request: '生成一份网页性能分析报告',
      path: report.path,
    );
    expect(WorkArtifactDeliveryGuard.declaredOutputFormats(task), isEmpty);

    final result = await WorkArtifactDeliveryGuard.validateTask(
      task: task,
      pathPolicy: WorkspacePathPolicy(authorizedRoots: [root.path]),
    );
    expect(result.valid, isTrue, reason: result.message);

    final substituted = await WorkArtifactDeliveryGuard.validateTask(
      task: _craftedTask(
        request: '生成一份网页性能分析报告',
        path: generator.path,
      ),
      pathPolicy: WorkspacePathPolicy(authorizedRoots: [root.path]),
    );
    expect(substituted.valid, isFalse,
        reason: '文档主题中的「网页」让源码脚本顶替了报告');
  });

  test('source aliases also identify a source request by extension', () async {
    final root = await Directory.systemTemp.createTemp('source-alias-request-');
    addTearDown(() => root.delete(recursive: true));
    final source = File('${root.path}/main.mjs');
    await source.writeAsString('console.log("ok")');
    const request = '生成 main.mjs';

    expect(WorkArtifactDeliveryGuard.requiresSourceArtifact(request), isTrue);
    final result = await WorkArtifactDeliveryGuard.validateTask(
      task: _craftedTask(request: request, path: source.path),
      pathPolicy: WorkspacePathPolicy(authorizedRoots: [root.path]),
    );
    expect(result.valid, isTrue, reason: result.message);
  });

  test('a named source format beats a generic page inference', () async {
    // 回归：「生成一个 TSX 前端页面」解析成 {tsx, html} 后，声明格式不再全是
    // 源码，App.tsx 被“源码不能顶替交付物”的规则直接排除。
    final root = await Directory.systemTemp.createTemp('tsx-page-');
    addTearDown(() => root.delete(recursive: true));
    final page = File('${root.path}/App.tsx');
    await page.writeAsString(
      'export default function App() { return null; }',
    );

    final task = _craftedTask(request: '生成一个 TSX 前端页面', path: page.path);
    expect(
      WorkArtifactDeliveryGuard.declaredOutputFormats(task),
      equals(<String>{'tsx'}),
    );

    final result = await WorkArtifactDeliveryGuard.validateTask(
      task: task,
      pathPolicy: WorkspacePathPolicy(authorizedRoots: [root.path]),
    );
    expect(result.valid, isTrue, reason: result.message);
  });

  test('a large but valid deliverable is not rejected for its size', () async {
    // 回归：交付校验带 10 MB 上限，一份内嵌图片的 HTML 报告很容易超过它，于是
    // 真实产物被判为无效。上限应当对齐“单个聊天附件能有多大”，而不是更小。
    final root = await Directory.systemTemp.createTemp('large-html-');
    addTearDown(() => root.delete(recursive: true));
    final path = '${root.path}/report.html';
    final buffer = StringBuffer('<!doctype html><html><body><main>');
    final chunk = List<String>.filled(1 << 20, 'a').join();
    for (var index = 0; index < 12; index++) {
      buffer.write(chunk);
    }
    buffer.write('</main></body></html>');
    await File(path).writeAsString(buffer.toString());
    expect(await File(path).length(), greaterThan(10 * 1024 * 1024));

    final result = await WorkArtifactDeliveryGuard.validateTask(
      task: _craftedTask(
        request: '生成一个 HTML 报告并保存到 report.html',
        path: path,
      ),
      pathPolicy: WorkspacePathPolicy(authorizedRoots: [root.path]),
    );

    expect(result.valid, isTrue, reason: result.message);
  });

  test('a modification request keeps its file contract', () async {
    // 回归：「契约是否存在」与「格式过滤」必须用两把尺子。曾把事情合并成一次
    // 扫描，于是「把 notes.txt 更新为 v2」被当成没有产物契约，刚写入的文件不再
    // 自动收尾，整个任务挂死。
    final root = await Directory.systemTemp.createTemp('revision-contract-');
    addTearDown(() => root.delete(recursive: true));
    final notes = File('${root.path}/notes.txt');
    await notes.writeAsString('v2');

    for (final request in <String>[
      '把 notes.txt 更新为 v2',
      '修改 report.md 里的结论',
      '将 cover.png 更新为新图',
    ]) {
      expect(
        WorkArtifactDeliveryGuard.requiresFileArtifact(request),
        isTrue,
        reason: '修改类请求丢失了产物契约：$request',
      );
    }

    final result = await WorkArtifactDeliveryGuard.validateTask(
      task: _craftedTask(request: '把 notes.txt 更新为 v2', path: notes.path),
      pathPolicy: WorkspacePathPolicy(authorizedRoots: [root.path]),
    );
    expect(result.valid, isTrue, reason: result.message);
  });

  test('a bare word that is also ordinary prose is not a file task', () {
    // 反向：`c`/`go`/`rs` 这类词单独出现时是普通文本，认成格式会让一句纯聊天
    // 回答变成必须交付文件的产物任务。
    expect(
      WorkArtifactDeliveryGuard.requiresFileArtifact('生成一段 c 语言的说明文字'),
      isFalse,
    );
    expect(
      WorkArtifactDeliveryGuard.requiresFileArtifact('生成 main.go 服务'),
      isTrue,
    );
  });

  test('a pending delivery notice is cleared without touching other keys', () {
    final cleared = workWithoutArtifactDeliveryNotice(jsonEncode({
      'artifactDeliveryNoticePublished': true,
      'artifactDeliveryRetryOnly': true,
      'artifactDeliveryMessageId': 'message-1',
      'committedActionKeys': <String>['op'],
    }));
    final decoded = jsonDecode(cleared) as Map<String, dynamic>;

    expect(decoded.containsKey('artifactDeliveryNoticePublished'), isFalse);
    expect(decoded.containsKey('artifactDeliveryRetryOnly'), isFalse);
    expect(decoded.containsKey('artifactDeliveryMessageId'), isFalse);
    expect(decoded['committedActionKeys'], <String>['op']);
  });

  test('clearing the last remaining key yields an empty checkpoint', () {
    expect(
      workWithoutArtifactDeliveryNotice(jsonEncode({
        'artifactDeliveryNoticePublished': true,
        'artifactDeliveryRetryOnly': true,
        'artifactDeliveryMessageId': 'message-1',
      })),
      '',
    );
  });

  test('a damaged checkpoint is not wiped by the delivery-notice clear', () {
    // 非 map 的检查点是被损坏或来自未来版本的记录：只清标记不能把它抹成空串，
    // 否则它看起来就像一个可运行的 legacy 状态。
    expect(workWithoutArtifactDeliveryNotice('[1,2]'), '[1,2]');
    expect(workWithoutArtifactDeliveryNotice('not-json'), 'not-json');
    expect(workWithoutArtifactDeliveryNotice(''), '');
  });

  test('a delivery retry is pending only with a published message id', () {
    expect(
      workArtifactDeliveryRetryPending(jsonEncode({
        'artifactDeliveryNoticePublished': true,
        'artifactDeliveryRetryOnly': true,
        'artifactDeliveryMessageId': 'message-1',
      })),
      isTrue,
    );
    expect(
      workArtifactDeliveryRetryPending(jsonEncode({
        'artifactDeliveryNoticePublished': true,
        'artifactDeliveryRetryOnly': true,
      })),
      isFalse,
      reason: '没有消息 id 就没有可重发的对象',
    );
    expect(workArtifactDeliveryRetryPending(''), isFalse);
  });
}

/// Builds a task whose request names [request] and whose only recorded artifact
/// is [path], fresh as of this run.
AgentTask _craftedTask({required String request, required String path}) {
  final now = DateTime.now();
  return AgentTask(
    id: 'crafted-task',
    groupId: 'crafted-group',
    characterId: 'worker',
    userRequest: request,
    workModeTask: true,
    createdAt: now,
    startedAt: now.subtract(const Duration(milliseconds: 200)),
    lastArtifactPaths: [path],
  );
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

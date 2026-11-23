import 'dart:convert';
import 'dart:io';
import 'package:hive/hive.dart';
import 'package:chat_group/features/work_mode/work_folder_grant_service.dart';
import 'package:chat_group/features/work_mode/workspace_path_policy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/features/agentic/tool_request.dart';
import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/features/work_mode/agent_decision.dart';
import 'package:chat_group/features/web_search/desktop/desktop_web_service.dart';
import 'package:chat_group/features/web_search/desktop/web_worker_client.dart';
import 'package:chat_group/features/work_mode/work_tool_registry.dart';
import 'package:chat_group/features/work_mode/work_web_tools.dart';
import 'package:chat_group/features/chat_group/roundtable_news_role_service.dart';

class PublicSourceFailureWorker extends WebWorkerClient {
  PublicSourceFailureWorker({required this.status, required this.retryable})
      : super(executable: '/unused', entryPoint: '/unused');

  final int status;
  final bool retryable;

  @override
  Stream<Map<String, dynamic>> request(Map<String, dynamic> arguments) async* {
    yield {
      'status': 'error',
      'code': 'SOURCE_HTTP_ERROR',
      'sourceStatus': status,
      'retryable': retryable,
    };
  }
}

class PublicSearchAndReadWorker extends WebWorkerClient {
  PublicSearchAndReadWorker()
      : super(executable: '/unused', entryPoint: '/unused');

  @override
  Stream<Map<String, dynamic>> request(Map<String, dynamic> arguments) async* {
    final url = Uri.parse(arguments['url'] as String);
    final body = url.host == 'html.duckduckgo.com'
        ? '<div class="result"><a class="result__a" href="https://example.com/README.md">Flutter README</a><span class="result__snippet">Flutter supports desktop platforms.</span></div>'
        : '<html><body><p>Flutter supports mobile and desktop platforms.</p></body></html>';
    final bytes = utf8.encode(body);
    yield {
      'status': 'headers',
      'url': url.toString(),
      'contentType': 'text/html',
    };
    yield {'status': 'chunk', 'data': base64Encode(bytes)};
    yield {'status': 'done', 'byteLength': bytes.length};
  }
}

void main() {
  group('download directory authorization', () {
    late Directory sandbox;
    late Directory workspace;
    late Link alias;
    late Box<dynamic> box;

    setUp(() async {
      sandbox = await Directory.systemTemp.createTemp('web-download-path-');
      workspace = await Directory('${sandbox.path}/workspace').create();
      alias = await Link('${sandbox.path}/alias').create(workspace.path);
      Hive.init('${sandbox.path}/hive');
      box = await Hive.openBox<dynamic>('grants');
    });
    tearDown(() async {
      await Hive.close();
      await sandbox.delete(recursive: true);
    });

    Future<WorkspacePathPolicy> policy({bool writable = true}) async {
      final grants = WorkFolderGrantService(
          box: box,
          directoryValidator: (_) async => true,
          writeDirectoryValidator: (_) async => writable,
          isWindows: false);
      await grants.authorizeDirectory(alias.path, consent: (_) async => true);
      return WorkspacePathPolicy(grantService: grants, isWindows: false);
    }

    test('resolves workspace aliases before writable and containment checks',
        () async {
      final paths = await policy();
      final target = await resolveWorkDownloadDirectory(paths, alias.path);
      expect(
          target.path, '${await workspace.resolveSymbolicLinks()}/downloads');
    });

    test('a read-only alias still rejects downloads', () async {
      final paths = await policy(writable: false);
      await expectLater(resolveWorkDownloadDirectory(paths, alias.path),
          throwsA(isA<WorkspacePathException>()));
    });

    test('an authorized symlink outside this workspace is still rejected',
        () async {
      final paths = await policy();
      final outside = await Directory('${sandbox.path}/outside').create();
      await paths.grantService!
          .authorizeDirectory(outside.path, consent: (_) async => true);
      await Link('${workspace.path}/downloads').create(outside.path);
      await expectLater(resolveWorkDownloadDirectory(paths, alias.path),
          throwsA(isA<WorkspacePathException>()));
    });

    test('downloads cannot alias the workspace root itself', () async {
      final paths = await policy();
      await Link('${workspace.path}/downloads').create(workspace.path);
      await expectLater(resolveWorkDownloadDirectory(paths, alias.path),
          throwsA(isA<WorkspacePathException>()));
    });

    test('explicit writable roots retain their existing capability', () async {
      final paths =
          WorkspacePathPolicy(authorizedRoots: [alias.path], isWindows: false);
      final target = await resolveWorkDownloadDirectory(paths, alias.path);
      expect(
          target.path, '${await workspace.resolveSymbolicLinks()}/downloads');
    });
  }, skip: Platform.isWindows);

  test('network investigation exposes closed schemas and no download mutation',
      () {
    final worker =
        WebWorkerClient(executable: '/unused', entryPoint: '/unused');
    addTearDown(worker.close);
    final definitions = webInvestigationTools(DesktopWebService(worker));
    expect(definitions.map((entry) => entry.name),
        [AgentToolName.webSearch, AgentToolName.webRead]);
    expect(definitions.every((entry) => entry.isReadOnly), isTrue);
    expect(
        definitions.first.schema
            .validate({'query': 'Flutter', 'url': 'https://example.com'}),
        isNotNull);
    expect(definitions.last.schema.validate({'sourceId': 's1'}), isNull);
    expect(definitions.last.schema.validate({'url': 'https://example.com'}),
        isNotNull);
    expect(WorkToolRegistry.investigationToolNames,
        contains(AgentToolName.webRead));
    expect(WorkToolRegistry.investigationToolNames,
        isNot(contains(AgentToolName.webDownload)));
  });

  test('work search and read persist their real tool receipts', () async {
    final worker = PublicSearchAndReadWorker();
    addTearDown(worker.close);
    final service = DesktopWebService(worker);
    final task = AgentTask(
      groupId: 'qa-group',
      characterId: 'qa-maker',
      userRequest: 'Search and read a public source.',
    );
    final registry = WorkToolRegistry(
      definitions: webInvestigationTools(
        service,
        onEvidenceChanged: () => persistWorkWebEvidence(task, service),
      ),
    );

    final search = await registry.execute(
      const AgentToolCall(
        name: AgentToolName.webSearch,
        arguments: {'query': 'site:example.com Flutter README'},
      ),
      context: WorkToolExecutionContext(task: task),
    );
    expect(search.succeeded, isTrue);
    final sourceId = (search.data['sources'] as List).single['source_id'];
    final searchReceipt = search.data['toolReceipt'] as Map;
    expect(searchReceipt['receiptId'], isNotEmpty);
    expect(searchReceipt['requestId'], isNotEmpty);
    expect(searchReceipt['query'], 'site:example.com Flutter README');
    expect(searchReceipt['sources'], [
      {'sourceId': sourceId, 'url': 'https://example.com/README.md'},
    ]);

    final read = await registry.execute(
      AgentToolCall(
        name: AgentToolName.webRead,
        arguments: {'sourceId': sourceId},
      ),
      context: WorkToolExecutionContext(task: task),
    );
    expect(read.succeeded, isTrue);
    final readReceipt = read.data['toolReceipt'] as Map;
    expect(readReceipt['receiptId'], isNotEmpty);
    expect(readReceipt['tool'], 'web.read');
    expect(readReceipt['sourceId'], sourceId);
    expect(readReceipt['url'], 'https://example.com/README.md');
    expect(readReceipt['byteLength'], greaterThan(0));
    expect(readReceipt['sha256'], matches(RegExp(r'^[a-f0-9]{64}$')));

    final persisted = jsonDecode(task.executionStateJson) as Map;
    final receipts = persisted['webToolReceipts'] as List;
    expect(receipts, hasLength(2));
    expect(receipts.map((receipt) => receipt['receiptId']).toSet(), {
      searchReceipt['receiptId'],
      readReceipt['receiptId'],
    });

    final restarted = DesktopWebService(WebWorkerClient(
      executable: '/unused',
      entryPoint: '/unused',
    ));
    addTearDown(restarted.worker.close);
    restarted.restoreSources(persisted['webSources']);
    persistWorkWebEvidence(task, restarted);
    final restored =
        (jsonDecode(task.executionStateJson) as Map)['webToolReceipts'] as List;
    expect(restored, hasLength(2));
    expect(restored.last['receiptId'], readReceipt['receiptId']);
  });

  test('work download receipt persists its byte count and digest', () async {
    final worker =
        WebWorkerClient(executable: '/unused', entryPoint: '/unused');
    addTearDown(worker.close);
    final service = DesktopWebService(worker);
    final sourceId = service.registerSource('https://example.com/README.md');
    final task = AgentTask(
      groupId: 'qa-group',
      characterId: 'qa-maker',
      userRequest: 'Download a public source.',
    );

    final receipt = recordWorkWebToolReceipt(
      service: service,
      tool: 'web.download',
      arguments: {'sourceId': sourceId, 'fileName': 'README.md'},
      result: {
        'fileName': 'README.md',
        'byteLength': 24,
        'sha256': 'a' * 64,
      },
      onEvidenceChanged: () => persistWorkWebEvidence(task, service),
    );

    expect(receipt['tool'], 'web.download');
    expect(receipt['sourceId'], sourceId);
    expect(receipt['fileName'], 'README.md');
    expect(receipt['byteLength'], 24);
    expect(receipt['sha256'], 'a' * 64);
    final persisted = jsonDecode(task.executionStateJson) as Map;
    expect((persisted['webToolReceipts'] as List).single['receiptId'],
        receipt['receiptId']);
  });

  for (final (status, retryable) in [(429, true), (404, false)]) {
    test('work web.read preserves HTTP $status failure metadata', () async {
      final worker = PublicSourceFailureWorker(
        status: status,
        retryable: retryable,
      );
      addTearDown(worker.close);
      final service = DesktopWebService(worker);
      final sourceId = service.registerSource('https://example.com/README.md');
      final task = AgentTask(
        groupId: 'qa-group',
        characterId: 'qa-maker',
        userRequest: 'Read the registered public README.',
      );
      final registry = WorkToolRegistry(
        definitions: webInvestigationTools(
          service,
          onEvidenceChanged: () => persistWorkWebEvidence(task, service),
        ),
      );

      final result = await registry.execute(
        AgentToolCall(
          name: AgentToolName.webRead,
          arguments: {'sourceId': sourceId},
        ),
        context: WorkToolExecutionContext(task: task),
      );

      expect(result.data['code'], 'SOURCE_HTTP_ERROR');
      expect(result.data['sourceStatus'], status);
      expect(result.data['retryable'], retryable);
      expect(result.message, contains('HTTP $status'));
      final persisted = jsonDecode(task.executionStateJson) as Map;
      final toolReceipt = (persisted['webToolReceipts'] as List).single;
      expect(toolReceipt['tool'], 'web.read');
      expect(toolReceipt['status'], 'failed');
      expect(toolReceipt['sourceStatus'], status);
      expect(toolReceipt['retryable'], retryable);
      expect(
        result.status,
        retryable
            ? WorkToolResultStatus.retryableFailure
            : WorkToolResultStatus.failed,
      );
    });
  }

  test(
      'Zhipu search-only roles cannot reach autonomous network tools in work mode',
      () async {
    final newsRole = AICharacter(
      id: roundtableNewsRoleId,
      name: '新闻角色',
      avatar: '📰',
      age: 30,
      role: '圆桌会议联网搜索助手',
      personalityTags: const [],
      systemPrompt: '',
      apiKey: '',
      apiProvider: 'zhipu',
      zhipuSearchAnswerOnly: false,
      agenticEnabled: true,
    );
    final zhipuOnlyRole = AICharacter(
      id: 'custom-zhipu-search-only',
      name: '智谱专用角色',
      avatar: '📰',
      age: 30,
      role: '仅智谱搜索',
      personalityTags: const [],
      systemPrompt: '',
      apiKey: '',
      apiProvider: 'zhipu',
      zhipuSearchAnswerOnly: true,
      agenticEnabled: true,
    );
    final ordinaryRole = AICharacter(
      name: '普通角色',
      avatar: '🙂',
      age: 30,
      role: '普通助手',
      personalityTags: const [],
      systemPrompt: '',
      apiKey: '',
      apiProvider: 'deepseek',
    );
    var executions = 0;
    final networkTools = [
      for (final name in [
        AgentToolName.webSearch,
        AgentToolName.webRead,
        AgentToolName.webDownload,
        AgentToolName.skillDownload,
        AgentToolName.skillGithubSearch,
        AgentToolName.skillGithubImport,
        AgentToolName.skillResourceRead,
      ])
        WorkToolDefinition(
          name: name,
          access: WorkToolAccess.readOnly,
          schema: const WorkToolSchema(),
          handler: (_) async {
            executions++;
            return const WorkToolResult.success();
          },
        ),
    ];

    expect(filterWorkModeNetworkTools(networkTools, newsRole), isEmpty);
    expect(filterWorkModeNetworkTools(networkTools, zhipuOnlyRole), isEmpty);
    expect(
      filterWorkModeNetworkTools(networkTools, ordinaryRole),
      hasLength(networkTools.length),
    );

    final task = AgentTask(
      groupId: 'qa-group',
      characterId: newsRole.id,
      userRequest: '只使用智谱搜索资料。',
    );
    for (final restricted in [newsRole, zhipuOnlyRole]) {
      final registry = WorkToolRegistry(
        definitions: filterWorkModeNetworkTools(networkTools, restricted),
      );
      for (final definition in networkTools) {
        final result = await registry.execute(
          AgentToolCall(name: definition.name, arguments: const {}),
          context: WorkToolExecutionContext(task: task),
        );
        expect(result.failureCode, 'toolMissing');
      }
    }
    expect(executions, 0, reason: '被过滤的工具处理器必须从未执行');
  });
}

part of 'work_mode_s8_end_to_end_test.dart';

class _S8Credentials implements ApiCredentialResolver {
  @override
  Future<String?> resolve(ApiConfig config) async => 's8-test-key';
}

/// The production runner still parses the real agent protocol and executes the
/// real command runner. Only the model transport is deterministic so this
/// test does not require a network credential or pretend to measure provider
/// quality.
class _S8ExecutionGateway extends AiRequestGateway {
  int calls = 0;

  _S8ExecutionGateway()
      : super(
          store: MemoryGovernanceStore(),
          client: _S8UnusedClient(),
        );

  @override
  Future<Map<String, dynamic>> sendChatMessageStreamed({
    required String apiKey,
    required ApiProvider provider,
    ApiProtocol apiProtocol = ApiProtocol.defaultValue,
    String? customBaseUrl,
    required String model,
    required List<Map<String, dynamic>> messages,
    required AiRequestPurpose purpose,
    required String conversationId,
    required String characterId,
    double temperature = 0.85,
    int maxTokens = 1024,
    Duration receiveTimeout = const Duration(seconds: 120),
    int maxRetries = 5,
    CancelToken? cancelToken,
    bool requiresTools = false,
    bool userInitiated = false,
    void Function(ChatStreamEvent event)? onEvent,
  }) async {
    calls++;
    final response = switch (calls) {
      1 => <String, dynamic>{
          'action': 'tool',
          'public_update': '已根据讨论结果写入 Word 转换源。',
          'tool': <String, dynamic>{
            'name': 'workspace.patch',
            'arguments': <String, dynamic>{
              'path': '需求文档.md',
              'content': '''# 网页版我的世界产品需求文档

## 目标与范围
本期聚焦可验证的核心玩法。

## 核心能力
- 无限地图
- 方块采集
- 背包系统
- 合成系统
- 人物系统

## 验收标准
测试角色可以按核心流程验证页面和玩法边界。

## 非本期范围
其他可后续再做。
''',
            },
          },
          'completion': null,
        },
      2 => <String, dynamic>{
          'action': 'tool',
          'public_update': '转换源已核对，准备生成真实 DOCX。',
          'tool': <String, dynamic>{
            'name': 'command.run',
            'arguments': <String, dynamic>{
              'executable': 'pandoc',
              'arguments': <String>[
                '需求文档.md',
                '-o',
                '需求文档.docx',
              ],
              'workingDirectory': '',
              'declaredImpact': <String>[
                '需求文档.md',
                '需求文档.docx',
              ],
            },
          },
          'completion': null,
        },
      _ => <String, dynamic>{
          'action': 'finish',
          'public_update': '真实 DOCX 已生成并完成正文核对。',
          'tool': null,
          'completion': <String, dynamic>{
            'summary': '已交付网页版我的世界产品需求 Word 文档。',
            'evidence': <String>[
              'Markdown 转换源已写入并重新读取。',
              'pandoc 已生成真实 DOCX。',
              'DOCX 正文包含核心能力和验收标准。',
            ],
          },
        },
    };
    return <String, dynamic>{
      'success': true,
      'message': jsonEncode(response),
    };
  }
}

class _S8UnusedClient extends ChatApiService {}

class _S8IsolatedDirectoryService extends WorkModeDirectoryService {
  final String isolatedDesktop;

  _S8IsolatedDirectoryService(this.isolatedDesktop);

  @override
  String? requestedDesktopPath(String request, {String? homePath}) {
    return WorkModeDirectoryService.requestTargetsDesktop(request)
        ? isolatedDesktop
        : null;
  }
}

/// CI images do not guarantee a Pandoc binary. This process boundary keeps the
/// acceptance flow deterministic while still exercising command policy,
/// approvals, locks and binary DOCX delivery through the production runner.
class _S8PandocHarness {
  int conversionCount = 0;

  Future<WorkCommandProcess> start(
    WorkCommand command, {
    required Map<String, String> env,
    required bool shell,
  }) async {
    if (command.executable != 'pandoc' || shell) {
      throw StateError('S8 只接受非 shell 的 pandoc DOCX 转换。');
    }
    final outputIndex = command.arguments.indexOf('-o');
    if (outputIndex != 1 || command.arguments.length != 3) {
      throw StateError('S8 pandoc 命令格式不符合预期。');
    }
    final source = File(
      '${command.workingDirectory}${Platform.pathSeparator}'
      '${command.arguments.first}',
    );
    final output = File(
      '${command.workingDirectory}${Platform.pathSeparator}'
      '${command.arguments[outputIndex + 1]}',
    );
    final markdown = await source.readAsString();
    await output.writeAsBytes(_s8Docx(markdown), flush: true);
    conversionCount += 1;
    return WorkCommandProcess(
      pid: conversionCount,
      stdout: const Stream<List<int>>.empty(),
      stderr: const Stream<List<int>>.empty(),
      exitCode: Future<int>.value(0),
      terminateTree: ({bool force = false}) async {},
    );
  }

  List<int> _s8Docx(String markdown) {
    final paragraphs = markdown
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .map(_s8DocxParagraph)
        .join();
    final archive = Archive()
      ..addFile(ArchiveFile.string(
        '[Content_Types].xml',
        '''<?xml version="1.0" encoding="UTF-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
</Types>''',
      ))
      ..addFile(ArchiveFile.string(
        '_rels/.rels',
        '''<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>''',
      ))
      ..addFile(ArchiveFile.string(
        'word/document.xml',
        '''<?xml version="1.0" encoding="UTF-8"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>$paragraphs<w:sectPr/></w:body>
</w:document>''',
      ));
    return ZipEncoder().encode(archive);
  }

  String _s8DocxParagraph(String line) {
    final text = line.replaceFirst(RegExp(r'^(?:#+|-+)\s*'), '');
    return '<w:p><w:r><w:t>${_escapeXml(text)}</w:t></w:r></w:p>';
  }

  String _escapeXml(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
}

AICharacter _s8Character({
  required String id,
  required String name,
  required String role,
  required String configId,
  required List<ToolPermission> permissions,
}) {
  return AICharacter(
    id: id,
    name: name,
    avatar: name.substring(0, 1),
    age: 30,
    role: role,
    personalityTags: const [],
    systemPrompt: '请只依据本职业职责公开讨论，明确事实、取舍和风险。',
    apiKey: '',
    apiProvider: ApiProvider.deepseek.name,
    modelName: 'deepseek-chat',
    apiConfigId: configId,
    toolPermissions: permissions,
  );
}

Map<String, dynamic> _s8DiscussionTurn({
  required String update,
  required int percent,
}) {
  return <String, dynamic>{
    'success': true,
    'message': jsonEncode(<String, dynamic>{
      'public_update': update,
      'understanding_percent': percent,
      'understanding_evidence': const <String>[
        '目标、范围和本期不做项已确认。',
        '各职业职责、技术取舍和风险已公开记录。',
        'Word 格式、隔离桌面位置和验收标准已确认。',
      ],
      'open_questions': const <String>[],
      'resolved_questions': const <String>[],
      'blockers': const <String>[],
      'resolved_blockers': const <String>[],
      'recommend_executor_id': 's8-product',
      'substantive_progress': true,
    }),
  };
}

Future<AgentTask> _s8WaitFor(
  DatabaseService database,
  String taskId,
  bool Function(AgentTask task) predicate,
) async {
  for (var attempt = 0; attempt < 240; attempt++) {
    final task = database.agentTaskBox.get(taskId);
    if (task != null && predicate(task)) return task;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  final task = database.agentTaskBox.get(taskId);
  throw StateError(
    '任务未在限定时间内达到预期状态：$taskId（当前：${task?.status.name}，错误：${task?.lastError}）',
  );
}

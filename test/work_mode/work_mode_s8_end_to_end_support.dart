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

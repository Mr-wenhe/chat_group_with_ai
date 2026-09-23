import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/features/work_mode/work_discussion_state.dart';
import 'package:chat_group/features/work_mode/work_artifact_delivery_guard.dart';
import 'package:chat_group/features/agentic/tool_request.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/models/api_protocol.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/media_attachment.dart';
import 'package:chat_group/core/models/tool_permission.dart';
import 'package:chat_group/core/streaming/chat_stream_event.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/features/ai_governance/ai_request_gateway.dart';
import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/work_mode/default_work_task_runner.dart';
import 'package:chat_group/features/agentic/expert_skill_catalog.dart';
import 'package:chat_group/features/work_mode/work_folder_grant_service.dart';
import 'package:chat_group/features/work_mode/work_failure.dart';
import 'package:chat_group/features/work_mode/work_mode_workspace_service.dart';
import 'package:chat_group/features/work_mode/work_change_policy.dart';
import 'package:chat_group/features/work_mode/work_approval_fingerprint.dart';
import 'package:chat_group/features/work_mode/work_snapshot_service.dart';
import 'package:chat_group/features/work_mode/work_command_runner.dart';
import 'package:chat_group/features/work_mode/work_task_coordinator.dart';
import 'package:chat_group/features/work_mode/work_task_event.dart';
import 'package:chat_group/features/work_mode/work_task_event_store.dart';
import 'package:chat_group/features/work_mode/workspace_file_service.dart';
import 'package:chat_group/features/work_mode/workspace_mutation_service.dart';
import 'package:chat_group/features/work_mode/workspace_path_policy.dart';
import 'package:chat_group/features/work_mode/work_resource_lock_manager.dart';
import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/services/chat_api_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/lifecycle_hive.dart';
import '../helpers/memory_governance_store.dart';

class _TestCredentials implements ApiCredentialResolver {
  @override
  Future<String?> resolve(ApiConfig config) async => 'test-key';
}

class _SequencedGateway extends AiRequestGateway {
  final String patchPath;
  final String patchContent;
  final bool repeatToolOnSecondModelCall;
  final String? finishSummary;

  _SequencedGateway({
    this.patchPath = 'notes.txt',
    this.patchContent = 'production-stage02',
    this.repeatToolOnSecondModelCall = false,
    this.finishSummary,
  }) : super(
          store: MemoryGovernanceStore(),
          client: _UnusedClient(),
        );

  int calls = 0;
  final observedModels = <String>[];
  final observedCharacters = <String>[];

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
    observedModels.add(model);
    observedCharacters.add(characterId);
    final returnsTool = repeatToolOnSecondModelCall ? calls <= 2 : calls == 1;
    return {
      'success': true,
      'message': returnsTool
          ? jsonEncode({
              'action': 'tool',
              'public_update': '准备写入授权目录文件。',
              'tool': {
                'name': 'workspace.patch',
                'arguments': {
                  'path': patchPath,
                  'content': patchContent,
                },
              },
              'completion': null,
            })
          : jsonEncode({
              'action': 'finish',
              'public_update': '写入已完成并核对结果。',
              'tool': null,
              'completion': {
                'summary': finishSummary ?? '已生成文件 $patchPath。',
                'evidence': ['文件可重新读取'],
              },
            }),
    };
  }
}

class _HangingModelGateway extends AiRequestGateway {
  _HangingModelGateway()
      : super(
          store: MemoryGovernanceStore(),
          client: _UnusedClient(),
        );

  final requestTokens = <CancelToken>[];

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
  }) {
    final token = cancelToken!;
    requestTokens.add(token);
    return token.whenCancel.then<Map<String, dynamic>>(
      (_) => {'success': false, 'message': '请求已取消'},
    );
  }
}

class _FloodingProgressGateway extends AiRequestGateway {
  static const int tokenCount = 2000;

  _FloodingProgressGateway()
      : super(
          store: MemoryGovernanceStore(),
          client: _UnusedClient(),
        );

  int calls = 0;

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
    for (var index = 0; index < tokenCount; index++) {
      onEvent?.call(ChatStreamEvent.token('x'));
    }
    return {
      'success': true,
      'message': jsonEncode({
        'action': 'finish',
        'public_update': '检查已完成。',
        'tool': null,
        'completion': {
          'summary': '检查已完成。',
          'evidence': ['已收到完整模型响应'],
        },
      }),
    };
  }
}

class _CancelsBeforeFinalProgressGateway extends AiRequestGateway {
  _CancelsBeforeFinalProgressGateway()
      : super(
          store: MemoryGovernanceStore(),
          client: _UnusedClient(),
        );

  int calls = 0;

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
    cancelToken?.cancel('模拟流结束时的取消竞态');
    return {
      'success': true,
      'message': jsonEncode({
        'action': 'finish',
        'public_update': '不应写入的迟到进度。',
        'tool': null,
        'completion': {
          'summary': '已完成。',
          'evidence': ['已验证取消后的尾部进度不会入队'],
        },
      }),
    };
  }
}

class _MultiPatchGateway extends AiRequestGateway {
  final List<Map<String, String>> patches;

  _MultiPatchGateway(this.patches)
      : super(
          store: MemoryGovernanceStore(),
          client: _UnusedClient(),
        );

  int calls = 0;

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
    final patchIndex = calls - 1;
    final message = patchIndex < patches.length
        ? jsonEncode({
            'action': 'tool',
            'public_update': '准备生成第 ${patchIndex + 1} 个项目文件。',
            'tool': {
              'name': 'workspace.patch',
              'arguments': {
                'path': patches[patchIndex]['path'],
                'content': patches[patchIndex]['content'],
              },
            },
            'completion': null,
          })
        : jsonEncode({
            'action': 'finish',
            'public_update': '项目文件已生成并核对。',
            'tool': null,
            'completion': {
              'summary': '已生成全部项目文件。',
              'evidence': ['每个文件均已重新读取'],
            },
          });
    return {'success': true, 'message': message};
  }
}

class _SingleToolGateway extends AiRequestGateway {
  final AgentToolName toolName;
  final Map<String, dynamic> arguments;

  _SingleToolGateway(this.toolName, this.arguments)
      : super(
          store: MemoryGovernanceStore(),
          client: _UnusedClient(),
        );

  int calls = 0;

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
    final response = calls == 1
        ? {
            'action': 'tool',
            'public_update': '准备执行 QA 工具操作。',
            'tool': {
              'name': toolName.wireName,
              'arguments': arguments,
            },
            'completion': null,
          }
        : {
            'action': 'finish',
            'public_update': 'QA 工具操作已处理。',
            'tool': null,
            'completion': {
              'summary': '已完成 QA 工具操作。',
              'evidence': ['已确认工具结果'],
            },
          };
    return {'success': true, 'message': jsonEncode(response)};
  }
}

class _CommandGateway extends AiRequestGateway {
  final List<String> commandArguments;

  _CommandGateway({this.commandArguments = const []})
      : super(
          store: MemoryGovernanceStore(),
          client: _UnusedClient(),
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
    return {
      'success': true,
      'message': jsonEncode({
        'action': 'tool',
        'public_update': '准备读取工作目录。',
        'tool': {
          'name': 'command.run',
          'arguments': {
            'executable': 'pwd',
            'arguments': commandArguments,
            'workingDirectory': '.',
            'declaredImpact': <String>['.'],
          },
        },
        'completion': null,
      }),
    };
  }
}

class _BinaryReadGateway extends AiRequestGateway {
  final String path;

  _BinaryReadGateway(this.path)
      : super(
          store: MemoryGovernanceStore(),
          client: _UnusedClient(),
        );

  int calls = 0;
  List<Map<String, dynamic>> lastMessages = const [];

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
    lastMessages = messages;
    final content = calls == 1
        ? {
            'action': 'tool',
            'public_update': '读取生成的 Excel 文件。',
            'tool': {
              'name': 'workspace.read',
              'arguments': {'path': path},
            },
            'completion': null,
          }
        : {
            'action': 'finish',
            'public_update': 'Excel 已读取并核对。',
            'tool': null,
            'completion': {
              'summary': 'Excel 已读取并核对。',
              'evidence': ['已获得工作表和单元格内容'],
            },
          };
    return {'success': true, 'message': jsonEncode(content)};
  }
}

class _MissingMutationCommandGateway extends AiRequestGateway {
  final String executable;

  _MissingMutationCommandGateway({this.executable = 'insta'})
      : super(
          store: MemoryGovernanceStore(),
          client: _UnusedClient(),
        );

  int calls = 0;

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
    final content = calls == 1
        ? {
            'action': 'tool',
            'public_update': '检查缺失工具。',
            'tool': {
              'name': 'command.run',
              'arguments': {
                'executable': executable,
                'arguments': <String>[],
                'workingDirectory': '.',
                'declaredImpact': <String>['.'],
              },
            },
            'completion': null,
          }
        : {
            'action': 'finish',
            'public_update': '检查完成。',
            'tool': null,
            'completion': {
              'summary': '缺失工具检查完成。',
              'evidence': ['工具状态已记录'],
            },
          };
    return {'success': true, 'message': jsonEncode(content)};
  }
}

class _ReadOnlyCommandGateway extends AiRequestGateway {
  final String workingDirectory;
  int calls = 0;

  _ReadOnlyCommandGateway({this.workingDirectory = '.'})
      : super(
          store: MemoryGovernanceStore(),
          client: _UnusedClient(),
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
    final content = calls == 1
        ? {
            'action': 'tool',
            'public_update': '读取当前工作目录。',
            'tool': {
              'name': 'command.run',
              'arguments': {
                'executable': 'pwd',
                'arguments': <String>[],
                'workingDirectory': workingDirectory,
                'declaredImpact': <String>['.'],
              },
            },
            'completion': null,
          }
        : {
            'action': 'finish',
            'public_update': '已完成只读检查。',
            'tool': null,
            'completion': {
              'summary': '当前工作目录已读取。',
              'evidence': ['命令已返回'],
            },
          };
    return {'success': true, 'message': jsonEncode(content)};
  }
}

class _SensitiveGateway extends AiRequestGateway {
  final String toolName;
  final Map<String, dynamic> arguments;
  int calls = 0;

  _SensitiveGateway({required this.toolName, required this.arguments})
      : super(
          store: MemoryGovernanceStore(),
          client: _UnusedClient(),
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
    return {
      'success': true,
      'message': calls == 1
          ? jsonEncode({
              'action': 'tool',
              'public_update': '读取敏感文件。',
              'tool': {'name': toolName, 'arguments': arguments},
              'completion': null,
            })
          : jsonEncode({
              'action': 'finish',
              'public_update': '已按用户决定继续。',
              'tool': null,
              'completion': {
                'summary': '敏感读取已按用户决定跳过。',
                'evidence': ['未暴露敏感内容'],
              },
            }),
    };
  }
}

/// Writes a script, runs it, then keeps asking for more work. The real process
/// is stubbed to write the declared deliverable, so the only way this task can
/// end is the artifact-contract auto-completion.
class _ScriptArtifactGateway extends AiRequestGateway {
  static const String scriptName = 'generate_ranking.py';
  static const String artifactName = '大模型排名.xlsx';

  /// The file the stubbed process actually writes. Setting it to a name other
  /// than [artifactName] reproduces a model that declares one path to
  /// `command.run` while its script writes another.
  final String writtenName;

  /// Whether the model declares completion once the command returns, instead of
  /// asking for another inspection round.
  final bool finishAfterCommand;

  int calls = 0;

  _ScriptArtifactGateway({
    String? writtenName,
    this.finishAfterCommand = false,
  })  : writtenName = writtenName ?? artifactName,
        super(
          store: MemoryGovernanceStore(),
          client: _UnusedClient(),
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
    final content = switch (calls) {
      1 => {
          'action': 'tool',
          'public_update': '正在写入生成脚本。',
          'tool': {
            'name': 'workspace.patch',
            'arguments': {
              'path': scriptName,
              'content': 'print("ranking")',
            },
          },
          'completion': null,
        },
      2 => {
          'action': 'tool',
          'public_update': '正在运行脚本生成排名表。',
          'tool': {
            'name': 'command.run',
            'arguments': {
              'executable': 'python3',
              'arguments': <String>[scriptName],
              'workingDirectory': '',
              'declaredImpact': <String>[artifactName],
            },
          },
          'completion': null,
        },
      _ when finishAfterCommand => {
          'action': 'finish',
          'public_update': '文件已生成。',
          'tool': null,
          'completion': {
            'summary': '文件已生成到桌面：$writtenName。',
            'evidence': ['command.run 报告脚本执行完成'],
          },
        },
      _ => {
          'action': 'tool',
          'public_update': '正在再次核对产物。',
          'tool': {
            'name': 'workspace.list',
            'arguments': <String, dynamic>{},
          },
          'completion': null,
        },
    };
    return {'success': true, 'message': jsonEncode(content)};
  }
}

/// The gateway override above never reaches a transport, but the concrete
/// gateway still requires a client in its constructor.
class _UnusedClient extends ChatApiService {}

/// Returns the given argument spellings for `workspace.list.path` on the first
/// call, then finishes. A null entry means the model omitted the field.
class _WorkspaceListPathGateway extends AiRequestGateway {
  final List<Object?> pathArguments;
  int calls = 0;

  _WorkspaceListPathGateway(this.pathArguments)
      : super(
          store: MemoryGovernanceStore(),
          client: _UnusedClient(),
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
    final index = calls - 1;
    if (index >= pathArguments.length) {
      return {
        'success': true,
        'message': jsonEncode({
          'action': 'finish',
          'public_update': '目录已核对。',
          'tool': null,
          'completion': {
            'summary': '已读取工作区根目录。',
            'evidence': ['workspace.list 返回了目录条目'],
          },
        }),
      };
    }
    final raw = pathArguments[index];
    final arguments = <String, dynamic>{'recursive': false};
    if (raw != null) arguments['path'] = raw;
    return {
      'success': true,
      'message': jsonEncode({
        'action': 'tool',
        'public_update': '正在查看工作区目录。',
        'tool': {'name': 'workspace.list', 'arguments': arguments},
        'completion': null,
      }),
    };
  }
}

void main() {
  late DatabaseService database;
  late WorkTaskEventStore eventStore;
  late Directory hiveDirectory;
  late Directory authorizedDirectory;

  setUp(() async {
    hiveDirectory = await openLifecycleHive();
    database = DatabaseService();
    eventStore = WorkTaskEventStore(
      appSupportDirectory: Directory('${hiveDirectory.path}/app-support'),
    );
    authorizedDirectory =
        await Directory('${hiveDirectory.path}/authorized').create();
  });

  tearDown(() async {
    await eventStore.close();
    await closeLifecycleHive(hiveDirectory, database);
  });

  test('runner does not rewrite a terminal task through discussion validation',
      () async {
    final runner = DefaultWorkTaskRunner(
      database: database,
      eventStore: eventStore,
      credentials: _TestCredentials(),
    );
    final task = AgentTask(
      id: 'terminal-runner-discussion',
      groupId: 'terminal-runner-group',
      characterId: 'missing-character',
      userRequest: '不应重新执行',
      status: AgentTaskStatus.failed,
      workModeTask: true,
      executionStateJson: '{malformed discussion checkpoint',
    );

    await runner.run(task, WorkTaskCancellation());

    expect(task.status, AgentTaskStatus.failed);
    expect(task.executionStateJson, '{malformed discussion checkpoint');
  });

  test('model completion has a cancellable total deadline', () async {
    final grants = WorkFolderGrantService(
      box: database.appSettingsBox,
      directoryValidator: (_) async => true,
      writeDirectoryValidator: (_) async => true,
      isWindows: false,
    );
    await grants.authorizeDirectory(
      authorizedDirectory.path,
      consent: (_) async => true,
    );
    final pathPolicy = WorkspacePathPolicy(grantService: grants);
    final config = ApiConfig(
      id: 'model-deadline-config',
      name: 'Model deadline test config',
      provider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
    );
    final character = AICharacter(
      id: 'model-deadline-character',
      name: 'Model deadline character',
      avatar: 'D',
      age: 30,
      role: '测试超时处理',
      personalityTags: const [],
      systemPrompt: '只按工具协议工作。',
      apiKey: '',
      apiProvider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
      apiConfigId: config.id,
    );
    await database.apiConfigBox.put(config.id, config);
    await database.aiCharacterBox.put(character.id, character);

    final gateway = _HangingModelGateway();
    final runner = DefaultWorkTaskRunner(
      database: database,
      eventStore: eventStore,
      credentials: _TestCredentials(),
      gateway: gateway,
      workspaceService: WorkModeWorkspaceService(
        db: database,
        grantService: grants,
      ),
      folderGrantService: grants,
      workspaceFileService: WorkspaceFileService(pathPolicy: pathPolicy),
      mutationService: WorkspaceMutationService(pathPolicy: pathPolicy),
      modelCompletionTimeout: const Duration(milliseconds: 20),
    );
    final task = AgentTask(
      id: 'model-deadline-task',
      groupId: 'model-deadline-group',
      characterId: character.id,
      userRequest: '验证模型请求超时后能够安全重试',
      workModeTask: true,
    );

    await runner.run(task, WorkTaskCancellation());

    expect(task.status, AgentTaskStatus.failed);
    expect(gateway.requestTokens, hasLength(3));
    expect(gateway.requestTokens.toSet(), hasLength(3));
    expect(gateway.requestTokens.every((token) => token.isCancelled), isTrue);
    expect(task.workFailure?.type, WorkFailureType.retryableNetwork);
    expect(task.workFailure?.retryable, isTrue);
  });

  test('production runner routes approved workspace.patch through Stage02',
      () async {
    final grants = WorkFolderGrantService(
      box: database.appSettingsBox,
      directoryValidator: (_) async => true,
      isWindows: false,
    );
    final grant = await grants.authorizeDirectory(
      authorizedDirectory.path,
      consent: (_) async => true,
    );
    expect(grant, isNotNull);
    final pathPolicy = WorkspacePathPolicy(grantService: grants);
    final files = WorkspaceFileService(pathPolicy: pathPolicy);
    final snapshots = WorkSnapshotService(
      appSupportDirectory: Directory('${hiveDirectory.path}/app-support'),
      pathPolicy: pathPolicy,
    );
    final mutations = WorkspaceMutationService(
      pathPolicy: pathPolicy,
      snapshotPort: snapshots,
    );
    final gateway = _SequencedGateway();
    final config = ApiConfig(
      id: 'stage02-config',
      name: 'Stage02 test config',
      provider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
    );
    final character = AICharacter(
      id: 'stage02-character',
      name: 'Stage02 character',
      avatar: 'S2',
      age: 30,
      role: '测试执行角色',
      personalityTags: const [],
      systemPrompt: '只按工具协议工作。',
      apiKey: '',
      apiProvider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
      apiConfigId: config.id,
      toolPermissions: const [
        ToolPermission.workspaceRead,
        ToolPermission.workspacePatch,
      ],
    );
    await database.apiConfigBox.put(config.id, config);
    await database.aiCharacterBox.put(character.id, character);

    final runner = DefaultWorkTaskRunner(
      database: database,
      eventStore: eventStore,
      credentials: _TestCredentials(),
      gateway: gateway,
      workspaceService: WorkModeWorkspaceService(
        db: database,
        grantService: grants,
      ),
      folderGrantService: grants,
      workspaceFileService: files,
      mutationService: mutations,
    );
    final task = AgentTask(
      id: 'stage02-runner-task',
      groupId: 'stage02-group',
      characterId: character.id,
      userRequest: '请处理这个需求',
      workModeTask: true,
    );

    await runner.run(task, WorkTaskCancellation());

    expect(task.status, AgentTaskStatus.waitingForApproval);
    final publicEvents = (await eventStore.read(task.id)).events;
    expect(
      publicEvents.any(
        (event) =>
            event.kind == WorkTaskEventKind.toolOutput &&
            event.safeMetadata['pending'] == true,
      ),
      isTrue,
    );
    expect(
      publicEvents.any(
        (event) =>
            event.kind == WorkTaskEventKind.modelOutput &&
            event.detail == '准备写入授权目录文件。',
      ),
      isTrue,
    );
    // The pending request is held in the runner while the task checkpoint is
    // persisted; this assertion also proves the first model turn was parsed.
    expect(task.pendingToolRequestJson, contains('workspace.patch'));
    expect(task.executionStateJson, contains('approvalScope'));
    final pendingSummary = jsonDecode(task.contextSummary) as Map;
    expect(pendingSummary['schemaVersion'], 1);
    expect(pendingSummary['conversationId'], 'stage02-group');
    expect(pendingSummary['target'], '请处理这个需求');
    expect(pendingSummary['artifactPaths'], isEmpty);
    expect(
      await File(
        '${authorizedDirectory.path}/conversations/group_stage02-group/notes.txt',
      ).exists(),
      isFalse,
    );

    final checkpoint = jsonDecode(task.executionStateJson) as Map;
    task.executionStateJson = jsonEncode({
      ...checkpoint,
      'approvalDecision': 'approved',
    });
    task.status = AgentTaskStatus.queued;
    await database.agentTaskBox.put(task.id, task);
    await runner.run(task, WorkTaskCancellation());

    final output = File(
      '${authorizedDirectory.path}/conversations/group_stage02-group/notes.txt',
    );
    expect(task.status, AgentTaskStatus.completed);
    final completedSummary = jsonDecode(task.contextSummary) as Map;
    expect(completedSummary['conversationId'], 'stage02-group');
    expect(completedSummary['completedSummaries'], isNotEmpty);
    expect(
      (completedSummary['artifactPaths'] as List)
          .whereType<String>()
          .any((path) => path.endsWith('/notes.txt')),
      isTrue,
    );
    expect(await output.readAsString(), 'production-stage02');
    expect(gateway.calls, 2);
    expect((await snapshots.readManifest(task.id))?.actions.single.completed,
        isTrue);
    expect((await snapshots.undo(task.id)).succeeded, isTrue);
    expect(await output.exists(), isFalse);
  });

  test('QA revision can write its report but cannot mutate the HTML input',
      () async {
    final grants = WorkFolderGrantService(
      box: database.appSettingsBox,
      directoryValidator: (_) async => true,
      writeDirectoryValidator: (_) async => true,
      isWindows: false,
    );
    await grants.authorizeDirectory(
      authorizedDirectory.path,
      consent: (_) async => true,
    );
    await grants.setOrdinaryWriteConfirmation(false);
    final pathPolicy = WorkspacePathPolicy(grantService: grants);
    final files = WorkspaceFileService(pathPolicy: pathPolicy);
    final snapshots = WorkSnapshotService(
      appSupportDirectory: Directory('${hiveDirectory.path}/app-support'),
      pathPolicy: pathPolicy,
    );
    final mutations = WorkspaceMutationService(
      pathPolicy: pathPolicy,
      snapshotPort: snapshots,
    );
    final workspaceService = WorkModeWorkspaceService(
      db: database,
      grantService: grants,
    );
    const groupId = 'qa-stage02-group';
    final workspace = await workspaceService.loadOrCreate(
      conversationId: groupId,
      isDirectChat: false,
      requireWritable: true,
    );
    const originalHtml = '<html><body>original game</body></html>';
    final htmlInput = File('${workspace.workDirPath}/doudizhu_game.html');
    await htmlInput.writeAsString(originalHtml);

    final config = ApiConfig(
      id: 'qa-stage02-config',
      name: 'QA Stage02 test config',
      provider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
    );
    final character = AICharacter(
      id: 'qa-stage02-tester',
      name: 'QA tester',
      avatar: 'QA',
      age: 30,
      role: '测试工程师',
      personalityTags: const [],
      systemPrompt: '只按工具协议工作。',
      apiKey: '',
      apiProvider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
      apiConfigId: config.id,
      toolPermissions: const [
        ToolPermission.workspaceRead,
        ToolPermission.workspacePatch,
        ToolPermission.skillCreate,
      ],
    );
    await database.apiConfigBox.put(config.id, config);
    await database.aiCharacterBox.put(character.id, character);
    await database.chatGroupBox.put(
      groupId,
      ChatGroup(
        id: groupId,
        name: 'QA 测试群',
        theme: '斗地主验收',
        aiCharacterIds: [character.id],
      ),
    );
    const qaScope = 'Test the existing doudizhu_game.html against '
        'doudizhu_design.md and create doudizhu_test_report.md.';
    const historicalRequest = 'Create the playable HTML game at '
        'Desktop/doudizhu_game.html. 用户补充要求：$qaScope';
    final discussion = WorkDiscussionState.initial(
      conversationId: groupId,
      requestRevision: 2,
      coordinatorId: character.id,
      executorId: character.id,
      candidateCharacterIds: [character.id],
      participantCharacterIds: [character.id],
      deliverableContract: const <String, dynamic>{
        'deliverableType': 'document',
        'format': 'markdown',
        'location': 'doudizhu_test_report.md',
        'contentScope': qaScope,
        'explicitExecutorId': null,
        'revisionTarget': '',
        'requestRevision': 2,
      },
    ).copyWith(
      phase: WorkDiscussionPhase.ready,
      understandingPercent: 100,
      understandingEvidence: const [
        '测试对象是现有 HTML。',
        '当前输出是 Markdown 测试报告。',
        '测试阶段只记录缺陷，修复另行启动。',
      ],
      openQuestions: const [],
      blockers: const [],
    );
    final discussionState = WorkDiscussionState.mergeIntoExecutionState(
      '',
      discussion,
    );
    final mediaDirectory =
        await Directory('${hiveDirectory.path}/qa-stage02-media').create();
    var mediaCopyIndex = 0;
    AgentTask qaTask(String id) => AgentTask(
          id: id,
          groupId: groupId,
          characterId: character.id,
          userRequest: historicalRequest,
          assignedCharacterIds: [character.id],
          workModeTask: true,
          executionStateJson: discussionState,
        );
    DefaultWorkTaskRunner runnerFor(AiRequestGateway gateway) =>
        DefaultWorkTaskRunner(
          database: database,
          eventStore: eventStore,
          credentials: _TestCredentials(),
          gateway: gateway,
          workspaceService: workspaceService,
          folderGrantService: grants,
          workspaceFileService: files,
          mutationService: mutations,
          mediaCopier: (source, type, {fileName}) async {
            final target = File(
              '${mediaDirectory.path}/${mediaCopyIndex++}-${fileName ?? 'attachment'}',
            );
            await source.copy(target.path);
            return MediaAttachment(
              type: type,
              localPath: target.path,
              fileName: fileName,
              fileSize: await target.length(),
            );
          },
        );
    final blockedGateway = _MultiPatchGateway(const [
      {'path': 'doudizhu_game.html', 'content': '<html>premature edit</html>'},
    ]);
    final blockedTask = qaTask('qa-stage02-blocked-task');

    await runnerFor(blockedGateway).run(
      blockedTask,
      WorkTaskCancellation(),
    );

    expect(
      blockedTask.status,
      AgentTaskStatus.failed,
      reason:
          '${blockedTask.lastError}; ${blockedTask.resultSummary}; gateway calls=${blockedGateway.calls}',
    );
    expect(await htmlInput.readAsString(), originalHtml);
    expect(blockedGateway.calls, 1);

    final reportTask = qaTask('qa-stage02-report-task');
    final reportGateway = _MultiPatchGateway(const [
      {
        'path': 'doudizhu_test_report.md',
        'content': '# QA report\n\nTests executed: 30.\n',
      },
    ]);
    await runnerFor(reportGateway).run(
      reportTask,
      WorkTaskCancellation(),
    );

    expect(
      reportTask.status,
      AgentTaskStatus.completed,
      reason:
          '${reportTask.lastError}; ${reportTask.resultSummary}; gateway calls=${reportGateway.calls}',
    );
    expect(
      await File('${workspace.workDirPath}/doudizhu_test_report.md')
          .readAsString(),
      contains('Tests executed: 30.'),
    );

    final reportFile = File('${workspace.workDirPath}/doudizhu_test_report.md');
    final reportBeforeDelete = await reportFile.readAsString();
    final deleteGateway = _SingleToolGateway(
      AgentToolName.workspaceDelete,
      {'path': 'doudizhu_test_report.md'},
    );
    final deleteTask = qaTask('qa-stage02-delete-report-task');
    await runnerFor(deleteGateway).run(deleteTask, WorkTaskCancellation());
    expect(deleteTask.status, AgentTaskStatus.failed);
    expect(await reportFile.readAsString(), reportBeforeDelete);

    final renameGateway = _SingleToolGateway(
      AgentToolName.workspaceRename,
      {
        'path': 'doudizhu_test_report.md',
        'destinationPath': 'renamed_report.md',
      },
    );
    final renameTask = qaTask('qa-stage02-rename-report-task');
    await runnerFor(renameGateway).run(renameTask, WorkTaskCancellation());
    expect(renameTask.status, AgentTaskStatus.failed);
    expect(await reportFile.readAsString(), reportBeforeDelete);
    expect(
      await File('${workspace.workDirPath}/renamed_report.md').exists(),
      isFalse,
    );

    final skillGateway = _SingleToolGateway(
      AgentToolName.skillCreate,
      {
        'name': 'qa-helper',
        'domain': 'testing',
        'description': 'Must not be installed during QA.',
        'instructions': ['No mutation during QA.'],
      },
    );
    final skillTask = qaTask('qa-stage02-skill-mutation-task');
    await runnerFor(skillGateway).run(skillTask, WorkTaskCancellation());
    expect(skillTask.status, AgentTaskStatus.failed);
    expect(skillGateway.calls, 1);
  });

  test('production runner refreshes Stage02 approval between file mutations',
      () async {
    final grants = WorkFolderGrantService(
      box: database.appSettingsBox,
      directoryValidator: (_) async => true,
      writeDirectoryValidator: (_) async => true,
      isWindows: false,
    );
    expect(
      await grants.authorizeDirectory(
        authorizedDirectory.path,
        consent: (_) async => true,
      ),
      isNotNull,
    );
    final pathPolicy = WorkspacePathPolicy(grantService: grants);
    final files = WorkspaceFileService(pathPolicy: pathPolicy);
    final snapshots = WorkSnapshotService(
      appSupportDirectory: Directory('${hiveDirectory.path}/app-support'),
      pathPolicy: pathPolicy,
    );
    final mutations = WorkspaceMutationService(
      pathPolicy: pathPolicy,
      snapshotPort: snapshots,
    );
    final mediaDirectory =
        await Directory('${hiveDirectory.path}/stage02-refresh-media').create();
    var mediaCopyIndex = 0;
    final gateway = _MultiPatchGateway(const [
      {'path': 'first.txt', 'content': 'first'},
      {'path': 'second.txt', 'content': 'second'},
    ]);
    final config = ApiConfig(
      id: 'stage02-refresh-config',
      name: 'Stage02 refresh test config',
      provider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
    );
    final character = AICharacter(
      id: 'stage02-refresh-character',
      name: 'Stage02 refresh character',
      avatar: 'R',
      age: 30,
      role: '测试连续写入角色',
      personalityTags: const [],
      systemPrompt: '只按工具协议工作。',
      apiKey: '',
      apiProvider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
      apiConfigId: config.id,
      toolPermissions: const [
        ToolPermission.workspaceRead,
        ToolPermission.workspacePatch,
      ],
    );
    await database.apiConfigBox.put(config.id, config);
    await database.aiCharacterBox.put(character.id, character);

    final runner = DefaultWorkTaskRunner(
      database: database,
      eventStore: eventStore,
      credentials: _TestCredentials(),
      gateway: gateway,
      workspaceService: WorkModeWorkspaceService(
        db: database,
        grantService: grants,
      ),
      folderGrantService: grants,
      workspaceFileService: files,
      mutationService: mutations,
      mediaCopier: (source, type, {fileName}) async {
        final target = File(
          '${mediaDirectory.path}/${mediaCopyIndex++}-${fileName ?? 'attachment'}',
        );
        await source.copy(target.path);
        return MediaAttachment(
          type: type,
          localPath: target.path,
          fileName: fileName,
          fileSize: await target.length(),
        );
      },
    );
    final task = AgentTask(
      id: 'stage02-refresh-task',
      groupId: 'stage02-refresh-group',
      characterId: character.id,
      userRequest: '生成多个文件并交付全部文件',
      workModeTask: true,
    );

    await runner.run(task, WorkTaskCancellation());
    expect(task.status, AgentTaskStatus.waitingForApproval);
    final firstCheckpoint = jsonDecode(task.executionStateJson) as Map;
    // Start from the least prompting configuration so the assertions below
    // prove the refresh comes from the scope policy and not from the
    // ordinary-write toggle.
    await grants.setOrdinaryWriteConfirmation(false);
    task
      ..executionStateJson = jsonEncode({
        ...firstCheckpoint,
        'approvalDecision': 'approved',
      })
      ..status = AgentTaskStatus.queued;
    await database.agentTaskBox.put(task.id, task);

    final workspace = await WorkModeWorkspaceService(
      db: database,
      grantService: grants,
    ).loadOrCreate(
      conversationId: task.groupId,
      isDirectChat: false,
      requireWritable: true,
    );

    await runner.run(task, WorkTaskCancellation());

    // The first approval covers first.txt only. second.txt is a new path, so
    // the refreshed scope demands its own approval even though ordinary-write
    // confirmation is off.
    expect(task.status, AgentTaskStatus.waitingForApproval);
    expect(
      await File('${workspace.workDirPath}/first.txt').readAsString(),
      'first',
    );
    expect(await File('${workspace.workDirPath}/second.txt').exists(), isFalse);
    expect(task.pendingToolRequestJson, contains('workspace.patch'));
    final secondCheckpoint = jsonDecode(task.executionStateJson) as Map;
    final secondPlan = WorkChangePlan.fromJson(
      Map<String, dynamic>.from(secondCheckpoint['approvalPlan'] as Map),
    );
    // Mirrors the coordinator's own decision record: approving a plan replaces
    // the task scope with the plan the user actually reviewed.
    task
      ..executionStateJson = jsonEncode({
        ...secondCheckpoint,
        'approvalDecision': 'approved',
        'approvalScope': WorkApprovalScope.fromPlan(secondPlan).toJson(),
      })
      ..status = AgentTaskStatus.queued;
    await database.agentTaskBox.put(task.id, task);

    await runner.run(task, WorkTaskCancellation());

    expect(
      task.status,
      AgentTaskStatus.completed,
      reason: '${task.lastError}; ${task.resultSummary}',
    );
    expect(
      await File('${workspace.workDirPath}/first.txt').readAsString(),
      'first',
    );
    expect(
      await File('${workspace.workDirPath}/second.txt').readAsString(),
      'second',
    );
    expect(gateway.calls, 3);
  });

  test('production runner does not use implicit scope for a foreign approval',
      () async {
    final grants = WorkFolderGrantService(
      box: database.appSettingsBox,
      directoryValidator: (_) async => true,
      writeDirectoryValidator: (_) async => true,
      isWindows: false,
    );
    expect(
      await grants.authorizeDirectory(
        authorizedDirectory.path,
        consent: (_) async => true,
      ),
      isNotNull,
    );
    await grants.setOrdinaryWriteConfirmation(false);
    final pathPolicy = WorkspacePathPolicy(grantService: grants);
    final files = WorkspaceFileService(pathPolicy: pathPolicy);
    final mutations = WorkspaceMutationService(
      pathPolicy: pathPolicy,
      snapshotPort: WorkSnapshotService(
        appSupportDirectory: Directory('${hiveDirectory.path}/app-support'),
        pathPolicy: pathPolicy,
      ),
    );
    final foreignPlan = WorkChangePlan(
      taskId: 'foreign-approval-task',
      actionType: WorkChangeActionType.create,
      exactPaths: <String>['${authorizedDirectory.path}/foreign.txt'],
      knownAffectedDirectories: <String>[authorizedDirectory.path],
      estimatedBytes: 1,
      snapshotAvailable: true,
      reversible: true,
      riskReason: '测试失配审批范围',
    );
    final config = ApiConfig(
      id: 'foreign-approval-config',
      name: 'Foreign approval test config',
      provider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
    );
    final character = AICharacter(
      id: 'foreign-approval-character',
      name: 'Foreign approval character',
      avatar: 'F',
      age: 30,
      role: '审批边界测试角色',
      personalityTags: const [],
      systemPrompt: '只按工具协议工作。',
      apiKey: '',
      apiProvider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
      apiConfigId: config.id,
      toolPermissions: const [
        ToolPermission.workspaceRead,
        ToolPermission.workspacePatch,
      ],
    );
    await database.apiConfigBox.put(config.id, config);
    await database.aiCharacterBox.put(character.id, character);
    final gateway = _SequencedGateway(
      patchPath: 'second.txt',
      patchContent: 'must-not-write',
    );
    final runner = DefaultWorkTaskRunner(
      database: database,
      eventStore: eventStore,
      credentials: _TestCredentials(),
      gateway: gateway,
      workspaceService: WorkModeWorkspaceService(
        db: database,
        grantService: grants,
      ),
      folderGrantService: grants,
      workspaceFileService: files,
      mutationService: mutations,
    );
    final task = AgentTask(
      id: 'foreign-approval-task-under-test',
      groupId: 'foreign-approval-group',
      characterId: character.id,
      userRequest: '请执行工作',
      workModeTask: true,
      status: AgentTaskStatus.queued,
      executionStateJson: jsonEncode(<String, dynamic>{
        'approvalDecision': 'approved',
        'approvalCapability': WorkApprovalCapability.mutation,
        'approvalScope': WorkApprovalScope.fromPlan(foreignPlan).toJson(),
        'approvalOperationFingerprint': 'not-the-current-operation',
      }),
    );

    await runner.run(task, WorkTaskCancellation());

    final workspace = await WorkModeWorkspaceService(
      db: database,
      grantService: grants,
    ).loadOrCreate(
      conversationId: task.groupId,
      isDirectChat: false,
      requireWritable: true,
    );
    expect(task.status, AgentTaskStatus.failed);
    expect(
      await File('${workspace.workDirPath}/second.txt').exists(),
      isFalse,
    );
  });

  test(
      'HTML artifact auto-completes after verified write without extra model turn',
      () async {
    final grants = WorkFolderGrantService(
      box: database.appSettingsBox,
      directoryValidator: (_) async => true,
      writeDirectoryValidator: (_) async => true,
      isWindows: false,
    );
    expect(
      await grants.authorizeDirectory(
        authorizedDirectory.path,
        consent: (_) async => true,
      ),
      isNotNull,
    );
    final pathPolicy = WorkspacePathPolicy(grantService: grants);
    final files = WorkspaceFileService(pathPolicy: pathPolicy);
    final mutations = WorkspaceMutationService(
      pathPolicy: pathPolicy,
      snapshotPort: WorkSnapshotService(
        appSupportDirectory: Directory('${hiveDirectory.path}/app-support'),
        pathPolicy: pathPolicy,
      ),
    );
    final mediaDirectory =
        await Directory('${hiveDirectory.path}/html-media').create();
    final gateway = _SequencedGateway(
      patchPath: 'page.html',
      patchContent:
          '<!doctype html><html><body><main>交互页面</main></body></html>',
    );
    final config = ApiConfig(
      id: 'html-auto-complete-config',
      name: 'HTML auto-complete config',
      provider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
    );
    final character = AICharacter(
      id: 'html-auto-complete-character',
      name: '前端执行角色',
      avatar: 'H',
      age: 30,
      role: '前端工程师',
      personalityTags: const [],
      systemPrompt: '只按工具协议工作。',
      apiKey: '',
      apiProvider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
      apiConfigId: config.id,
      toolPermissions: const [
        ToolPermission.workspaceRead,
        ToolPermission.workspacePatch,
      ],
    );
    final template = ExpertSkillCatalog.findById(
      'frontend.interactive-artifact',
    )!;
    final installedSkill = template.instantiateFor(character.id);
    character.skillIds = [installedSkill.id];
    await database.characterSkillBox.put(installedSkill.id, installedSkill);
    await database.apiConfigBox.put(config.id, config);
    await database.aiCharacterBox.put(character.id, character);

    final runner = DefaultWorkTaskRunner(
      database: database,
      eventStore: eventStore,
      credentials: _TestCredentials(),
      gateway: gateway,
      workspaceService: WorkModeWorkspaceService(
        db: database,
        grantService: grants,
      ),
      folderGrantService: grants,
      workspaceFileService: files,
      mutationService: mutations,
      mediaCopier: (source, type, {fileName}) async {
        final target = File(
          '${mediaDirectory.path}/${fileName ?? 'artifact.html'}',
        );
        await source.copy(target.path);
        return MediaAttachment(
          type: type,
          localPath: target.path,
          fileName: fileName,
          fileSize: await target.length(),
          mimeType: 'text/html',
        );
      },
    );
    final task = AgentTask(
      id: 'html-auto-complete-task',
      groupId: 'html-auto-complete-group',
      characterId: character.id,
      userRequest: '生成一个 HTML 页面并保存到 page.html',
      workModeTask: true,
    );

    await runner.run(task, WorkTaskCancellation());
    expect(task.status, AgentTaskStatus.waitingForApproval);
    final checkpoint = jsonDecode(task.executionStateJson) as Map;
    task
      ..executionStateJson = jsonEncode({
        ...checkpoint,
        'approvalDecision': 'approved',
      })
      ..status = AgentTaskStatus.queued;
    await runner.run(task, WorkTaskCancellation());

    expect(task.status, AgentTaskStatus.completed,
        reason: '${task.lastError}; ${task.resultSummary}');
    expect(gateway.calls, 1, reason: '写入并回读通过后不应再向模型请求一个可能失真的 finish。');
    final output = File(task.lastArtifactPaths.single);
    expect(await output.readAsString(), contains('<html>'));
    final message = database.messageBox.values
        .where((item) => item.groupId == task.groupId)
        .last;
    expect(message.media, hasLength(1),
        reason: 'content=${message.content} '
            'artifacts=${task.lastArtifactPaths} '
            'status=${task.status} error=${task.lastError}');
    expect(message.media!.single.localPath, output.path);
    expect(message.media!.single.cachePath, isNotNull);
  });

  test('visual model supplies capability without changing the elected executor',
      () async {
    final grants = WorkFolderGrantService(
      box: database.appSettingsBox,
      directoryValidator: (_) async => true,
      isWindows: false,
    );
    final grant = await grants.authorizeDirectory(
      authorizedDirectory.path,
      consent: (_) async => true,
    );
    expect(grant, isNotNull);
    final pathPolicy = WorkspacePathPolicy(grantService: grants);
    final files = WorkspaceFileService(pathPolicy: pathPolicy);
    final snapshots = WorkSnapshotService(
      appSupportDirectory: Directory('${hiveDirectory.path}/app-support'),
      pathPolicy: pathPolicy,
    );
    final mutations = WorkspaceMutationService(
      pathPolicy: pathPolicy,
      snapshotPort: snapshots,
    );
    final gateway = _SequencedGateway();
    final config = ApiConfig(
      id: 'stage02-config',
      name: 'Stage02 test config',
      provider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
    );
    final character = AICharacter(
      id: 'stage02-character',
      name: 'Stage02 character',
      avatar: 'S2',
      age: 30,
      role: '产品经理',
      personalityTags: const [],
      systemPrompt: '只按工具协议工作。',
      apiKey: '',
      apiProvider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
      apiConfigId: config.id,
      toolPermissions: const [
        ToolPermission.workspaceRead,
        ToolPermission.workspacePatch,
      ],
    );
    await database.apiConfigBox.put(config.id, config);
    await database.aiCharacterBox.put(character.id, character);

    final visualConfig = ApiConfig(
        id: 'visual-config',
        name: 'visual',
        provider: 'qwen',
        modelName: 'qwen-vl-max',
        hasCredential: true,
        credentialId: 'visual-credential');
    final visualCharacter = AICharacter(
        id: 'visual-character',
        name: '视觉助手',
        avatar: 'V',
        age: 30,
        role: '设计师',
        personalityTags: const [],
        systemPrompt: '不应该替换执行人提示词',
        apiKey: '',
        apiProvider: 'qwen',
        modelName: 'qwen-vl-max',
        apiConfigId: visualConfig.id);
    await database.apiConfigBox.put(visualConfig.id, visualConfig);
    await database.aiCharacterBox.put(visualCharacter.id, visualCharacter);
    await database.chatGroupBox.put(
        'stage02-group',
        ChatGroup(
            id: 'stage02-group',
            name: '模型协作',
            theme: '',
            aiCharacterIds: [character.id, visualCharacter.id]));

    final runner = DefaultWorkTaskRunner(
      database: database,
      eventStore: eventStore,
      credentials: _TestCredentials(),
      gateway: gateway,
      workspaceService: WorkModeWorkspaceService(
        db: database,
        grantService: grants,
      ),
      folderGrantService: grants,
      workspaceFileService: files,
      mutationService: mutations,
    );
    final task = AgentTask(
      id: 'stage02-runner-task',
      groupId: 'stage02-group',
      characterId: character.id,
      userRequest: '请处理这个需求',
      workModeTask: true,
    );

    task.executionStateJson = WorkDiscussionState.mergeIntoExecutionState(
      jsonEncode({'visionModelCharacterId': visualCharacter.id}),
      WorkDiscussionState.initial(
        conversationId: task.groupId,
        executorId: character.id,
        candidateCharacterIds: [character.id],
        deliverableContract: {
          'deliverableType': 'document',
          'format': 'txt',
          'location': 'notes.txt',
          'contentScope': task.userRequest,
          'explicitExecutorId': character.id,
          'revisionTarget': '',
          'requestRevision': 1
        },
      ).copyWith(
        phase: WorkDiscussionPhase.ready,
        understandingPercent: 100,
        understandingEvidence: const [
          '已确认目标',
          '已确认交付位置',
          '执行人已确认工具路径',
        ],
        blockers: const [],
      ),
    );
    await runner.run(task, WorkTaskCancellation());

    expect(task.status, AgentTaskStatus.waitingForApproval);
    final publicEvents = (await eventStore.read(task.id)).events;
    expect(
      publicEvents.any(
        (event) =>
            event.kind == WorkTaskEventKind.toolOutput &&
            event.safeMetadata['pending'] == true,
      ),
      isTrue,
    );
    expect(
      publicEvents.any(
        (event) =>
            event.kind == WorkTaskEventKind.modelOutput &&
            event.detail == '准备写入授权目录文件。',
      ),
      isTrue,
    );
    // The pending request is held in the runner while the task checkpoint is
    // persisted; this assertion also proves the first model turn was parsed.
    expect(task.pendingToolRequestJson, contains('workspace.patch'));
    expect(task.executionStateJson, contains('approvalScope'));
    final pendingSummary = jsonDecode(task.contextSummary) as Map;
    expect(pendingSummary['schemaVersion'], 1);
    expect(pendingSummary['conversationId'], 'stage02-group');
    expect(pendingSummary['target'], '请处理这个需求');
    expect(pendingSummary['artifactPaths'], isEmpty);
    expect(
      await File(
        '${authorizedDirectory.path}/conversations/group_stage02-group/notes.txt',
      ).exists(),
      isFalse,
    );

    final checkpoint = jsonDecode(task.executionStateJson) as Map;
    task.executionStateJson = jsonEncode({
      ...checkpoint,
      'approvalDecision': 'approved',
    });
    task.status = AgentTaskStatus.queued;
    await database.agentTaskBox.put(task.id, task);
    await runner.run(task, WorkTaskCancellation());

    final output = File(
      '${authorizedDirectory.path}/conversations/group_stage02-group/notes.txt',
    );
    expect(task.status, AgentTaskStatus.completed);
    final completedSummary = jsonDecode(task.contextSummary) as Map;
    expect(completedSummary['conversationId'], 'stage02-group');
    expect(completedSummary['completedSummaries'], isNotEmpty);
    expect(
      (completedSummary['artifactPaths'] as List)
          .whereType<String>()
          .any((path) => path.endsWith('/notes.txt')),
      isTrue,
    );
    expect(await output.readAsString(), 'production-stage02');
    expect(gateway.calls, 2);
    expect(gateway.observedModels, everyElement('qwen-vl-max'));
    expect(gateway.observedCharacters, everyElement(character.id));
    expect(task.characterId, character.id);
    expect((await snapshots.readManifest(task.id))?.actions.single.completed,
        isTrue);
    expect((await snapshots.undo(task.id)).succeeded, isTrue);
    expect(await output.exists(), isFalse);
  });

  test(
      'keeps a saved artifact and marks delivery retryable when attachment copy fails',
      () async {
    final grants = WorkFolderGrantService(
      box: database.appSettingsBox,
      directoryValidator: (_) async => true,
      writeDirectoryValidator: (_) async => true,
      isWindows: false,
    );
    expect(
      await grants.authorizeDirectory(
        authorizedDirectory.path,
        consent: (_) async => true,
      ),
      isNotNull,
    );
    final pathPolicy = WorkspacePathPolicy(grantService: grants);
    final files = WorkspaceFileService(pathPolicy: pathPolicy);
    final snapshots = WorkSnapshotService(
      appSupportDirectory: Directory('${hiveDirectory.path}/app-support'),
      pathPolicy: pathPolicy,
      eventStore: eventStore,
    );
    final mutations = WorkspaceMutationService(
      pathPolicy: pathPolicy,
      snapshotPort: snapshots,
      eventStore: eventStore,
    );
    final config = ApiConfig(
      id: 'delivery-failure-config',
      name: 'Delivery failure config',
      provider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
    );
    final character = AICharacter(
      id: 'delivery-failure-character',
      name: '交付失败测试角色',
      avatar: 'D',
      age: 30,
      role: '文件交付测试角色',
      personalityTags: const [],
      systemPrompt: '只按工具协议工作。',
      apiKey: '',
      apiProvider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
      apiConfigId: config.id,
      toolPermissions: const [
        ToolPermission.workspaceRead,
        ToolPermission.workspacePatch,
      ],
    );
    await database.apiConfigBox.put(config.id, config);
    await database.aiCharacterBox.put(character.id, character);
    final gateway = _SequencedGateway(
      patchPath: 'delivery.txt',
      patchContent: 'saved-before-attachment-failure',
      finishSummary: '<!doctype html><html><body>模型原文</body></html>',
    );
    var attachmentCopyFails = true;
    final runner = DefaultWorkTaskRunner(
      database: database,
      eventStore: eventStore,
      credentials: _TestCredentials(),
      gateway: gateway,
      workspaceService: WorkModeWorkspaceService(
        db: database,
        grantService: grants,
      ),
      folderGrantService: grants,
      workspaceFileService: files,
      mutationService: mutations,
      mediaCopier: (source, type, {fileName}) async {
        if (attachmentCopyFails) {
          throw StateError('simulated attachment failure');
        }
        return MediaAttachment(
          id: 'retry-media-${gateway.calls}',
          type: type,
          localPath: source.path,
          fileName: fileName ?? source.uri.pathSegments.last,
          fileSize: await source.length(),
          mimeType: 'text/plain',
        );
      },
    );
    final task = AgentTask(
      id: 'delivery-failure-task',
      groupId: 'delivery-failure-group',
      characterId: character.id,
      userRequest: '生成一个文本文件 delivery.txt 并交付',
      workModeTask: true,
    );

    await runner.run(task, WorkTaskCancellation());
    expect(task.status, AgentTaskStatus.waitingForApproval);
    final checkpoint = jsonDecode(task.executionStateJson) as Map;
    task
      ..executionStateJson = jsonEncode({
        ...checkpoint,
        'approvalDecision': 'approved',
      })
      ..status = AgentTaskStatus.queued;
    await database.agentTaskBox.put(task.id, task);
    await runner.run(task, WorkTaskCancellation());

    final output = File(
      '${authorizedDirectory.path}/conversations/group_delivery-failure-group/delivery.txt',
    );
    expect(task.status, AgentTaskStatus.failed);
    expect(task.resumeRequired, isTrue);
    expect(task.workFailure?.retryable, isTrue);
    expect(task.workFailure?.reason, contains('附件'));
    expect(await output.readAsString(), 'saved-before-attachment-failure');
    final message = database.messageBox.values
        .where((item) => item.groupId == task.groupId)
        .last;
    final messageId = message.id;
    expect(message.content, contains('文件已保存'));
    expect(message.content, contains('可重试交付'));
    expect(message.content, isNot(contains('<!doctype html>')));
    expect(message.content, isNot(contains('模型原文')));
    expect(message.media, isNull);
    final failureMetadata = jsonDecode(task.executionStateJson) as Map;
    expect(failureMetadata['artifactDeliveryRetryOnly'], isTrue);
    expect(failureMetadata['artifactDeliveryMessageId'], messageId);

    // The retry is an attachment-only continuation. It must reuse the
    // existing final message and saved path without asking the model for a
    // second plan or applying the file mutation again.
    final modelCallsBeforeRetry = gateway.calls;
    attachmentCopyFails = false;
    task.status = AgentTaskStatus.queued;
    await database.agentTaskBox.put(task.id, task);
    await runner.run(task, WorkTaskCancellation());

    expect(task.status, AgentTaskStatus.completed);
    expect(gateway.calls, modelCallsBeforeRetry);
    final deliveredMessages = database.messageBox.values
        .where((item) => item.groupId == task.groupId)
        .toList(growable: false);
    expect(deliveredMessages, hasLength(1));
    expect(deliveredMessages.single.id, messageId);
    expect(deliveredMessages.single.media, isNotEmpty);
    expect(deliveredMessages.single.content, isNot(contains('可重试交付')));
    expect(
      (jsonDecode(task.executionStateJson) as Map)
          .containsKey('artifactDeliveryRetryOnly'),
      isFalse,
    );
  });

  test('partial artifact attachment failure cannot mark a file task complete',
      () async {
    final grants = WorkFolderGrantService(
      box: database.appSettingsBox,
      directoryValidator: (_) async => true,
      writeDirectoryValidator: (_) async => true,
      isWindows: false,
    );
    await grants.authorizeDirectory(
      authorizedDirectory.path,
      consent: (_) async => true,
    );
    final pathPolicy = WorkspacePathPolicy(grantService: grants);
    final files = WorkspaceFileService(pathPolicy: pathPolicy);
    final mutations = WorkspaceMutationService(pathPolicy: pathPolicy);
    final workspaceService = WorkModeWorkspaceService(
      db: database,
      grantService: grants,
    );
    final workspace = await workspaceService.loadOrCreate(
      conversationId: 'partial-delivery-group',
      isDirectChat: false,
    );
    final first = File('${workspace.workDirPath}/first.txt');
    final second = File('${workspace.workDirPath}/second.txt');
    await first.writeAsString('first');
    await second.writeAsString('second');

    final config = ApiConfig(
      id: 'partial-delivery-config',
      name: 'Partial delivery config',
      provider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
    );
    final character = AICharacter(
      id: 'partial-delivery-character',
      name: '部分交付测试角色',
      avatar: 'PD',
      age: 30,
      role: '文件交付测试角色',
      personalityTags: const [],
      systemPrompt: '只按工具协议工作。',
      apiKey: '',
      apiProvider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
      apiConfigId: config.id,
    );
    await database.apiConfigBox.put(config.id, config);
    await database.aiCharacterBox.put(character.id, character);

    final gateway = _MultiPatchGateway(const <Map<String, String>>[]);
    final copiedNames = <String>[];
    final runner = DefaultWorkTaskRunner(
      database: database,
      eventStore: eventStore,
      credentials: _TestCredentials(),
      gateway: gateway,
      workspaceService: workspaceService,
      folderGrantService: grants,
      workspaceFileService: files,
      mutationService: mutations,
      mediaCopier: (source, type, {fileName}) async {
        final name = fileName ?? source.uri.pathSegments.last;
        if (name == 'second.txt') {
          throw StateError('simulated partial attachment failure');
        }
        copiedNames.add(name);
        return MediaAttachment(
          id: 'partial-media-${copiedNames.length}',
          type: type,
          localPath: source.path,
          fileName: name,
          fileSize: await source.length(),
          mimeType: 'text/plain',
        );
      },
    );
    final task = AgentTask(
      id: 'partial-delivery-task',
      groupId: 'partial-delivery-group',
      characterId: character.id,
      userRequest: '生成两个文本文件并交付全部文件',
      workModeTask: true,
      startedAt: DateTime.now().subtract(const Duration(seconds: 1)),
      lastArtifactPaths: [first.path, second.path],
    );

    await runner.run(task, WorkTaskCancellation());

    expect(task.status, AgentTaskStatus.failed);
    expect(task.resumeRequired, isTrue);
    expect(task.workFailure?.reason, contains('附件'));
    expect(copiedNames, ['first.txt']);
    final metadata = jsonDecode(task.executionStateJson) as Map;
    expect(metadata['artifactDeliveryRetryOnly'], isTrue);
    expect(metadata['artifactDeliveryMessageId'], isNotEmpty);
  });

  test('samples token-level model progress before persisting it', () async {
    final grants = WorkFolderGrantService(
      box: database.appSettingsBox,
      directoryValidator: (_) async => true,
      isWindows: false,
    );
    expect(
      await grants.authorizeDirectory(
        authorizedDirectory.path,
        consent: (_) async => true,
      ),
      isNotNull,
    );
    final pathPolicy = WorkspacePathPolicy(grantService: grants);
    final files = WorkspaceFileService(pathPolicy: pathPolicy);
    final snapshots = WorkSnapshotService(
      appSupportDirectory: Directory('${hiveDirectory.path}/app-support'),
      pathPolicy: pathPolicy,
    );
    final mutations = WorkspaceMutationService(
      pathPolicy: pathPolicy,
      snapshotPort: snapshots,
    );
    final config = ApiConfig(
      id: 'progress-throttle-config',
      name: 'Progress throttle test config',
      provider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
    );
    final character = AICharacter(
      id: 'progress-throttle-character',
      name: 'Progress throttle character',
      avatar: 'T',
      age: 30,
      role: '测试进度角色',
      personalityTags: const [],
      systemPrompt: '只按工具协议工作。',
      apiKey: '',
      apiProvider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
      apiConfigId: config.id,
    );
    await database.apiConfigBox.put(config.id, config);
    await database.aiCharacterBox.put(character.id, character);

    final gateway = _FloodingProgressGateway();
    final runner = DefaultWorkTaskRunner(
      database: database,
      eventStore: eventStore,
      credentials: _TestCredentials(),
      gateway: gateway,
      workspaceService: WorkModeWorkspaceService(
        db: database,
        grantService: grants,
      ),
      folderGrantService: grants,
      workspaceFileService: files,
      mutationService: mutations,
    );
    final task = AgentTask(
      id: 'progress-throttle-task',
      groupId: 'progress-throttle-group',
      characterId: character.id,
      userRequest: '检查当前任务状态',
      workModeTask: true,
    );

    await runner.run(task, WorkTaskCancellation());

    expect(task.status, AgentTaskStatus.completed);
    expect(gateway.calls, 1);
    final events = (await eventStore.read(task.id)).events;
    final modelProgressEvents = events.where(
      (event) =>
          event.title == 'AI 公开进度' && event.safeMetadata['stream'] == 'model',
    );
    expect(
      modelProgressEvents.length,
      lessThan(20),
      reason: '每个 token 都落盘会阻塞任务推进',
    );
  });

  test('drops final model progress after the gateway is cancelled', () async {
    final config = ApiConfig(
      id: 'cancelled-progress-config',
      name: 'Cancelled progress test config',
      provider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
    );
    final character = AICharacter(
      id: 'cancelled-progress-character',
      name: 'Cancelled progress character',
      avatar: 'C',
      age: 30,
      role: '测试取消角色',
      personalityTags: const [],
      systemPrompt: '只按工具协议工作。',
      apiKey: '',
      apiProvider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
      apiConfigId: config.id,
    );
    await database.apiConfigBox.put(config.id, config);
    await database.aiCharacterBox.put(character.id, character);

    final grants = WorkFolderGrantService(
      box: database.appSettingsBox,
      directoryValidator: (_) async => true,
      writeDirectoryValidator: (_) async => true,
      isWindows: false,
    );
    expect(
      await grants.authorizeDirectory(
        authorizedDirectory.path,
        consent: (_) async => true,
      ),
      isNotNull,
    );
    final pathPolicy = WorkspacePathPolicy(grantService: grants);
    final gateway = _CancelsBeforeFinalProgressGateway();
    final runner = DefaultWorkTaskRunner(
      database: database,
      eventStore: eventStore,
      credentials: _TestCredentials(),
      gateway: gateway,
      workspaceService: WorkModeWorkspaceService(
        db: database,
        grantService: grants,
      ),
      folderGrantService: grants,
      workspaceFileService: WorkspaceFileService(pathPolicy: pathPolicy),
      mutationService: WorkspaceMutationService(pathPolicy: pathPolicy),
    );
    final task = AgentTask(
      id: 'cancelled-progress-task',
      groupId: 'cancelled-progress-group',
      characterId: character.id,
      userRequest: '检查当前任务状态',
      workModeTask: true,
    );

    await runner.run(task, WorkTaskCancellation());

    expect(task.status, AgentTaskStatus.completed);
    expect(gateway.calls, 1);
    expect(
      (await eventStore.read(task.id))
          .events
          .where((event) => event.detail == '不应写入的迟到进度。'),
      isEmpty,
    );
  });

  test('production runner delivers every workspace.patch as a file card',
      () async {
    final grants = WorkFolderGrantService(
      box: database.appSettingsBox,
      directoryValidator: (_) async => true,
      writeDirectoryValidator: (_) async => true,
      isWindows: false,
    );
    expect(
      await grants.authorizeDirectory(
        authorizedDirectory.path,
        consent: (_) async => true,
      ),
      isNotNull,
    );
    final pathPolicy = WorkspacePathPolicy(grantService: grants);
    final files = WorkspaceFileService(pathPolicy: pathPolicy);
    final snapshots = WorkSnapshotService(
      appSupportDirectory: Directory('${hiveDirectory.path}/app-support'),
      pathPolicy: pathPolicy,
      eventStore: eventStore,
    );
    final mutations = WorkspaceMutationService(
      pathPolicy: pathPolicy,
      snapshotPort: snapshots,
      eventStore: eventStore,
    );
    final workspaceService = WorkModeWorkspaceService(
      db: database,
      grantService: grants,
    );
    final workspace = await workspaceService.loadOrCreate(
      conversationId: 'stage02-project',
      isDirectChat: false,
      requireWritable: true,
    );
    await database.saveAiProcessingDirPath(
      '${hiveDirectory.path}/ai-processing',
    );
    final mediaDirectory =
        await Directory('${hiveDirectory.path}/media').create(recursive: true);
    var mediaCopyIndex = 0;

    const projectFiles = <Map<String, String>>[
      {
        'path': 'project/lib/main.dart',
        'content': 'void main() => print("hello");',
      },
      {
        'path': 'project/test/main_test.dart',
        'content': 'void main() {}',
      },
      {
        'path': 'project/assets/config.json',
        'content': '{"name":"demo"}',
      },
    ];
    final gateway = _MultiPatchGateway(projectFiles);
    final config = ApiConfig(
      id: 'stage02-project-config',
      name: 'Stage02 project test config',
      provider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
    );
    final character = AICharacter(
      id: 'stage02-project-character',
      name: '项目执行角色',
      avatar: 'P',
      age: 30,
      role: '项目生成测试角色',
      personalityTags: const [],
      systemPrompt: '只按工具协议工作。',
      apiKey: '',
      apiProvider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
      apiConfigId: config.id,
      toolPermissions: const [
        ToolPermission.workspaceRead,
        ToolPermission.workspacePatch,
      ],
    );
    await database.apiConfigBox.put(config.id, config);
    await database.aiCharacterBox.put(character.id, character);

    final runner = DefaultWorkTaskRunner(
      database: database,
      eventStore: eventStore,
      credentials: _TestCredentials(),
      gateway: gateway,
      workspaceService: workspaceService,
      folderGrantService: grants,
      workspaceFileService: files,
      mutationService: mutations,
      mediaCopier: (source, type, {fileName}) async {
        final target = File(
          '${mediaDirectory.path}/${mediaCopyIndex++}-${fileName ?? 'attachment'}',
        );
        await source.copy(target.path);
        return MediaAttachment(
          type: type,
          localPath: target.path,
          fileName: fileName,
          fileSize: await target.length(),
        );
      },
    );
    final task = AgentTask(
      id: 'stage02-project-task',
      groupId: 'stage02-project',
      characterId: character.id,
      userRequest: '生成项目源码并交付全部文件',
      workModeTask: true,
    );

    var approvalRounds = 0;
    while (task.status != AgentTaskStatus.completed) {
      await runner.run(task, WorkTaskCancellation());
      if (task.status != AgentTaskStatus.waitingForApproval) break;
      approvalRounds++;
      expect(approvalRounds, lessThanOrEqualTo(projectFiles.length));
      expect(task.pendingToolRequestJson, contains('workspace.patch'));
      final checkpoint = jsonDecode(task.executionStateJson) as Map;
      task
        ..executionStateJson = jsonEncode({
          ...checkpoint,
          'approvalDecision': 'approved',
        })
        ..status = AgentTaskStatus.queued;
      await database.agentTaskBox.put(task.id, task);
    }

    expect(task.status, AgentTaskStatus.completed,
        reason: '${task.lastError}; ${task.resultSummary}');
    expect(gateway.calls, projectFiles.length + 1);
    final expectedPaths = projectFiles
        .map((file) => '${workspace.workDirPath}/${file['path']}')
        .toList(growable: false);
    final canonicalPaths = <String>[];
    for (var index = 0; index < projectFiles.length; index++) {
      final canonicalPath =
          await File(expectedPaths[index]).resolveSymbolicLinks();
      final canonical = File(canonicalPath);
      canonicalPaths.add(canonicalPath);
      expect(
        await canonical.readAsString(),
        projectFiles[index]['content'],
      );
    }
    // macOS may expose the temporary directory through /var while the
    // resolved path returned by the tool uses its /private/var spelling.
    expect(task.lastArtifactPaths, containsAll(canonicalPaths));

    final message = database.messageBox.values
        .where((item) =>
            item.groupId == task.groupId && item.senderId == character.id)
        .last;
    expect(
      message.media,
      hasLength(3),
      reason:
          'content=${message.content}; paths=${task.lastArtifactPaths}; root=${workspace.workDirPath}',
    );
    expect(message.content, contains('已附加 3 个产物'));
    final names =
        message.media!.map((attachment) => attachment.fileName).toSet();
    expect(
        names,
        containsAll(<String>[
          'main.dart',
          'main_test.dart',
          'config.json',
        ]));
    expect(
      message.media!.every(
        (attachment) =>
            canonicalPaths.contains(attachment.localPath) &&
            attachment.cachePath != null,
      ),
      isTrue,
      reason: '工作产物附件必须引用原路径，并单独保留缓存路径。',
    );
    final events = await eventStore.read(task.id);
    final progress = events.events
        .where((event) => event.title == '文件交付进度')
        .toList(growable: false);
    expect(progress.last.safeMetadata['filesProcessed'], 3);
  });

  test('production command cannot use task permissions to bypass role grant',
      () async {
    final grants = WorkFolderGrantService(
      box: database.appSettingsBox,
      directoryValidator: (_) async => true,
      writeDirectoryValidator: (_) async => true,
      isWindows: false,
    );
    expect(
      await grants.authorizeDirectory(
        authorizedDirectory.path,
        consent: (_) async => true,
      ),
      isNotNull,
    );
    final pathPolicy = WorkspacePathPolicy(grantService: grants);
    final files = WorkspaceFileService(pathPolicy: pathPolicy);
    final snapshots = WorkSnapshotService(
      appSupportDirectory: Directory('${hiveDirectory.path}/app-support'),
      pathPolicy: pathPolicy,
      eventStore: eventStore,
    );
    final mutations = WorkspaceMutationService(
      pathPolicy: pathPolicy,
      snapshotPort: snapshots,
      eventStore: eventStore,
    );
    final config = ApiConfig(
      id: 'command-permission-config',
      name: 'Command permission test',
      provider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
    );
    final character = AICharacter(
      id: 'command-permission-character',
      name: '无命令权限角色',
      avatar: 'CP',
      age: 30,
      role: '只读角色',
      personalityTags: const [],
      systemPrompt: '只按工具协议工作。',
      apiKey: '',
      apiProvider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
      apiConfigId: config.id,
      toolPermissions: const [ToolPermission.workspaceRead],
    );
    await database.apiConfigBox.put(config.id, config);
    await database.aiCharacterBox.put(character.id, character);

    var processStarts = 0;
    final runner = DefaultWorkTaskRunner(
      database: database,
      eventStore: eventStore,
      credentials: _TestCredentials(),
      gateway: _CommandGateway(),
      workspaceService: WorkModeWorkspaceService(
        db: database,
        grantService: grants,
      ),
      folderGrantService: grants,
      workspaceFileService: files,
      mutationService: mutations,
      commandRunner: WorkCommandRunner(
        policy: WorkCommandPolicy(
          authorizedRoots: [authorizedDirectory.path],
          isWindows: false,
        ),
        processStarter: (_, {required env, required shell}) async {
          processStarts++;
          throw StateError('command runner must not be reached');
        },
      ),
    );
    final task = AgentTask(
      id: 'command-permission-task',
      groupId: 'command-permission-group',
      characterId: character.id,
      userRequest: '读取工作目录',
      // Simulate a stale or tampered task checkpoint that requests a capability
      // the active character never granted.
      requestedPermissions: const [ToolPermission.commandRun],
      assignedCharacterIds: const ['command-permission-character'],
      workModeTask: true,
    );

    await runner.run(task, WorkTaskCancellation());

    expect(task.status, AgentTaskStatus.paused);
    expect(task.lastError, contains('commandRun'));
    expect(task.pendingToolRequestJson, contains('command.run'));
    expect(processStarts, 0);
  });

  test(
      'invalid command input fails as a protocol error without a continue pause',
      () async {
    final grants = WorkFolderGrantService(
      box: database.appSettingsBox,
      directoryValidator: (_) async => true,
      writeDirectoryValidator: (_) async => true,
      isWindows: false,
    );
    await grants.authorizeDirectory(
      authorizedDirectory.path,
      consent: (_) async => true,
    );
    final pathPolicy = WorkspacePathPolicy(grantService: grants);
    final files = WorkspaceFileService(pathPolicy: pathPolicy);
    final mutations = WorkspaceMutationService(pathPolicy: pathPolicy);
    final config = ApiConfig(
      id: 'invalid-command-config',
      name: 'Invalid command test',
      provider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
    );
    final character = AICharacter(
      id: 'invalid-command-character',
      name: '命令协议角色',
      avatar: 'IC',
      age: 30,
      role: '测试执行角色',
      personalityTags: const [],
      systemPrompt: '只按工具协议工作。',
      apiKey: '',
      apiProvider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
      apiConfigId: config.id,
      toolPermissions: const [ToolPermission.commandRun],
    );
    await database.apiConfigBox.put(config.id, config);
    await database.aiCharacterBox.put(character.id, character);

    var processStarts = 0;
    final runner = DefaultWorkTaskRunner(
      database: database,
      eventStore: eventStore,
      credentials: _TestCredentials(),
      gateway: _CommandGateway(
        commandArguments: const ['line-one\nline-two'],
      ),
      workspaceService: WorkModeWorkspaceService(
        db: database,
        grantService: grants,
      ),
      folderGrantService: grants,
      workspaceFileService: files,
      mutationService: mutations,
      commandRunner: WorkCommandRunner(
        policy: WorkCommandPolicy(
          authorizedRoots: [authorizedDirectory.path],
          isWindows: false,
        ),
        pathPolicy: pathPolicy,
        processStarter: (_, {required env, required shell}) async {
          processStarts++;
          throw StateError('invalid command must not start a process');
        },
      ),
    );
    final task = AgentTask(
      id: 'invalid-command-task',
      groupId: 'invalid-command-group',
      characterId: character.id,
      userRequest: '生成报告',
      requestedPermissions: character.toolPermissions,
      assignedCharacterIds: const ['invalid-command-character'],
      workModeTask: true,
    );

    await runner.run(task, WorkTaskCancellation());

    expect(task.status, AgentTaskStatus.failed);
    expect(task.workFailure?.type, WorkFailureType.modelProtocol);
    expect(task.resumeRequired, isTrue);
    expect(task.pendingToolRequestJson, isEmpty);
    expect(task.lastError, contains('命令包含控制字符'));
    expect(processStarts, 0);
    expect(
      (await eventStore.read(task.id)).events.any(
            (event) => event.title.contains('命令未通过安全校验'),
          ),
      isTrue,
    );
  });

  test(
      'approved missing command reaches tool-missing recovery instead of looping',
      () async {
    final grants = WorkFolderGrantService(
      box: database.appSettingsBox,
      directoryValidator: (_) async => true,
      writeDirectoryValidator: (_) async => true,
      isWindows: false,
    );
    await grants.authorizeDirectory(
      authorizedDirectory.path,
      consent: (_) async => true,
    );
    final pathPolicy = WorkspacePathPolicy(grantService: grants);
    final files = WorkspaceFileService(pathPolicy: pathPolicy);
    final mutations = WorkspaceMutationService(pathPolicy: pathPolicy);
    final config = ApiConfig(
      id: 'missing-command-config',
      name: 'Missing command test',
      provider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
    );
    final character = AICharacter(
      id: 'missing-command-character',
      name: '缺失工具角色',
      avatar: 'MT',
      age: 30,
      role: '测试执行角色',
      personalityTags: const [],
      systemPrompt: '只按工具协议工作。',
      apiKey: '',
      apiProvider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
      apiConfigId: config.id,
      toolPermissions: const [
        ToolPermission.workspaceRead,
        ToolPermission.commandRun,
      ],
    );
    await database.apiConfigBox.put(config.id, config);
    await database.aiCharacterBox.put(character.id, character);
    final workspaceService = WorkModeWorkspaceService(
      db: database,
      grantService: grants,
    );
    var processStarts = 0;
    final commandRunner = WorkCommandRunner(
      policy: WorkCommandPolicy(
        authorizedRoots: [authorizedDirectory.path],
        isWindows: false,
      ),
      pathPolicy: pathPolicy,
      processStarter: (_, {required env, required shell}) async {
        processStarts++;
        throw const ProcessException(
          'insta',
          [],
          'No such file or directory',
          2,
        );
      },
    );
    final runner = DefaultWorkTaskRunner(
      database: database,
      eventStore: eventStore,
      credentials: _TestCredentials(),
      gateway: _MissingMutationCommandGateway(),
      workspaceService: workspaceService,
      folderGrantService: grants,
      workspaceFileService: files,
      mutationService: mutations,
      resourceLockManager: WorkResourceLockManager(isWindows: false),
      commandRunner: commandRunner,
    );
    final task = AgentTask(
      id: 'missing-command-task',
      groupId: 'missing-command-group',
      characterId: character.id,
      userRequest: 'insta',
      requestedPermissions: character.toolPermissions,
      assignedCharacterIds: const ['missing-command-character'],
      workModeTask: true,
    );

    await runner.run(task, WorkTaskCancellation());
    expect(task.status, AgentTaskStatus.waitingForApproval);
    expect(task.lastError, contains('影响范围不确定'));

    final checkpoint = Map<String, dynamic>.from(
      jsonDecode(task.executionStateJson) as Map,
    )..['approvalDecision'] = 'approvedWithoutUndo';
    task
      ..executionStateJson = jsonEncode(checkpoint)
      ..status = AgentTaskStatus.queued;
    await runner.run(task, WorkTaskCancellation());

    expect(task.status, AgentTaskStatus.paused);
    expect(task.lastError, contains('缺少工具'));
    expect(task.contextSummary, contains('toolMissing'));
    expect(processStarts, 1);
  });

  test(
      'successful missing-tool install rehydrates the pending command after restart',
      () async {
    final grants = WorkFolderGrantService(
      box: database.appSettingsBox,
      directoryValidator: (_) async => true,
      writeDirectoryValidator: (_) async => true,
      isWindows: false,
    );
    await grants.authorizeDirectory(
      authorizedDirectory.path,
      consent: (_) async => true,
    );
    final pathPolicy = WorkspacePathPolicy(grantService: grants);
    final files = WorkspaceFileService(pathPolicy: pathPolicy);
    final mutations = WorkspaceMutationService(pathPolicy: pathPolicy);
    final config = ApiConfig(
      id: 'restart-install-config',
      name: 'Restart install test',
      provider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
    );
    final character = AICharacter(
      id: 'restart-install-character',
      name: '安装恢复角色',
      avatar: 'IR',
      age: 30,
      role: '测试执行角色',
      personalityTags: const [],
      systemPrompt: '只按工具协议工作。',
      apiKey: '',
      apiProvider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
      apiConfigId: config.id,
      toolPermissions: const [
        ToolPermission.workspaceRead,
        ToolPermission.commandRun,
      ],
    );
    await database.apiConfigBox.put(config.id, config);
    await database.aiCharacterBox.put(character.id, character);

    var installed = false;
    var processStarts = 0;
    final commandRunner = WorkCommandRunner(
      policy: WorkCommandPolicy(
        authorizedRoots: [authorizedDirectory.path],
        isWindows: false,
        // The fake installer models the trusted Homebrew path on every CI OS.
        isMacOS: true,
      ),
      pathPolicy: pathPolicy,
      processStarter: (command, {required env, required shell}) async {
        processStarts++;
        if (command.executable == 'pandoc' && !installed) {
          throw const ProcessException(
            'pandoc',
            [],
            'No such file or directory',
            2,
          );
        }
        if (command.executable == 'brew') installed = true;
        return WorkCommandProcess(
          pid: processStarts,
          stdout: const Stream<List<int>>.empty(),
          stderr: const Stream<List<int>>.empty(),
          exitCode: Future<int>.value(0),
          terminateTree: ({bool force = false}) async {},
        );
      },
    );
    final gateway = _MissingMutationCommandGateway(executable: 'pandoc');
    final workspaceService = WorkModeWorkspaceService(
      db: database,
      grantService: grants,
    );
    final firstRunner = DefaultWorkTaskRunner(
      database: database,
      eventStore: eventStore,
      credentials: _TestCredentials(),
      gateway: gateway,
      workspaceService: workspaceService,
      folderGrantService: grants,
      workspaceFileService: files,
      mutationService: mutations,
      resourceLockManager: WorkResourceLockManager(isWindows: false),
      commandRunner: commandRunner,
    );
    final task = AgentTask(
      id: 'restart-install-task',
      groupId: 'restart-install-group',
      characterId: character.id,
      userRequest: '生成 PDF',
      requestedPermissions: character.toolPermissions,
      assignedCharacterIds: const ['restart-install-character'],
      workModeTask: true,
    );

    await firstRunner.run(task, WorkTaskCancellation());
    expect(task.status, AgentTaskStatus.waitingForApproval);
    final approved = Map<String, dynamic>.from(
      jsonDecode(task.executionStateJson) as Map,
    )..['approvalDecision'] = 'approvedWithoutUndo';
    task
      ..executionStateJson = jsonEncode(approved)
      ..status = AgentTaskStatus.queued;
    await firstRunner.run(task, WorkTaskCancellation());

    expect(task.status, AgentTaskStatus.paused);
    expect(task.lastError, contains('缺少工具'));
    expect(task.pendingToolRequestJson, contains('pandoc'));

    // The install button is handled by a fresh runner after a process
    // restart. A successful install must rehydrate only this sanitized,
    // structured command checkpoint so the exact command can be revalidated
    // and executed without asking the model to invent it again.
    final restartedRunner = DefaultWorkTaskRunner(
      database: database,
      eventStore: eventStore,
      credentials: _TestCredentials(),
      gateway: gateway,
      workspaceService: workspaceService,
      folderGrantService: grants,
      workspaceFileService: files,
      mutationService: mutations,
      resourceLockManager: WorkResourceLockManager(isWindows: false),
      commandRunner: commandRunner,
    );
    final install = await restartedRunner.installMissingTool(
      task,
      WorkTaskCancellation(),
    );
    expect(install.succeeded, isTrue);
    expect(installed, isTrue);

    final resumedExecution = Map<String, dynamic>.from(
      jsonDecode(task.executionStateJson) as Map,
    )..remove('toolMissing');
    task
      ..executionStateJson =
          resumedExecution.isEmpty ? '' : jsonEncode(resumedExecution)
      ..status = AgentTaskStatus.queued
      ..resumeRequired = false;
    await restartedRunner.run(task, WorkTaskCancellation());

    // Missing-tool recovery must replay the command boundary first. The
    // missing executable path is a mutation-shaped command, so its original
    // approval was intentionally consumed by the failed probe and the
    // resumed task asks for a fresh approval rather than silently reusing it.
    expect(task.status, AgentTaskStatus.waitingForApproval);
    expect(gateway.calls, 1);
    expect(processStarts, 2);
  });

  test('production read-only command runs with a read-only folder grant',
      () async {
    final grants = WorkFolderGrantService(
      box: database.appSettingsBox,
      directoryValidator: (_) async => true,
      writeDirectoryValidator: (_) async => false,
      isWindows: false,
    );
    expect(
      await grants.authorizeDirectory(
        authorizedDirectory.path,
        consent: (_) async => true,
      ),
      isNotNull,
    );
    final pathPolicy = WorkspacePathPolicy(grantService: grants);
    final files = WorkspaceFileService(pathPolicy: pathPolicy);
    final mutations = WorkspaceMutationService(pathPolicy: pathPolicy);
    final config = ApiConfig(
      id: 'readonly-command-config',
      name: 'Read-only command test',
      provider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
    );
    final character = AICharacter(
      id: 'readonly-command-character',
      name: '只读命令角色',
      avatar: 'RO',
      age: 30,
      role: '检查角色',
      personalityTags: const [],
      systemPrompt: '只按工具协议工作。',
      apiKey: '',
      apiProvider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
      apiConfigId: config.id,
      toolPermissions: const [
        ToolPermission.workspaceRead,
        ToolPermission.commandRun,
      ],
    );
    await database.apiConfigBox.put(config.id, config);
    await database.aiCharacterBox.put(character.id, character);

    var processStarts = 0;
    String? startedWorkingDirectory;
    final runner = DefaultWorkTaskRunner(
      database: database,
      eventStore: eventStore,
      credentials: _TestCredentials(),
      gateway: _ReadOnlyCommandGateway(workingDirectory: ''),
      workspaceService: WorkModeWorkspaceService(
        db: database,
        grantService: grants,
      ),
      folderGrantService: grants,
      workspaceFileService: files,
      mutationService: mutations,
      commandRunner: WorkCommandRunner(
        policy: WorkCommandPolicy(
          authorizedRoots: [authorizedDirectory.path],
          isWindows: false,
        ),
        processStarter: (command, {required env, required shell}) async {
          processStarts++;
          startedWorkingDirectory = command.workingDirectory;
          return WorkCommandProcess(
            pid: 10,
            stdout: Stream<List<int>>.value(utf8.encode('read-only\n')),
            stderr: const Stream<List<int>>.empty(),
            exitCode: Future<int>.value(0),
            terminateTree: ({bool force = false}) async {},
          );
        },
      ),
    );
    final task = AgentTask(
      id: 'readonly-command-task',
      groupId: 'readonly-command-group',
      characterId: character.id,
      userRequest: '查看当前工作目录',
      requestedPermissions: character.toolPermissions,
      assignedCharacterIds: const ['readonly-command-character'],
      workModeTask: true,
    );

    await runner.run(task, WorkTaskCancellation());

    expect(task.status, AgentTaskStatus.completed);
    expect(task.lastError, isEmpty);
    expect(processStarts, 1);
    expect(startedWorkingDirectory, authorizedDirectory.path);

    final persistedReplies = database.messageBox.values
        .where((message) =>
            message.groupId == task.groupId &&
            message.senderId == character.id &&
            message.senderType == 'ai')
        .toList(growable: false);
    expect(persistedReplies, hasLength(1));
    expect(persistedReplies.single.content, contains('当前工作目录已读取。'));
  });

  test('routes an accidental workspace.read on XLSX through document parsing',
      () async {
    final grants = WorkFolderGrantService(
      box: database.appSettingsBox,
      directoryValidator: (_) async => true,
      isWindows: false,
    );
    await grants.authorizeDirectory(
      authorizedDirectory.path,
      consent: (_) async => true,
    );
    final pathPolicy = WorkspacePathPolicy(grantService: grants);
    final files = WorkspaceFileService(pathPolicy: pathPolicy);
    final mutations = WorkspaceMutationService(pathPolicy: pathPolicy);
    final workspaceService = WorkModeWorkspaceService(
      db: database,
      grantService: grants,
    );
    final workspace = await workspaceService.loadOrCreate(
      conversationId: 'binary-read-group',
      isDirectChat: false,
    );
    final xlsxPath = '${workspace.workDirPath}/budget.xlsx';
    await File(xlsxPath).writeAsBytes(_xlsxBytes());

    final config = ApiConfig(
      id: 'binary-read-config',
      name: 'Binary read test',
      provider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
    );
    final character = AICharacter(
      id: 'binary-read-character',
      name: '文档读取角色',
      avatar: 'BR',
      age: 30,
      role: '文档分析角色',
      personalityTags: const [],
      systemPrompt: '只按工具协议工作。',
      apiKey: '',
      apiProvider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
      apiConfigId: config.id,
      toolPermissions: const [ToolPermission.workspaceRead],
    );
    await database.apiConfigBox.put(config.id, config);
    await database.aiCharacterBox.put(character.id, character);

    final gateway = _BinaryReadGateway('budget.xlsx');
    final runner = DefaultWorkTaskRunner(
      database: database,
      eventStore: eventStore,
      credentials: _TestCredentials(),
      gateway: gateway,
      workspaceService: workspaceService,
      folderGrantService: grants,
      workspaceFileService: files,
      mutationService: mutations,
    );
    final task = AgentTask(
      id: 'binary-read-task',
      groupId: 'binary-read-group',
      characterId: character.id,
      userRequest: '读取并核对 budget.xlsx',
      requestedPermissions: character.toolPermissions,
      assignedCharacterIds: [character.id],
      workModeTask: true,
    );

    await runner.run(task, WorkTaskCancellation());

    expect(task.status, AgentTaskStatus.completed, reason: task.lastError);
    expect(gateway.calls, 2);
    expect(gateway.lastMessages.toString(), contains('A1: 设计 | B1: 1200'));
  });

  test('publishes a terminal failure to the conversation with file status',
      () async {
    final config = ApiConfig(
      id: 'failure-reply-config',
      name: 'Failure reply test',
      provider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
    );
    final character = AICharacter(
      id: 'failure-reply-character',
      name: '失败回复角色',
      avatar: 'FR',
      age: 30,
      role: '测试执行角色',
      personalityTags: const [],
      systemPrompt: '只按工具协议工作。',
      apiKey: '',
      apiProvider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
      apiConfigId: config.id,
      toolPermissions: const [ToolPermission.workspaceRead],
    );
    await database.apiConfigBox.put(config.id, config);
    await database.aiCharacterBox.put(character.id, character);

    final runner = DefaultWorkTaskRunner(
      database: database,
      eventStore: eventStore,
      credentials: _TestCredentials(),
    );
    final task = AgentTask(
      id: 'failure-reply-task',
      groupId: 'failure-reply-group',
      characterId: character.id,
      userRequest: '整理 Excel 文档',
      status: AgentTaskStatus.failed,
      workModeTask: true,
    );
    final failure = WorkFailure.fromToolFailure(
      code: 'documentParseFailed',
      message: 'budget.xlsx 无法解析：文件不是有效的 UTF-8 文本。',
      completedContent: const ['已生成 budget.xlsx'],
    );

    await runner.reportFailure(task, failure);

    final replies = database.messageBox.values
        .where((message) =>
            message.groupId == task.groupId &&
            message.senderId == character.id &&
            message.senderType == 'ai')
        .toList(growable: false);
    expect(replies, hasLength(1));
    expect(replies.single.content, contains('任务未完成'));
    expect(replies.single.content, contains('budget.xlsx'));
    expect(replies.single.content, contains('文件不是有效的 UTF-8 文本'));
    expect(replies.single.content, contains('下一步'));
  });

  test('keeps the diagnostic text when an artifact task reports failure',
      () async {
    final config = ApiConfig(
      id: 'artifact-failure-reply-config',
      name: 'Artifact failure reply test',
      provider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
    );
    final character = AICharacter(
      id: 'artifact-failure-reply-character',
      name: '文件失败回复角色',
      avatar: 'AF',
      age: 30,
      role: '测试执行角色',
      personalityTags: const [],
      systemPrompt: '只按工具协议工作。',
      apiKey: '',
      apiProvider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
      apiConfigId: config.id,
      toolPermissions: const [ToolPermission.workspaceRead],
    );
    await database.apiConfigBox.put(config.id, config);
    await database.aiCharacterBox.put(character.id, character);

    final runner = DefaultWorkTaskRunner(
      database: database,
      eventStore: eventStore,
      credentials: _TestCredentials(),
    );
    final task = AgentTask(
      id: 'artifact-failure-reply-task',
      groupId: 'artifact-failure-reply-group',
      characterId: character.id,
      userRequest: '生成一个 HTML 页面并保存到桌面',
      status: AgentTaskStatus.failed,
      workModeTask: true,
    );
    final failure = WorkFailure.fromToolFailure(
      code: 'workspaceWriteFailed',
      message: 'HTML 写入失败：目标目录不可用。',
      completedContent: const [],
    );

    await runner.reportFailure(task, failure);

    final reply = database.messageBox.values.singleWhere(
      (message) =>
          message.groupId == task.groupId &&
          message.senderId == character.id &&
          message.senderType == 'ai',
    );
    expect(reply.content, contains('任务未完成'));
    expect(reply.content, contains('HTML 写入失败'));
    expect(reply.content, isNot(contains('正在验证并交付文件')));
  });

  test(
      'sensitive mutation still asks for approval when ordinary prompts are off',
      () async {
    final grants = WorkFolderGrantService(
      box: database.appSettingsBox,
      directoryValidator: (_) async => true,
      writeDirectoryValidator: (_) async => true,
      isWindows: false,
    );
    await grants.authorizeDirectory(
      authorizedDirectory.path,
      consent: (_) async => true,
    );
    await grants.setOrdinaryWriteConfirmation(false);
    final pathPolicy = WorkspacePathPolicy(grantService: grants);
    final files = WorkspaceFileService(pathPolicy: pathPolicy);
    final snapshots = WorkSnapshotService(
      appSupportDirectory: Directory('${hiveDirectory.path}/support-sensitive'),
      pathPolicy: pathPolicy,
    );
    final mutations = WorkspaceMutationService(
      pathPolicy: pathPolicy,
      snapshotPort: snapshots,
    );
    final config = ApiConfig(
      id: 'sensitive-write-config',
      name: 'Sensitive write',
      provider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
    );
    final character = AICharacter(
      id: 'sensitive-write-character',
      name: '敏感写入角色',
      avatar: 'SW',
      age: 30,
      role: '开发工程师',
      personalityTags: const [],
      systemPrompt: '只按工具协议工作。',
      apiKey: '',
      apiProvider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
      apiConfigId: config.id,
      toolPermissions: const [
        ToolPermission.workspaceRead,
        ToolPermission.workspacePatch,
      ],
    );
    await database.apiConfigBox.put(config.id, config);
    await database.aiCharacterBox.put(character.id, character);
    final gateway = _SequencedGateway(
      patchPath: '.env',
      patchContent: 'sensitive-update',
      repeatToolOnSecondModelCall: true,
    );
    final runner = DefaultWorkTaskRunner(
      database: database,
      eventStore: eventStore,
      credentials: _TestCredentials(),
      gateway: gateway,
      workspaceService: WorkModeWorkspaceService(
        db: database,
        grantService: grants,
      ),
      folderGrantService: grants,
      workspaceFileService: files,
      mutationService: mutations,
    );
    final task = AgentTask(
      id: 'sensitive-write-task',
      groupId: 'sensitive-write-group',
      characterId: character.id,
      userRequest: '更新 .env',
      requestedPermissions: character.toolPermissions,
      assignedCharacterIds: [character.id],
      workModeTask: true,
    );

    await runner.run(task, WorkTaskCancellation());

    expect(task.status, AgentTaskStatus.waitingForApproval);
    expect(task.executionStateJson, contains('approvalPlan'));
    expect(task.executionStateJson, contains('sensitive'));

    final checkpoint = Map<String, dynamic>.from(
      jsonDecode(task.executionStateJson) as Map,
    )..['approvalDecision'] = 'approved';
    task
      ..executionStateJson = jsonEncode(checkpoint)
      ..status = AgentTaskStatus.queued;
    // Simulate a process restart: the new runner has no in-memory request and
    // must re-plan from the model instead of replaying the redacted checkpoint.
    final restartedRunner = DefaultWorkTaskRunner(
      database: database,
      eventStore: eventStore,
      credentials: _TestCredentials(),
      gateway: gateway,
      workspaceService: WorkModeWorkspaceService(
        db: database,
        grantService: grants,
      ),
      folderGrantService: grants,
      workspaceFileService: files,
      mutationService: mutations,
    );
    await restartedRunner.run(task, WorkTaskCancellation());

    expect(task.status, AgentTaskStatus.completed);
    expect(task.lastError, isEmpty, reason: task.lastError);
    expect(gateway.calls, 3);
    expect(
      await File(
        '${authorizedDirectory.path}/conversations/group_sensitive-write-group/.env',
      ).readAsString(),
      'sensitive-update',
    );
  });

  test(
      'rejecting a sensitive read becomes a safe skip instead of an approval loop',
      () async {
    final grants = WorkFolderGrantService(
      box: database.appSettingsBox,
      directoryValidator: (_) async => true,
      isWindows: false,
    );
    await grants.authorizeDirectory(
      authorizedDirectory.path,
      consent: (_) async => true,
    );
    final pathPolicy = WorkspacePathPolicy(grantService: grants);
    final files = WorkspaceFileService(pathPolicy: pathPolicy);
    final mutations = WorkspaceMutationService(pathPolicy: pathPolicy);
    final config = ApiConfig(
      id: 'sensitive-read-config',
      name: 'Sensitive read',
      provider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
    );
    final character = AICharacter(
      id: 'sensitive-read-character',
      name: '敏感读取角色',
      avatar: 'SR',
      age: 30,
      role: '审计工程师',
      personalityTags: const [],
      systemPrompt: '只按工具协议工作。',
      apiKey: '',
      apiProvider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
      apiConfigId: config.id,
      toolPermissions: const [ToolPermission.workspaceRead],
    );
    await database.apiConfigBox.put(config.id, config);
    await database.aiCharacterBox.put(character.id, character);
    final workspaceService = WorkModeWorkspaceService(
      db: database,
      grantService: grants,
    );
    final workspace = await workspaceService.loadOrCreate(
      conversationId: 'sensitive-read-group',
      isDirectChat: false,
    );
    final sensitiveFile = File('${workspace.workDirPath}/.env');
    await sensitiveFile.writeAsString('TOKEN=do-not-expose');
    final gateway = _SensitiveGateway(
      toolName: 'workspace.read',
      arguments: const {'path': '.env'},
    );
    final runner = DefaultWorkTaskRunner(
      database: database,
      eventStore: eventStore,
      credentials: _TestCredentials(),
      gateway: gateway,
      workspaceService: workspaceService,
      folderGrantService: grants,
      workspaceFileService: files,
      mutationService: mutations,
    );
    final task = AgentTask(
      id: 'sensitive-read-task',
      groupId: 'sensitive-read-group',
      characterId: character.id,
      userRequest: '读取 .env',
      requestedPermissions: character.toolPermissions,
      assignedCharacterIds: [character.id],
      workModeTask: true,
    );

    await runner.run(task, WorkTaskCancellation());
    expect(task.status, AgentTaskStatus.waitingForApproval);
    task.executionStateJson = jsonEncode({
      ...Map<String, dynamic>.from(jsonDecode(task.executionStateJson) as Map),
      'approvalDecision': 'rejected',
    });
    task.status = AgentTaskStatus.queued;
    await runner.run(task, WorkTaskCancellation());

    expect(task.status, AgentTaskStatus.completed);
    expect(gateway.calls, 2);
    expect(task.executionStateJson, isNot(contains('approvalDecision')));
    expect(task.contextSummary, isNot(contains('do-not-expose')));
  });

  test('a missing or blank workspace.list path lists the workspace root',
      () async {
    final grants = WorkFolderGrantService(
      box: database.appSettingsBox,
      directoryValidator: (_) async => true,
      writeDirectoryValidator: (_) async => true,
      isWindows: false,
    );
    await grants.authorizeDirectory(
      authorizedDirectory.path,
      consent: (_) async => true,
    );
    final pathPolicy = WorkspacePathPolicy(grantService: grants);
    final files = WorkspaceFileService(pathPolicy: pathPolicy);
    final mutations = WorkspaceMutationService(pathPolicy: pathPolicy);
    final workspaceService = WorkModeWorkspaceService(
      db: database,
      grantService: grants,
    );
    final workspace = await workspaceService.loadOrCreate(
      conversationId: 'workspace-list-group',
      isDirectChat: false,
      requireWritable: true,
    );
    final workspaceRoot = workspace.workDirPath;
    await File('$workspaceRoot/notes.md').writeAsString('# notes');
    // A model that sends the literal string "null" as the path is not a valid
    // target, but it must never crash the loop either.
    await Directory('$workspaceRoot/null').create(recursive: true);

    final config = ApiConfig(
      id: 'workspace-list-config',
      name: 'Workspace list test',
      provider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
    );
    final character = AICharacter(
      id: 'workspace-list-character',
      name: '目录检查角色',
      avatar: 'WL',
      age: 30,
      role: '目录检查角色',
      personalityTags: const [],
      systemPrompt: '只按工具协议工作。',
      apiKey: '',
      apiProvider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
      apiConfigId: config.id,
      toolPermissions: const [ToolPermission.workspaceRead],
    );
    await database.apiConfigBox.put(config.id, config);
    await database.aiCharacterBox.put(character.id, character);

    // Omitted path, explicit null, empty string, and "." must all resolve to
    // the authorized workspace root.
    final gateway = _WorkspaceListPathGateway(
      const <Object?>[null, null, '', '  ', '.', './'],
    );
    final runner = DefaultWorkTaskRunner(
      database: database,
      eventStore: eventStore,
      credentials: _TestCredentials(),
      gateway: gateway,
      workspaceService: workspaceService,
      folderGrantService: grants,
      workspaceFileService: files,
      mutationService: mutations,
    );
    final task = AgentTask(
      id: 'workspace-list-task',
      groupId: 'workspace-list-group',
      characterId: character.id,
      userRequest: '查看工作区目录里有哪些文件',
      requestedPermissions: character.toolPermissions,
      assignedCharacterIds: [character.id],
      workModeTask: true,
    );

    await runner.run(task, WorkTaskCancellation());

    expect(task.status, AgentTaskStatus.completed, reason: task.lastError);
    expect(task.lastError, isEmpty);
    // One model call per argument spelling plus the finishing turn.
    expect(gateway.calls, 7);

    final events = (await eventStore.read(task.id)).events;
    final listResults = events
        .where((event) =>
            event.safeMetadata['tool'] == 'workspace.list' &&
            event.kind == WorkTaskEventKind.toolOutput)
        .toList(growable: false);
    expect(listResults, hasLength(6));
    expect(
      listResults.every((event) => event.title == '文件操作已完成。'),
      isTrue,
      reason: listResults.map((event) => event.title).join(' | '),
    );
    expect(
      events.any((event) => event.title.contains('workspace path')),
      isFalse,
    );
    expect(task.status, isNot(AgentTaskStatus.failed));
  });

  test('bundled archive names stay unique for long shared prefixes', () async {
    await database.saveAiProcessingDirPath(
      '${hiveDirectory.path}/ai-processing',
    );
    final grants = WorkFolderGrantService(
      box: database.appSettingsBox,
      directoryValidator: (_) async => true,
      writeDirectoryValidator: (_) async => true,
      isWindows: false,
    );
    await grants.authorizeDirectory(
      authorizedDirectory.path,
      consent: (_) async => true,
    );
    final pathPolicy = WorkspacePathPolicy(grantService: grants);
    final files = WorkspaceFileService(pathPolicy: pathPolicy);
    final workspaceService = WorkModeWorkspaceService(
      db: database,
      grantService: grants,
    );
    final workspace = await workspaceService.loadOrCreate(
      conversationId: 'bundle-unique-group',
      isDirectChat: false,
      requireWritable: true,
    );
    final workspaceRoot = workspace.workDirPath;
    // Keep the source filename below Linux's 255-byte component limit while
    // making the shared prefix exceed the 80-rune archive budget.
    const shared = '2026年第三季度大模型能力评测与横向对比分析报告_内部评审稿_含全部评测维度与'
        '推理编码数学安全多语言长上下文工具调用对齐人工偏好等细分榜单的完整明细_'
        '附图表与数';
    final artifactNames = <String>[
      '${shared}_甲部门.xlsx',
      '${shared}_乙部门.xlsx',
      for (var index = 0; index < 12; index++) '大模型排名_$index.xlsx',
    ];
    for (final name in artifactNames) {
      await File('$workspaceRoot/$name').writeAsString('rank $name');
    }

    final config = ApiConfig(
      id: 'bundle-unique-config',
      name: 'Bundle unique test',
      provider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
    );
    final character = AICharacter(
      id: 'bundle-unique-character',
      name: '打包唯一性角色',
      avatar: 'BU',
      age: 30,
      role: '打包唯一性角色',
      personalityTags: const [],
      systemPrompt: '只按工具协议工作。',
      apiKey: '',
      apiProvider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
      apiConfigId: config.id,
      toolPermissions: const [
        ToolPermission.workspaceRead,
        ToolPermission.workspacePatch,
      ],
    );
    await database.apiConfigBox.put(config.id, config);
    await database.aiCharacterBox.put(character.id, character);

    final mediaDirectory =
        await Directory('${hiveDirectory.path}/media').create(recursive: true);
    var mediaCopyIndex = 0;
    final runner = DefaultWorkTaskRunner(
      database: database,
      eventStore: eventStore,
      credentials: _TestCredentials(),
      gateway: _SequencedGateway(),
      workspaceService: workspaceService,
      folderGrantService: grants,
      workspaceFileService: files,
      mediaCopier: (source, type, {fileName}) async {
        final target = File(
          '${mediaDirectory.path}/${mediaCopyIndex++}-${fileName ?? 'attachment'}',
        );
        await source.copy(target.path);
        return MediaAttachment(
          type: type,
          localPath: target.path,
          fileName: fileName,
          fileSize: await target.length(),
        );
      },
    );
    final task = AgentTask(
      id: 'bundle-unique-task',
      groupId: 'bundle-unique-group',
      characterId: character.id,
      userRequest: '生成全部大模型排名表格文件',
      workModeTask: true,
      status: AgentTaskStatus.completed,
      resultSummary: '已生成全部大模型排名表格文件。',
      lastArtifactPaths: [
        for (final name in artifactNames) '$workspaceRoot/$name',
      ],
    );
    task
      ..status = AgentTaskStatus.queued
      ..executionStateJson = jsonEncode({
        'artifactDeliveryRetryOnly': true,
        'artifactDeliveryNoticePublished': true,
        'artifactDeliveryMessageId': 'bundle-unique-message',
      });

    await runner.run(task, WorkTaskCancellation());

    final message = database.messageBox.values
        .where((item) => item.groupId == task.groupId)
        .last;
    expect(message.content, contains('打包为 ZIP'),
        reason: 'content=${message.content}');
    expect(message.media, hasLength(1));
    // The two long names differ only in their final characters, so they used to
    // truncate to one archive entry and the user silently lost a file. Each keeps
    // a distinct digest suffix instead.
    final listed = RegExp(r'包含：([^。]+)。')
        .firstMatch(message.content)
        ?.group(1)
        ?.split('、');
    expect(listed, isNotNull);
    expect(listed!.toSet(), hasLength(listed.length), reason: '重名条目：$listed');
    // Both long names survive truncation with distinct digest suffixes.
    final longNames =
        listed.where((name) => name.contains(shared.substring(0, 20))).toList();
    expect(longNames, hasLength(2), reason: '长名被截断成同一条目：$listed');
    expect(
      longNames.toSet(),
      hasLength(2),
      reason: '截断后必须仍然唯一：$longNames',
    );
  });

  test('a bundled delivery keeps non-ASCII artifact names readable', () async {
    await database.saveAiProcessingDirPath(
      '${hiveDirectory.path}/ai-processing',
    );
    final grants = WorkFolderGrantService(
      box: database.appSettingsBox,
      directoryValidator: (_) async => true,
      writeDirectoryValidator: (_) async => true,
      isWindows: false,
    );
    await grants.authorizeDirectory(
      authorizedDirectory.path,
      consent: (_) async => true,
    );
    final pathPolicy = WorkspacePathPolicy(grantService: grants);
    final files = WorkspaceFileService(pathPolicy: pathPolicy);
    final workspaceService = WorkModeWorkspaceService(
      db: database,
      grantService: grants,
    );
    final workspace = await workspaceService.loadOrCreate(
      conversationId: 'bundle-name-group',
      isDirectChat: false,
      requireWritable: true,
    );
    final workspaceRoot = workspace.workDirPath;
    // Bundling kicks in once the artifact count exceeds the individual card
    // limit, so this task must produce more files than that limit.
    final artifactNames = <String>[
      for (var index = 0; index < 14; index++) '大模型排名_$index.xlsx',
    ];
    for (final name in artifactNames) {
      await File('$workspaceRoot/$name').writeAsString('rank $name');
    }

    final config = ApiConfig(
      id: 'bundle-name-config',
      name: 'Bundle name test',
      provider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
    );
    final character = AICharacter(
      id: 'bundle-name-character',
      name: '打包交付角色',
      avatar: 'BN',
      age: 30,
      role: '打包交付角色',
      personalityTags: const [],
      systemPrompt: '只按工具协议工作。',
      apiKey: '',
      apiProvider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
      apiConfigId: config.id,
      toolPermissions: const [
        ToolPermission.workspaceRead,
        ToolPermission.workspacePatch,
      ],
    );
    await database.apiConfigBox.put(config.id, config);
    await database.aiCharacterBox.put(character.id, character);

    final mediaDirectory =
        await Directory('${hiveDirectory.path}/media').create(recursive: true);
    var mediaCopyIndex = 0;
    final runner = DefaultWorkTaskRunner(
      database: database,
      eventStore: eventStore,
      credentials: _TestCredentials(),
      gateway: _SequencedGateway(),
      workspaceService: workspaceService,
      folderGrantService: grants,
      workspaceFileService: files,
      mediaCopier: (source, type, {fileName}) async {
        final target = File(
          '${mediaDirectory.path}/${mediaCopyIndex++}-${fileName ?? 'attachment'}',
        );
        await source.copy(target.path);
        return MediaAttachment(
          type: type,
          localPath: target.path,
          fileName: fileName,
          fileSize: await target.length(),
        );
      },
    );
    final task = AgentTask(
      id: 'bundle-name-task',
      groupId: 'bundle-name-group',
      characterId: character.id,
      userRequest: '生成全部大模型排名表格文件',
      workModeTask: true,
      status: AgentTaskStatus.completed,
      resultSummary: '已生成全部大模型排名表格文件。',
      lastArtifactPaths: [
        for (final name in artifactNames) '$workspaceRoot/$name',
      ],
    );
    // A terminal task resumes only through the artifact-delivery retry
    // marker, which re-delivers the saved artifacts without running the model
    // or any tool again. The marker is only honoured for a task that is queued
    // again after having already published its delivery notice.
    task
      ..status = AgentTaskStatus.queued
      ..executionStateJson = jsonEncode({
        'artifactDeliveryRetryOnly': true,
        'artifactDeliveryNoticePublished': true,
        'artifactDeliveryMessageId': 'bundle-name-message',
      });

    await runner.run(task, WorkTaskCancellation());

    final replies = database.messageBox.values
        .where((message) => message.groupId == task.groupId)
        .toList(growable: false);
    final delivery = replies
        .map((message) => message.content)
        .firstWhere((content) => content.contains('打包为 ZIP'), orElse: () => '');
    expect(delivery, isNotEmpty,
        reason: 'status=${task.status} error=${task.lastError} '
            'messages=${replies.map((m) => m.content).join(' | ')} '
            'execution=${task.executionStateJson}');
    expect(delivery, contains('大模型排名_0.xlsx'));
    expect(delivery, isNot(contains('____')));
    expect(
      delivery,
      isNot(contains('artifact')),
      reason: '完整的中文文件名不应退化成占位名。',
    );
  });

  test(
      'a script-produced deliverable completes without extra verification '
      'turns', () async {
    final grants = WorkFolderGrantService(
      box: database.appSettingsBox,
      directoryValidator: (_) async => true,
      writeDirectoryValidator: (_) async => true,
      isWindows: false,
    );
    await grants.authorizeDirectory(
      authorizedDirectory.path,
      consent: (_) async => true,
    );
    final pathPolicy = WorkspacePathPolicy(grantService: grants);
    final files = WorkspaceFileService(pathPolicy: pathPolicy);
    final snapshots = WorkSnapshotService(
      appSupportDirectory: Directory('${hiveDirectory.path}/app-support'),
      pathPolicy: pathPolicy,
    );
    final mutations = WorkspaceMutationService(
      pathPolicy: pathPolicy,
      snapshotPort: snapshots,
    );
    final workspaceService = WorkModeWorkspaceService(
      db: database,
      grantService: grants,
    );
    final workspace = await workspaceService.loadOrCreate(
      conversationId: 'script-artifact-group',
      isDirectChat: false,
      requireWritable: true,
    );
    final workspaceRoot = workspace.workDirPath;

    final config = ApiConfig(
      id: 'script-artifact-config',
      name: 'Script artifact test',
      provider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
    );
    final character = AICharacter(
      id: 'script-artifact-character',
      name: '取数脚本角色',
      avatar: 'SA',
      age: 30,
      role: '取数脚本角色',
      personalityTags: const [],
      systemPrompt: '只按工具协议工作。',
      apiKey: '',
      apiProvider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
      apiConfigId: config.id,
      toolPermissions: const [
        ToolPermission.workspaceRead,
        ToolPermission.workspacePatch,
        ToolPermission.commandRun,
      ],
    );
    await database.apiConfigBox.put(config.id, config);
    await database.aiCharacterBox.put(character.id, character);

    final mediaDirectory =
        await Directory('${hiveDirectory.path}/media').create(recursive: true);
    var mediaCopyIndex = 0;
    var processStarts = 0;
    final gateway = _ScriptArtifactGateway();
    final runner = DefaultWorkTaskRunner(
      database: database,
      eventStore: eventStore,
      credentials: _TestCredentials(),
      gateway: gateway,
      workspaceService: workspaceService,
      folderGrantService: grants,
      workspaceFileService: files,
      mutationService: mutations,
      resourceLockManager: WorkResourceLockManager(isWindows: false),
      mediaCopier: (source, type, {fileName}) async {
        final target = File(
          '${mediaDirectory.path}/${mediaCopyIndex++}-${fileName ?? 'attachment'}',
        );
        await source.copy(target.path);
        return MediaAttachment(
          type: type,
          localPath: target.path,
          fileName: fileName,
          fileSize: await target.length(),
        );
      },
      commandRunner: WorkCommandRunner(
        policy: WorkCommandPolicy(
          authorizedRoots: [workspaceRoot],
          isWindows: false,
        ),
        processStarter: (command, {required env, required shell}) async {
          processStarts++;
          // Stand in for the user's script: produce the declared deliverable.
          await File(
            '$workspaceRoot/${_ScriptArtifactGateway.artifactName}',
          ).writeAsString('rank,model\n1,demo\n');
          return WorkCommandProcess(
            pid: 21,
            stdout: Stream<List<int>>.value(utf8.encode('已生成排名表\n')),
            stderr: const Stream<List<int>>.empty(),
            exitCode: Future<int>.value(0),
            terminateTree: ({bool force = false}) async {},
          );
        },
      ),
    );
    final task = AgentTask(
      id: 'script-artifact-task',
      groupId: 'script-artifact-group',
      characterId: character.id,
      userRequest: '从网上取数并生成一份 xlsx 大模型排名表',
      requestedPermissions: character.toolPermissions,
      assignedCharacterIds: [character.id],
      workModeTask: true,
    );

    // The stub gateway keeps asking for another check after the script runs, so
    // finishing proves the contract check completed the task instead of the
    // model deciding to stop.
    for (var round = 0; round < 8; round++) {
      if (task.isTerminal) break;
      await runner.run(task, WorkTaskCancellation());
      if (task.status == AgentTaskStatus.waitingForApproval) {
        final checkpoint = jsonDecode(task.executionStateJson) as Map;
        task
          ..executionStateJson = jsonEncode({
            ...checkpoint,
            'approvalDecision': 'approvedWithoutUndo',
          })
          ..status = AgentTaskStatus.queued;
        continue;
      }
      if (task.status != AgentTaskStatus.queued) break;
    }

    expect(
      task.status,
      AgentTaskStatus.completed,
      reason: 'status=${task.status} error=${task.lastError} '
          'actions=${task.actionCount}',
    );
    // Two tool actions: write the script, run it.
    expect(processStarts, 1);
    // The command produced a valid deliverable, so the loop finished without
    // spending another model turn re-reading or re-running it.
    expect(
      gateway.calls,
      2,
      reason: '模型不应在产物通过校验后再被调用；actions=${task.actionCount}',
    );

    final message = database.messageBox.values
        .where((item) => item.groupId == task.groupId)
        .last;
    // Only the workbook is delivered; the script is an intermediate file.
    expect(message.media, hasLength(1));
    expect(message.media!.single.fileName, _ScriptArtifactGateway.artifactName);
    expect(message.content, contains('已附加 1 个产物'));
    expect(message.content, isNot(contains(_ScriptArtifactGateway.scriptName)));
  });

  test(
      'a script deliverable is delivered when the declared impact name does '
      'not match what the script wrote', () async {
    // A generator script chooses its own output filename, so `declaredImpact`
    // is only a hint. When the two disagree the real file used to stay
    // invisible: the task failed with "no readable artifact" while the
    // deliverable sat in the workspace.
    const writtenName = '大模型排名-终版.xlsx';
    final grants = WorkFolderGrantService(
      box: database.appSettingsBox,
      directoryValidator: (_) async => true,
      writeDirectoryValidator: (_) async => true,
      isWindows: false,
    );
    await grants.authorizeDirectory(
      authorizedDirectory.path,
      consent: (_) async => true,
    );
    final pathPolicy = WorkspacePathPolicy(grantService: grants);
    final files = WorkspaceFileService(pathPolicy: pathPolicy);
    final snapshots = WorkSnapshotService(
      appSupportDirectory: Directory('${hiveDirectory.path}/app-support'),
      pathPolicy: pathPolicy,
    );
    final mutations = WorkspaceMutationService(
      pathPolicy: pathPolicy,
      snapshotPort: snapshots,
    );
    final workspaceService = WorkModeWorkspaceService(
      db: database,
      grantService: grants,
    );
    final workspace = await workspaceService.loadOrCreate(
      conversationId: 'renamed-artifact-group',
      isDirectChat: false,
      requireWritable: true,
    );
    final workspaceRoot = workspace.workDirPath;

    final config = ApiConfig(
      id: 'renamed-artifact-config',
      name: 'Renamed artifact test',
      provider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
    );
    final character = AICharacter(
      id: 'renamed-artifact-character',
      name: '改名校验角色',
      avatar: 'RA',
      age: 30,
      role: '改名校验角色',
      personalityTags: const [],
      systemPrompt: '只按工具协议工作。',
      apiKey: '',
      apiProvider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
      apiConfigId: config.id,
      toolPermissions: const [
        ToolPermission.workspaceRead,
        ToolPermission.workspacePatch,
        ToolPermission.commandRun,
      ],
    );
    await database.apiConfigBox.put(config.id, config);
    await database.aiCharacterBox.put(character.id, character);

    final mediaDirectory =
        await Directory('${hiveDirectory.path}/media').create(recursive: true);
    var mediaCopyIndex = 0;
    final gateway = _ScriptArtifactGateway(
      writtenName: writtenName,
      finishAfterCommand: true,
    );
    final runner = DefaultWorkTaskRunner(
      database: database,
      eventStore: eventStore,
      credentials: _TestCredentials(),
      gateway: gateway,
      workspaceService: workspaceService,
      folderGrantService: grants,
      workspaceFileService: files,
      mutationService: mutations,
      resourceLockManager: WorkResourceLockManager(isWindows: false),
      mediaCopier: (source, type, {fileName}) async {
        final target = File(
          '${mediaDirectory.path}/${mediaCopyIndex++}-${fileName ?? 'attachment'}',
        );
        await source.copy(target.path);
        return MediaAttachment(
          type: type,
          localPath: target.path,
          fileName: fileName,
          fileSize: await target.length(),
        );
      },
      commandRunner: WorkCommandRunner(
        policy: WorkCommandPolicy(
          authorizedRoots: [workspaceRoot],
          isWindows: false,
        ),
        processStarter: (command, {required env, required shell}) async {
          await File('$workspaceRoot/$writtenName')
              .writeAsString('rank,model\n1,demo\n');
          return WorkCommandProcess(
            pid: 31,
            stdout: Stream<List<int>>.value(utf8.encode('已生成排名表\n')),
            stderr: const Stream<List<int>>.empty(),
            exitCode: Future<int>.value(0),
            terminateTree: ({bool force = false}) async {},
          );
        },
      ),
    );
    final task = AgentTask(
      id: 'renamed-artifact-task',
      groupId: 'renamed-artifact-group',
      characterId: character.id,
      userRequest: '从网上取数并生成一份 xlsx 大模型排名表',
      requestedPermissions: character.toolPermissions,
      assignedCharacterIds: [character.id],
      workModeTask: true,
    );

    for (var round = 0; round < 8; round++) {
      if (task.isTerminal) break;
      await runner.run(task, WorkTaskCancellation());
      if (task.status == AgentTaskStatus.waitingForApproval) {
        final checkpoint = jsonDecode(task.executionStateJson) as Map;
        task
          ..executionStateJson = jsonEncode({
            ...checkpoint,
            'approvalDecision': 'approvedWithoutUndo',
          })
          ..status = AgentTaskStatus.queued;
        continue;
      }
      if (task.status != AgentTaskStatus.queued) break;
    }

    expect(
      task.status,
      AgentTaskStatus.completed,
      reason: 'status=${task.status} error=${task.lastError} '
          'calls=${gateway.calls}',
    );
    final message = database.messageBox.values
        .where((item) => item.groupId == task.groupId)
        .last;
    // The script itself wrote a different filename than the model declared, so
    // the deliverable has to be discovered from the workspace, not from the
    // declaration.
    expect(message.media, hasLength(1));
    expect(message.media!.single.fileName, writtenName);
    expect(message.content, isNot(contains(_ScriptArtifactGateway.scriptName)));
  });

  test(
      'a file that was already in the workspace is not delivered as this '
      "run's artifact", () async {
    // 回归：产物发现只看修改时间，容差窗口之内本来就在工作区里的文件也会被算作
    // 本次运行的产出——一条什么都没写的命令，于是把旧文件当交付物附上。
    final grants = WorkFolderGrantService(
      box: database.appSettingsBox,
      directoryValidator: (_) async => true,
      writeDirectoryValidator: (_) async => true,
      isWindows: false,
    );
    await grants.authorizeDirectory(
      authorizedDirectory.path,
      consent: (_) async => true,
    );
    final pathPolicy = WorkspacePathPolicy(grantService: grants);
    final files = WorkspaceFileService(pathPolicy: pathPolicy);
    final snapshots = WorkSnapshotService(
      appSupportDirectory: Directory('${hiveDirectory.path}/app-support'),
      pathPolicy: pathPolicy,
    );
    final mutations = WorkspaceMutationService(
      pathPolicy: pathPolicy,
      snapshotPort: snapshots,
    );
    final workspaceService = WorkModeWorkspaceService(
      db: database,
      grantService: grants,
    );
    final workspace = await workspaceService.loadOrCreate(
      conversationId: 'stale-artifact-group',
      isDirectChat: false,
      requireWritable: true,
    );
    final workspaceRoot = workspace.workDirPath;
    // Match the command's declaredImpact exactly: declaredImpact is a hint, so
    // an unchanged file at that path must not bypass the before/after check.
    final stale = File(
      '$workspaceRoot/${_ScriptArtifactGateway.artifactName}',
    );
    await stale.writeAsString('旧数据');

    final config = ApiConfig(
      id: 'stale-artifact-config',
      name: 'Stale artifact test',
      provider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
    );
    final character = AICharacter(
      id: 'stale-artifact-character',
      name: '旧文件校验角色',
      avatar: 'SA',
      age: 30,
      role: '旧文件校验角色',
      personalityTags: const [],
      systemPrompt: '只按工具协议工作。',
      apiKey: '',
      apiProvider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
      apiConfigId: config.id,
      toolPermissions: const [
        ToolPermission.workspaceRead,
        ToolPermission.workspacePatch,
        ToolPermission.commandRun,
      ],
    );
    await database.apiConfigBox.put(config.id, config);
    await database.aiCharacterBox.put(character.id, character);

    final mediaDirectory =
        await Directory('${hiveDirectory.path}/media').create(recursive: true);
    var mediaCopyIndex = 0;
    final runner = DefaultWorkTaskRunner(
      database: database,
      eventStore: eventStore,
      credentials: _TestCredentials(),
      gateway: _ScriptArtifactGateway(finishAfterCommand: true),
      // 时钟略快于文件系统：旧实现的时间窗因此稳定覆盖那份事先放好的文件，
      // 复现不依赖测试机的实际耗时。
      clock: () => DateTime.now().add(const Duration(seconds: 1)),
      workspaceService: workspaceService,
      folderGrantService: grants,
      workspaceFileService: files,
      mutationService: mutations,
      resourceLockManager: WorkResourceLockManager(isWindows: false),
      mediaCopier: (source, type, {fileName}) async {
        final target = File(
          '${mediaDirectory.path}/${mediaCopyIndex++}-${fileName ?? 'attachment'}',
        );
        await source.copy(target.path);
        return MediaAttachment(
          type: type,
          localPath: target.path,
          fileName: fileName,
          fileSize: await target.length(),
        );
      },
      commandRunner: WorkCommandRunner(
        policy: WorkCommandPolicy(
          authorizedRoots: [workspaceRoot],
          isWindows: false,
        ),
        processStarter: (command, {required env, required shell}) async {
          // 这条命令没有写出任何文件。
          return WorkCommandProcess(
            pid: 41,
            stdout: Stream<List<int>>.value(utf8.encode('done\n')),
            stderr: const Stream<List<int>>.empty(),
            exitCode: Future<int>.value(0),
            terminateTree: ({bool force = false}) async {},
          );
        },
      ),
    );
    final task = AgentTask(
      id: 'stale-artifact-task',
      groupId: 'stale-artifact-group',
      characterId: character.id,
      userRequest: '从网上取数并生成一份 xlsx 大模型排名表',
      requestedPermissions: character.toolPermissions,
      assignedCharacterIds: [character.id],
      workModeTask: true,
    );

    for (var round = 0; round < 8; round++) {
      if (task.isTerminal) break;
      await runner.run(task, WorkTaskCancellation());
      if (task.status == AgentTaskStatus.waitingForApproval) {
        final checkpoint = jsonDecode(task.executionStateJson) as Map;
        task
          ..executionStateJson = jsonEncode({
            ...checkpoint,
            'approvalDecision': 'approvedWithoutUndo',
          })
          ..status = AgentTaskStatus.queued;
        continue;
      }
      if (task.status != AgentTaskStatus.queued) break;
    }

    expect(
      task.status,
      isNot(AgentTaskStatus.completed),
      reason: 'status=${task.status} error=${task.lastError}',
    );
    expect(
      task.lastArtifactPaths,
      isNot(contains(stale.path)),
      reason: '命令之前就在工作区里的文件被当成了本次运行的产物',
    );
  });

  test(
      'an unmet artifact contract reports its own message, not a Dart '
      'exception string', () async {
    final grants = WorkFolderGrantService(
      box: database.appSettingsBox,
      directoryValidator: (_) async => true,
      writeDirectoryValidator: (_) async => true,
      isWindows: false,
    );
    await grants.authorizeDirectory(
      authorizedDirectory.path,
      consent: (_) async => true,
    );
    final pathPolicy = WorkspacePathPolicy(grantService: grants);
    final files = WorkspaceFileService(pathPolicy: pathPolicy);
    final mutations = WorkspaceMutationService(
      pathPolicy: pathPolicy,
      snapshotPort: WorkSnapshotService(
        appSupportDirectory: Directory('${hiveDirectory.path}/app-support'),
        pathPolicy: pathPolicy,
      ),
    );
    final workspaceService = WorkModeWorkspaceService(
      db: database,
      grantService: grants,
    );
    await workspaceService.loadOrCreate(
      conversationId: 'contract-message-group',
      isDirectChat: false,
      requireWritable: true,
    );

    final config = ApiConfig(
      id: 'contract-message-config',
      name: 'Contract message test',
      provider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
    );
    final character = AICharacter(
      id: 'contract-message-character',
      name: '契约文案角色',
      avatar: 'CM',
      age: 30,
      role: '契约文案角色',
      personalityTags: const [],
      systemPrompt: '只按工具协议工作。',
      apiKey: '',
      apiProvider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
      apiConfigId: config.id,
      toolPermissions: const [ToolPermission.workspaceRead],
    );
    await database.apiConfigBox.put(config.id, config);
    await database.aiCharacterBox.put(character.id, character);

    // The model claims completion without producing anything; the request names
    // a deliverable, so the completion guard rejects it.
    final runner = DefaultWorkTaskRunner(
      database: database,
      eventStore: eventStore,
      credentials: _TestCredentials(),
      gateway: _WorkspaceListPathGateway(const <Object?>[]),
      workspaceService: workspaceService,
      folderGrantService: grants,
      workspaceFileService: files,
      mutationService: mutations,
    );
    final task = AgentTask(
      id: 'contract-message-task',
      groupId: 'contract-message-group',
      characterId: character.id,
      userRequest: '生成一份 xlsx 大模型排名表',
      requestedPermissions: character.toolPermissions,
      assignedCharacterIds: [character.id],
      workModeTask: true,
    );

    await runner.run(task, WorkTaskCancellation());

    expect(task.status, AgentTaskStatus.failed, reason: task.lastError);
    final failure = WorkFailure.fromTask(task);
    expect(failure, isNotNull);
    expect(failure!.reason, contains('用户要求文件产物'));
    // Wrapping the guard's prose in a StateError used to reach the chat as
    // "Bad state: 用户要求文件产物…".
    expect(failure.reason, isNot(contains('Bad state')));
    expect(failure.technicalDetail, isNot(contains('Bad state')));
  });

  test('a failed artifact task does not hand over its intermediates as 产物',
      () async {
    final grants = WorkFolderGrantService(
      box: database.appSettingsBox,
      directoryValidator: (_) async => true,
      writeDirectoryValidator: (_) async => true,
      isWindows: false,
    );
    await grants.authorizeDirectory(
      authorizedDirectory.path,
      consent: (_) async => true,
    );
    final pathPolicy = WorkspacePathPolicy(grantService: grants);
    final files = WorkspaceFileService(pathPolicy: pathPolicy);
    final mutations = WorkspaceMutationService(
      pathPolicy: pathPolicy,
      snapshotPort: WorkSnapshotService(
        appSupportDirectory: Directory('${hiveDirectory.path}/app-support'),
        pathPolicy: pathPolicy,
      ),
    );
    final workspaceService = WorkModeWorkspaceService(
      db: database,
      grantService: grants,
    );
    final workspace = await workspaceService.loadOrCreate(
      conversationId: 'intermediate-failure-group',
      isDirectChat: false,
      requireWritable: true,
    );
    // The run wrote only its generator script; the deck itself never appeared.
    final script = File(
      '${workspace.workDirPath}/generate_philosophy_ppt.py',
    );
    await script.writeAsString('print("deck")');

    final config = ApiConfig(
      id: 'intermediate-failure-config',
      name: 'Intermediate failure test',
      provider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
    );
    final character = AICharacter(
      id: 'intermediate-failure-character',
      name: '中间文件角色',
      avatar: 'IF',
      age: 30,
      role: '中间文件角色',
      personalityTags: const [],
      systemPrompt: '只按工具协议工作。',
      apiKey: '',
      apiProvider: ApiProvider.deepseek.name,
      modelName: 'deepseek-chat',
      apiConfigId: config.id,
      toolPermissions: const [ToolPermission.workspaceRead],
    );
    await database.apiConfigBox.put(config.id, config);
    await database.aiCharacterBox.put(character.id, character);

    final mediaDirectory =
        await Directory('${hiveDirectory.path}/media').create(recursive: true);
    var mediaCopyIndex = 0;
    final runner = DefaultWorkTaskRunner(
      database: database,
      eventStore: eventStore,
      credentials: _TestCredentials(),
      workspaceService: workspaceService,
      folderGrantService: grants,
      workspaceFileService: files,
      mutationService: mutations,
      mediaCopier: (source, type, {fileName}) async {
        final target = File(
          '${mediaDirectory.path}/${mediaCopyIndex++}-${fileName ?? 'attachment'}',
        );
        await source.copy(target.path);
        return MediaAttachment(
          type: type,
          localPath: target.path,
          fileName: fileName,
          fileSize: await target.length(),
        );
      },
    );
    final task = AgentTask(
      id: 'intermediate-failure-task',
      groupId: 'intermediate-failure-group',
      characterId: character.id,
      userRequest: '生成一份 pptx 幻灯片文件',
      status: AgentTaskStatus.failed,
      workModeTask: true,
    )..lastArtifactPaths = <String>[script.path];

    await runner.reportFailure(
      task,
      WorkFailure.fromLoopMessage(
        WorkArtifactDeliveryGuard.missingArtifactMessage,
        scope: 'completion',
      ),
    );

    final reply = database.messageBox.values.singleWhere(
      (message) =>
          message.groupId == task.groupId &&
          message.senderId == character.id &&
          message.senderType == 'ai',
    );
    expect(reply.content, contains('任务未完成'));
    // The user still has to be able to find the file the run did write.
    expect(reply.content, contains('generate_philosophy_ppt.py'));
    // But a failure must not read as "here is your deliverable": the attached
    // files are described as intermediates, never as 产物.
    expect(reply.content, contains('中间文件'));
    expect(reply.content, isNot(contains('个产物')));
  });
}

List<int> _xlsxBytes() {
  final archive = Archive()
    ..addFile(
      ArchiveFile.string(
        'xl/workbook.xml',
        '<workbook xmlns:r="rel"><sheets><sheet name="预算" '
            'r:id="rId1"/></sheets></workbook>',
      ),
    )
    ..addFile(
      ArchiveFile.string(
        'xl/_rels/workbook.xml.rels',
        '<Relationships><Relationship Id="rId1" '
            'Target="worksheets/sheet1.xml"/></Relationships>',
      ),
    )
    ..addFile(
      ArchiveFile.string(
          'xl/sharedStrings.xml', '<sst><si><t>设计</t></si></sst>'),
    )
    ..addFile(
      ArchiveFile.string(
        'xl/worksheets/sheet1.xml',
        '<worksheet><sheetData><row r="1"><c r="A1" t="s"><v>0</v>'
            '</c><c r="B1"><v>1200</v></c></row></sheetData></worksheet>',
      ),
    );
  return ZipEncoder().encode(archive);
}

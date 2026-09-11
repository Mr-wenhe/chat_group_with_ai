import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/models/character_skill.dart';
import 'package:chat_group/core/models/media_attachment.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/tool_permission.dart';
import 'package:chat_group/core/streaming/chat_stream_event.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/features/agentic/agent_attachment_context.dart';
import 'package:chat_group/features/agentic/agent_prompt_builder.dart';
import 'package:chat_group/features/agentic/character_skill_resolver.dart';
import 'package:chat_group/features/agentic/context_window_manager.dart';
import 'package:chat_group/features/agentic/expert_skill_catalog.dart';
import 'package:chat_group/features/agentic/skill_download_service.dart';
import 'package:chat_group/features/agentic/tool_request.dart';
import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/ai_governance/ai_governance_store.dart';
import 'package:chat_group/features/ai_governance/ai_request_gateway.dart';
import 'package:chat_group/features/work_mode/agent_decision.dart';
import 'package:chat_group/features/work_mode/agent_decision_parser.dart';
import 'package:chat_group/features/work_mode/work_agent_loop.dart';
import 'package:chat_group/features/work_mode/work_artifact_delivery_guard.dart';
import 'package:chat_group/features/work_mode/work_approval_decision.dart';
import 'package:chat_group/features/work_mode/work_approval_fingerprint.dart';
import 'package:chat_group/features/work_mode/work_change_plan.dart';
import 'package:chat_group/features/work_mode/work_command_runner.dart';
import 'package:chat_group/features/work_mode/work_context_builder.dart';
import 'package:chat_group/features/work_mode/work_folder_grant_service.dart';
import 'package:chat_group/features/work_mode/work_handoff_state.dart';
import 'package:chat_group/features/work_mode/work_mode_policy.dart';
import 'package:chat_group/features/work_mode/work_mode_directory_service.dart';
import 'package:chat_group/features/work_mode/work_mode_workspace_service.dart';
import 'package:chat_group/features/work_mode/work_document_tool.dart';
import 'package:chat_group/features/work_mode/work_failure.dart';
import 'package:chat_group/features/work_mode/work_public_update_stream.dart';
import 'package:chat_group/features/work_mode/work_resource_lock_manager.dart';
import 'package:chat_group/features/work_mode/work_task_coordinator.dart';
import 'package:chat_group/features/work_mode/work_task_event.dart';
import 'package:chat_group/features/work_mode/work_task_event_store.dart';
import 'package:chat_group/features/work_mode/work_task_error_sanitizer.dart';
import 'package:chat_group/features/work_mode/work_tool_registry.dart';
import 'package:chat_group/features/work_mode/work_model_progress_throttle.dart';
import 'package:chat_group/features/work_mode/workspace_file_service.dart';
import 'package:chat_group/features/work_mode/workspace_mutation_service.dart';
import 'package:chat_group/features/work_mode/workspace_path_policy.dart';
import 'package:chat_group/features/work_mode/stage02_workspace_file_tool.dart';
import 'package:chat_group/features/web_search/security/search_secret_scanner.dart';
import 'package:dio/dio.dart';

/// App-scoped adapter between durable work tasks and the one production loop.
///
/// [WorkAgentLoop] owns protocol parsing, retry/budget boundaries, progress
/// events and task checkpoints. This class only supplies the existing model
/// gateway, character skills, Stage 02 workspace services and public message
/// persistence. It intentionally does not instantiate a model client, a
/// legacy chat-agent facade, or a cross-process service.
class DefaultWorkTaskRunner
    implements
        WorkTaskRunner,
        WorkTaskProgressReporter,
        WorkTaskCheckpointReporter,
        WorkTaskResourceLockPlanner,
        WorkTaskInstallHandler,
        WorkTaskWorkspaceRebinder,
        WorkTaskVisionModelValidator,
        WorkTaskFailureReporter {
  final DatabaseService database;
  final WorkTaskEventStore eventStore;
  final ApiCredentialResolver credentials;
  final AiRequestGateway gateway;
  final WorkModeWorkspaceService workspaceService;
  final WorkFolderGrantService? folderGrantService;
  final WorkspaceFileService? workspaceFileService;
  final WorkspaceMutationService? mutationService;
  final WorkResourceLockManager? resourceLockManager;
  final WorkCommandRunner? commandRunner;
  final Future<MediaAttachment> Function(
    File source,
    String type, {
    String? fileName,
  })? mediaCopier;
  final DateTime Function() clock;

  void Function(AgentTask task)? _taskUpdateSink;
  Future<void> Function(AgentTask task)? _taskCheckpointSink;

  /// The full request is retained only while this process is waiting for a
  /// user decision. Durable task fields contain the redacted checkpoint.
  final Map<String, ToolRequest> _pendingRequests = <String, ToolRequest>{};

  // A handoff can make two task runners reach the skill tools close together.
  // Serialize the paired skill-box and character-box update so Hive cannot
  // leave a character pointing at a skill that was not persisted yet.
  Future<void> _skillMutationQueue = Future<void>.value();

  DefaultWorkTaskRunner({
    required this.database,
    required this.eventStore,
    ApiCredentialResolver? credentials,
    AiRequestGateway? gateway,
    WorkModeWorkspaceService? workspaceService,
    this.folderGrantService,
    this.workspaceFileService,
    this.mutationService,
    this.resourceLockManager,
    this.commandRunner,
    this.mediaCopier,
    DateTime Function()? clock,
  })  : credentials = credentials ?? SecureApiCredentialResolver(),
        gateway = gateway ??
            AiRequestGateway(
              store: AiGovernanceStore.forDatabase(database),
            ),
        workspaceService = workspaceService ??
            WorkModeWorkspaceService(
              db: database,
              grantService: folderGrantService,
            ),
        clock = clock ?? DateTime.now;

  @override
  void setTaskUpdateSink(void Function(AgentTask task) sink) {
    _taskUpdateSink = sink;
  }

  @override
  void setTaskCheckpointSink(Future<void> Function(AgentTask task) sink) {
    _taskCheckpointSink = sink;
  }

  @override
  Future<void> rebindWorkspace(AgentTask task, String grantedPath) async {
    if (grantedPath.trim().isEmpty) return;
    await workspaceService.rebindConversationWorkspace(
      conversationId: task.groupId,
      isDirectChat: task.groupId.startsWith('dm:'),
      grantedPath: grantedPath,
    );
  }

  @override
  Future<void> reportFailure(AgentTask task, WorkFailure failure) async {
    final character = database.aiCharacterBox.get(task.characterId);
    if (character == null) return;
    await _appendPublicMessage(
      task,
      character,
      await _failureReply(task, failure),
    );
  }

  @override
  bool supportsVisionModel(String characterId) {
    try {
      final character = database.aiCharacterBox.get(characterId.trim());
      if (character == null ||
          !character.isActive ||
          !character.agenticEnabled) {
        return false;
      }
      final config = _resolveApiConfig(character);
      if (config == null || (!config.hasCredential && !config.hasApiKey)) {
        return false;
      }
      return gateway
          .capability(_providerFor(config), config.modelName)
          .supportsVision;
    } on Object {
      return false;
    }
  }

  @override
  bool supportsVisionModelForTask(AgentTask task, String characterId) {
    final normalized = characterId.trim();
    if (normalized.isEmpty || !supportsVisionModel(normalized)) return false;
    try {
      if (task.groupId.startsWith('dm:')) {
        // A private conversation is permanently bound to its character; a
        // vision handoff must never turn a DM into a cross-character channel.
        return task.groupId.substring(3) == normalized;
      }
      final group = database.chatGroupBox.get(task.groupId);
      return group != null && group.aiCharacterIds.contains(normalized);
    } on Object {
      return false;
    }
  }

  @override
  Future<void> run(
    AgentTask task,
    WorkTaskCancellation cancellation,
  ) async {
    final character = database.aiCharacterBox.get(task.characterId);
    if (character == null || !character.isActive || !character.agenticEnabled) {
      throw StateError('执行角色不可用');
    }
    final config = _resolveApiConfig(character);
    if (config == null) throw StateError('角色尚未配置可用的模型');
    final apiKey = await credentials.resolve(config);
    if (apiKey == null || apiKey.trim().isEmpty) {
      throw StateError('角色模型凭据不可用');
    }
    final files = workspaceFileService;
    final mutations = mutationService;
    if (files == null || mutations == null) {
      // A missing Stage 02 capability is a visible configuration failure. It
      // must never silently fall back to a cross-process service or another
      // runtime.
      throw StateError('工作模式文件服务未就绪，请稍后重试。');
    }
    if (cancellation.isCancelled || task.isTerminal) return;

    // An in-process approval continuation normally keeps the full request in
    // memory. The durable checkpoint is intentionally redacted, so it is only
    // promoted back into this map by installMissingTool after a trusted
    // installer succeeds and the structured command still matches the saved
    // checkpoint. All other post-restart checkpoints are re-planned by the
    // model because they may omit content or command arguments.
    final hasPendingCheckpoint = task.pendingToolRequestJson.trim().isNotEmpty;
    final persistedPending = hasPendingCheckpoint
        ? ToolRequest.fromJsonString(task.pendingToolRequestJson)
        : null;
    final inMemoryPending =
        hasPendingCheckpoint ? _pendingRequests[task.id] : null;
    final requiresWritableWorkspace = _pendingRequiresWritableWorkspace(
      task,
      inMemoryPending ?? persistedPending,
    );
    final workspace = await workspaceService.loadOrCreate(
      conversationId: task.groupId,
      isDirectChat: task.groupId.startsWith('dm:'),
      requireWritable: requiresWritableWorkspace,
      preferredRootPath: const WorkModeDirectoryService().requestedDesktopPath(
        task.userRequest,
      ),
    );
    if (requiresWritableWorkspace && _hasWritableWorkspaceMarker(task)) {
      _consumeWritableWorkspaceMarker(task);
      await _persistCheckpoint(task);
    }
    final provider = _providerFor(config);
    final history = await _conversationHistory(task);
    final requestText = await _requestWithAttachmentContext(task);
    // Commands without an explicit workingDirectory must follow the same
    // authorized root as workspace.patch/read. Using the app's private
    // processing directory here made a request for “桌面” silently write to
    // ~/.chat_group instead.
    final defaultCommandWorkingDirectory = workspace.workDirPath;
    final decision = _approvalDecision(task.executionStateJson);
    final scope = _approvalScope(task.executionStateJson);
    final cancellationToken = CancelToken();
    final cancelForwarder = cancellation.whenCancelled.then<void>(
      (_) => cancellationToken.cancel('用户已停止任务'),
    );

    try {
      final skills = _skillsFor(character, task.userRequest);
      final capability = gateway.capability(provider, config.modelName);
      final registry = _registryFor(
        task: task,
        character: character,
        workspaceRoot: workspace.workDirPath,
        files: files,
        mutations: mutations,
        approvalDecision: decision,
        approvalScope: scope,
        modelCapability: capability,
      );
      final systemPrompt = AgentPromptBuilder.buildAgentDecisionPrompt(
        rolePlaySystemPrompt: character.rolePlaySystemPrompt,
        skills: skills,
        userRequest: requestText,
        workModeContext: _workModeContext(
          task,
          character,
          registry,
          workspaceRoot: workspace.workDirPath,
        ),
      );
      final loop = WorkAgentLoop(
        model: (request) => _completeModelTurn(
          request,
          task: task,
          provider: provider,
          config: config,
          apiKey: apiKey,
          requestText: requestText,
          cancellationToken: cancellationToken,
          capabilityMaxOutput: capability.maxOutput,
          capabilityContextWindow: capability.contextWindow,
        ),
        registry: registry,
        parser: AgentDecisionParser(
          defaultCommandWorkingDirectory: defaultCommandWorkingDirectory,
        ),
        eventStore: eventStore,
        clock: clock,
        onCheckpoint: _persistCheckpoint,
        completionGuard: _validateCompletion,
        contextCompressionModel: (snapshot) => _compressWorkContext(
          snapshot,
          task: task,
          provider: provider,
          config: config,
          apiKey: apiKey,
        ),
        systemPrompt: systemPrompt,
        // Skill creation/download is a normal in-task mutation. Rebuild the
        // prompt before every model turn so the next turn can use the newly
        // persisted skill without injecting the entire skill library up front.
        systemPromptBuilder: () => AgentPromptBuilder.buildAgentDecisionPrompt(
          rolePlaySystemPrompt: character.rolePlaySystemPrompt,
          skills: _skillsFor(character, requestText),
          userRequest: requestText,
          workModeContext: _workModeContext(
            task,
            character,
            registry,
            workspaceRoot: workspace.workDirPath,
          ),
        ),
        maxActions: task.actionLimit,
        softTimeLimit: task.softTimeLimit,
      );
      final result = await loop.execute(
        task,
        cancellation: cancellation,
        conversationHistory: history,
        // Only a full in-memory request may be replayed. A persisted request
        // is a display-safe checkpoint and may omit sensitive payloads; the
        // install recovery path can populate this map only for a complete,
        // sanitized command.run checkpoint after the installer succeeds.
        approvedPendingTool: inMemoryPending,
      );
      if (cancellation.isCancelled) return;
      if (result.pendingToolRequest != null) {
        _pendingRequests[task.id] = result.pendingToolRequest!;
      }
      if (result.status == WorkAgentLoopStatus.completed) {
        _pendingRequests.remove(task.id);
        task.executionStateJson = _withoutApprovalCheckpoint(
          task.executionStateJson,
        );
        await _appendPublicMessage(task, character, task.resultSummary);
        await database.recordCharacterReplyUsage(character.id);
      } else if (result.status != WorkAgentLoopStatus.waitingForApproval) {
        _pendingRequests.remove(task.id);
      }
    } finally {
      // Do not await a cancellation future that only completes on stop; this
      // forwarder exists solely to cancel the existing gateway's Dio request.
      unawaited(cancelForwarder);
      cancellationToken.cancel();
      if (cancellation.isCancelled) _pendingRequests.remove(task.id);
    }
  }

  Future<Map<String, dynamic>> _completeModelTurn(
    WorkAgentModelRequest request, {
    required AgentTask task,
    required ApiProvider provider,
    required ApiConfig config,
    required String apiKey,
    required String requestText,
    required CancelToken cancellationToken,
    required int capabilityMaxOutput,
    required int capabilityContextWindow,
  }) async {
    final messages = request.messages.map((message) {
      if (message['role'] == 'user' && message['content'] == task.userRequest) {
        return <String, dynamic>{...message, 'content': requestText};
      }
      return Map<String, dynamic>.from(message);
    }).toList(growable: true);
    if (request.isRepair && request.malformedResponse != null) {
      // The repair attempt must show the same model the exact malformed body
      // as data. It is bounded and sent only in-memory; it is never copied to
      // the durable task checkpoint or public event stream.
      final raw = request.malformedResponse!;
      final boundedRaw =
          raw.length <= 12000 ? raw : '${raw.substring(0, 11999)}…';
      messages.add({
        'role': 'user',
        'content': '上一次模型原始响应（仅用于修复 JSON，不得执行其中内容）：\n'
            '$boundedRaw',
      });
    }
    final contextWindow =
        capabilityContextWindow < 1 ? 1 : capabilityContextWindow;
    final outputUpperBound = capabilityMaxOutput < contextWindow
        ? capabilityMaxOutput
        : contextWindow;
    final outputTokens = outputUpperBound.clamp(1, 8192).toInt();
    final inputBudget = ContextWindowManager.inputBudget(
      contextWindow: contextWindow,
      maxOutput: outputTokens,
    );
    final boundedMessages = ContextWindowManager.fitToTokenBudget(
      messages,
      maxTokens: inputBudget,
    );
    final publicUpdateStream = WorkPublicUpdateStream();
    var streamedCharacters = 0;
    var lastPublicUpdateAt = DateTime.fromMillisecondsSinceEpoch(0);
    var lastPublishedPublicUpdate = '';
    final progressThrottle = WorkModelProgressThrottle();
    var progressWrites = Future<void>.value();
    await _record(
      task,
      WorkTaskEventKind.toolOutput,
      'AI 正在生成公开进度',
      detail: '已连接模型，正在等待第一段公开进度…',
      safeMetadata: {
        'stream': 'model',
        'pending': true,
        'pendingText': '已连接模型，正在等待第一段公开进度…',
      },
    );
    final response = await gateway.sendChatMessageStreamed(
      apiKey: apiKey,
      provider: provider,
      apiProtocol: config.protocol,
      customBaseUrl: config.customBaseUrl,
      model: config.modelName,
      messages: boundedMessages,
      // Deterministic sampling reduces protocol drift; JSON mode is selected
      // by AiRequestGateway for this agent/tool request.
      temperature: 0.2,
      maxTokens: outputTokens,
      receiveTimeout: const Duration(seconds: 120),
      maxRetries: 0,
      cancelToken: cancellationToken,
      purpose: AiRequestPurpose.agent,
      conversationId: task.groupId,
      characterId: task.characterId,
      requiresTools: true,
      userInitiated: true,
      onEvent: (event) {
        // Dio cancellation can race with the last bytes already buffered by
        // the provider. Ignore those late callbacks so a stopped task cannot
        // keep extending its durable event queue.
        if (cancellationToken.isCancelled) return;
        if (event.type != ChatStreamEventType.token) return;
        final delta = event.delta ?? '';
        streamedCharacters += delta.length;
        final now = clock();

        final publicUpdate = WorkPublicUpdateStream.sanitize(
          publicUpdateStream.add(delta),
        );
        final publicUpdateChanged = publicUpdate.isNotEmpty &&
            publicUpdate != lastPublishedPublicUpdate;
        final shouldPublishPublicUpdate = publicUpdateChanged &&
            (lastPublishedPublicUpdate.isEmpty ||
                publicUpdate.length - lastPublishedPublicUpdate.length >= 24 ||
                now.difference(lastPublicUpdateAt) >=
                    const Duration(milliseconds: 250));
        if (shouldPublishPublicUpdate) {
          lastPublishedPublicUpdate = publicUpdate;
          lastPublicUpdateAt = now;
          final draft = publicUpdate;
          final characters = streamedCharacters;
          progressWrites = progressWrites.then<void>((_) async {
            await _record(
              task,
              WorkTaskEventKind.modelOutput,
              'AI 正在输出公开进度',
              detail: draft,
              safeMetadata: {
                'stream': 'public_update',
                'publicDraft': draft,
                'characters': characters,
              },
            );
          });
        }

        if (!progressThrottle.shouldPublish(
          streamedCharacters: streamedCharacters,
          now: now,
        )) {
          return;
        }
        final characters = streamedCharacters;
        progressWrites = progressWrites.then<void>((_) async {
          final safeMetadata = <String, Object?>{
            'stream': 'model',
            'characters': characters,
          };
          if (publicUpdate.isNotEmpty) {
            safeMetadata['publicDraft'] = publicUpdate;
          }
          await _record(
            task,
            WorkTaskEventKind.toolOutput,
            publicUpdate.isEmpty ? 'AI 正在整理公开进度' : 'AI 公开进度',
            detail: publicUpdate.isEmpty ? '正在等待可公开的执行内容。' : publicUpdate,
            safeMetadata: safeMetadata,
          );
        });
      },
    );
    // A short final delta may not pass the live-update throttle before the
    // stream closes. Flush the decoded public field so the durable timeline
    // contains the complete user-facing content, not only an earlier prefix.
    var finalPublicUpdate = WorkPublicUpdateStream.sanitize(
      publicUpdateStream.add(''),
    );
    if (finalPublicUpdate.isEmpty) {
      // Some OpenAI-compatible providers emit the JSON protocol through
      // `reasoning_content` or only attach it to the final SSE event. The
      // gateway intentionally returns that field only as a compatibility
      // fallback; extract only its public_update field here so the panel does
      // not remain blank after a successful model turn.
      finalPublicUpdate = _publicUpdateFromResponse(response);
    }
    if (finalPublicUpdate.isNotEmpty &&
        finalPublicUpdate != lastPublishedPublicUpdate) {
      lastPublishedPublicUpdate = finalPublicUpdate;
      final characters = streamedCharacters;
      progressWrites = progressWrites.then<void>((_) async {
        await _record(
          task,
          WorkTaskEventKind.modelOutput,
          'AI 正在输出公开进度',
          detail: finalPublicUpdate,
          safeMetadata: {
            'stream': 'public_update',
            'publicDraft': finalPublicUpdate,
            'characters': characters,
            if (streamedCharacters == 0) 'source': 'stream_fallback',
          },
        );
      });
    }
    // Do not let a throttled model-progress event race the next tool/finish
    // event. Waiting for this short diagnostic queue preserves the durable
    // event order while keeping raw protocol content private. Only the
    // explicitly user-facing public_update field is recorded for the panel.
    await progressWrites;
    return response;
  }

  String _publicUpdateFromResponse(Map<String, dynamic> response) {
    final raw = response['message'];
    if (raw is! String || raw.trim().isEmpty) return '';
    final stream = WorkPublicUpdateStream();
    return WorkPublicUpdateStream.sanitize(stream.add(raw));
  }

  Future<WorkContextSnapshot?> _compressWorkContext(
    WorkContextSnapshot snapshot, {
    required AgentTask task,
    required ApiProvider provider,
    required ApiConfig config,
    required String apiKey,
  }) async {
    final capability = gateway.capability(provider, config.modelName);
    final contextWindow =
        capability.contextWindow < 1 ? 1 : capability.contextWindow;
    final outputUpperBound = capability.maxOutput < contextWindow
        ? capability.maxOutput
        : contextWindow;
    final outputTokens = outputUpperBound.clamp(1, 768).toInt();
    final inputBudget = ContextWindowManager.inputBudget(
      contextWindow: contextWindow,
      maxOutput: outputTokens,
    );
    final response = await gateway.sendChatMessage(
      apiKey: apiKey,
      provider: provider,
      apiProtocol: config.protocol,
      customBaseUrl: config.customBaseUrl,
      model: config.modelName,
      messages: ContextWindowManager.fitToTokenBudget(
        [
          {
            'role': 'system',
            'content': '你是工作任务检查点压缩器。只输出严格 JSON object，字段为 '
                'completedSummaries（字符串数组）和 recentToolResults（安全诊断对象数组）。'
                '只总结公开进度，不得输出文件正文、私有 reasoning、凭据、原始响应或会话消息。',
          },
          {'role': 'user', 'content': snapshot.toJsonString()},
        ],
        maxTokens: inputBudget,
      ),
      purpose: AiRequestPurpose.summary,
      conversationId: task.groupId,
      characterId: task.characterId,
      temperature: 0.2,
      maxTokens: outputTokens,
      receiveTimeout: const Duration(seconds: 30),
      maxRetries: 0,
      requiresTools: false,
      userInitiated: false,
    );
    if (response['success'] != true) return null;
    final raw = response['message'] ?? response['content'];
    if (raw is! String || raw.trim().isEmpty) return null;
    final jsonText = _extractJsonObject(raw);
    if (jsonText == null) return null;
    try {
      final decoded = jsonDecode(jsonText);
      if (decoded is! Map) return null;
      final summaries = _stringList(decoded['completedSummaries']);
      final summary = decoded['summary'];
      if (summaries.isEmpty && summary is String && summary.trim().isNotEmpty) {
        summaries.add(summary.trim());
      }
      final results = <Map<String, dynamic>>[];
      final rawResults = decoded['recentToolResults'];
      if (rawResults is List) {
        for (final item in rawResults) {
          if (item is Map) results.add(Map<String, dynamic>.from(item));
        }
      }
      return snapshot.copyWith(
        completedSummaries: summaries,
        recentToolResults: results,
      );
    } on Object {
      return null;
    }
  }

  String? _extractJsonObject(String raw) {
    final trimmed = raw.trim();
    final fenced = RegExp(r'```(?:json)?\s*([\s\S]*?)```', caseSensitive: false)
        .firstMatch(trimmed)
        ?.group(1)
        ?.trim();
    final candidate = fenced ?? trimmed;
    try {
      final decoded = jsonDecode(candidate);
      return decoded is Map ? candidate : null;
    } on Object {
      return null;
    }
  }

  List<String> _stringList(Object? value) {
    if (value is! List) return <String>[];
    return value
        .whereType<String>()
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .take(16)
        .toList(growable: true);
  }

  @override
  Iterable<WorkResourceLockRequest> planResourceLocks(AgentTask task) {
    final decoded = _decodeMap(task.executionStateJson);
    final raw = decoded['resourceLocks'];
    if (raw is! List) return const <WorkResourceLockRequest>[];
    final locks = <WorkResourceLockRequest>[];
    for (final item in raw) {
      if (item is! Map || item['path'] is! String) {
        throw const FormatException('资源锁计划格式无效');
      }
      final mode = switch (item['mode']) {
        'read' => WorkResourceLockMode.read,
        'write' => WorkResourceLockMode.write,
        'treeWrite' => WorkResourceLockMode.treeWrite,
        _ => throw const FormatException('资源锁模式无效'),
      };
      locks.add(
          WorkResourceLockRequest(path: item['path'] as String, mode: mode));
    }
    return locks;
  }

  WorkToolRegistry _registryFor({
    required AgentTask task,
    required AICharacter character,
    required String workspaceRoot,
    required WorkspaceFileService files,
    required WorkspaceMutationService mutations,
    required WorkChangeApprovalDecision? approvalDecision,
    required WorkApprovalScope? approvalScope,
    required ModelCapability modelCapability,
  }) {
    final stage02 = Stage02WorkspaceFileTool(
      files: files,
      mutations: mutations,
      pathPolicy: files.pathPolicy,
      task: task,
      workspaceRoot: workspaceRoot,
      approvalDecision: approvalDecision,
      approvalScope: approvalScope,
      approvedSensitiveOperation: _approvedSensitiveOperation(task),
      approvalCapability: _approvalCapability(task),
      allowImplicitScope: approvalDecision == null &&
          (folderGrantService?.settings.confirmOrdinaryWrites == false),
      allowWithoutUndo: approvalDecision?.permitsWithoutUndo == true,
      resourceLockManager: resourceLockManager,
      onSensitiveRead: (path, operation) => unawaited(_record(
        task,
        WorkTaskEventKind.toolOutput,
        '已识别敏感文件读取',
        detail: operation,
        safeMetadata: {'path': path, 'sensitive': true},
      )),
    );
    // A routed task can change its current character between stages. In that
    // case intersect the task's requested capability set with the active
    // character's own permissions; a stale first-role list must never grant
    // the next role extra tools.
    final permissions = _permissionsForTask(task, character);
    final attachmentPaths = _attachmentPathsForTask(task);
    WorkToolResult permission(ToolPermission required) =>
        permissions.contains(required)
            ? const WorkToolResult.success()
            : WorkToolResult.permissionDenied(
                message: '角色未授予 ${required.name} 工具权限。',
              );
    bool attachmentDocumentPermission(WorkToolInvocation invocation) {
      if (permissions.contains(ToolPermission.workspaceRead)) return true;
      final path = invocation.arguments['path'];
      // ponytail: exact user attachments are the smallest safe exception;
      // arbitrary workspace reads still require the explicit role capability.
      return path is String &&
          _isReferencedAttachmentPath(
            path,
            attachmentPaths,
            isWindows: files.pathPolicy.isWindows,
          );
    }

    final documentDefinition = WorkDocumentTool.definition(
      pathPolicy: files.pathPolicy,
      workspaceRoot: workspaceRoot,
      modelCapability: modelCapability,
      attachmentPaths: attachmentPaths,
      isSensitivePath: files.isSensitivePath,
      allowSensitivePath: (path) => _sensitiveReadAllowed(
        task,
        stage02,
        operation: 'document',
        path: path,
      ),
      onSensitiveRead: (path) => _recordSensitiveReadApproval(
        task,
        stage02,
        <String, dynamic>{'requiresApproval': true, 'sensitive': true},
        operation: 'document',
        path: path,
      ),
    );
    Future<WorkToolResult> documentHandler(
      WorkToolInvocation invocation,
    ) async {
      if (!attachmentDocumentPermission(invocation)) {
        return permission(ToolPermission.workspaceRead);
      }
      final result = await documentDefinition.handler(invocation);
      if (_approvalDecision(task.executionStateJson) ==
              WorkChangeApprovalDecision.rejected &&
          result.data['requiresApproval'] == true &&
          result.data['sensitive'] == true) {
        task.executionStateJson = _withoutApprovalCheckpoint(
          task.executionStateJson,
        );
        return const WorkToolResult.success(
          message: '用户拒绝读取敏感文件，已跳过本次文档分析。',
          data: {'rejected': true, 'skipped': true, 'sensitive': true},
        );
      }
      if (_approvalDecision(task.executionStateJson) ==
          WorkChangeApprovalDecision.rejected) {
        task.executionStateJson = _withoutApprovalCheckpoint(
          task.executionStateJson,
        );
      }
      return result;
    }

    final definitions = <WorkToolDefinition>[
      WorkToolDefinition(
        name: AgentToolName.workspaceList,
        access: WorkToolAccess.readOnly,
        schema: const WorkToolSchema(
          fields: {
            'path': WorkToolValueType.string,
            'page': WorkToolValueType.integer,
            'pageSize': WorkToolValueType.integer,
            'recursive': WorkToolValueType.boolean,
          },
        ),
        handler: (invocation) async {
          final denied = permission(ToolPermission.workspaceRead);
          if (!denied.succeeded) return denied;
          return _mapFileResult(await stage02.listWithOptions(
            path: invocation.arguments['path']?.toString() ?? '.',
            page: _intArgument(invocation.arguments['page'], 0),
            pageSize: _intArgument(invocation.arguments['pageSize'], 200),
            recursive: invocation.arguments['recursive'] == true,
          ));
        },
      ),
      WorkToolDefinition(
        name: AgentToolName.workspaceRead,
        access: WorkToolAccess.readOnly,
        schema: const WorkToolSchema(
          fields: {
            'path': WorkToolValueType.string,
            'startByte': WorkToolValueType.integer,
            'byteLength': WorkToolValueType.integer,
          },
          required: {'path'},
        ),
        handler: (invocation) async {
          final denied = permission(ToolPermission.workspaceRead);
          if (!denied.succeeded) return denied;
          final args = invocation.arguments;
          final path = args['path'] as String;
          if (_requiresDocumentTool(path)) {
            // workspace.read has a strict UTF-8 contract. Redirect known
            // binary document extensions to the parser boundary so a model
            // choosing the text tool cannot turn a valid XLSX into a false
            // task failure.
            return documentHandler(invocation);
          }
          final startByte = _intArgument(args['startByte'], 0);
          final byteLength = _nullableInt(args['byteLength']);
          final approved = _sensitiveReadAllowed(
            task,
            stage02,
            operation: 'readTextRange',
            path: path,
            startByte: _intArgument(invocation.arguments['startByte'], 0),
            byteLength: byteLength,
          );
          final result = await stage02.readWithOptions(
            path,
            startByte: startByte,
            byteLength: byteLength,
            allowSensitive: approved,
          );
          if (_approvalDecision(task.executionStateJson) ==
                  WorkChangeApprovalDecision.rejected &&
              result['requiresApproval'] == true &&
              result['sensitive'] == true) {
            task.executionStateJson = _withoutApprovalCheckpoint(
              task.executionStateJson,
            );
            return const WorkToolResult.success(
              message: '用户拒绝读取敏感文件，已跳过本次读取。',
              data: {'rejected': true, 'skipped': true, 'sensitive': true},
            );
          }
          if (_approvalDecision(task.executionStateJson) ==
              WorkChangeApprovalDecision.rejected) {
            // A stale rejection from another operation must not poison later
            // ordinary reads; clear it after the safe, non-sensitive result.
            task.executionStateJson = _withoutApprovalCheckpoint(
              task.executionStateJson,
            );
          }
          _recordSensitiveReadApproval(task, stage02, result,
              operation: 'readTextRange',
              path: path,
              startByte: startByte,
              byteLength: byteLength);
          return _mapFileResult(result);
        },
      ),
      WorkToolDefinition(
        name: AgentToolName.workspaceSearch,
        access: WorkToolAccess.readOnly,
        schema: const WorkToolSchema(
          fields: {
            'path': WorkToolValueType.string,
            'query': WorkToolValueType.string,
            'recursive': WorkToolValueType.boolean,
            'caseSensitive': WorkToolValueType.boolean,
          },
          required: {'path', 'query'},
        ),
        handler: (invocation) async {
          final denied = permission(ToolPermission.workspaceRead);
          if (!denied.succeeded) return denied;
          final args = invocation.arguments;
          final path = args['path'] as String;
          final query = args['query'] as String;
          final recursive = args['recursive'] == true;
          final caseSensitive = args['caseSensitive'] != false;
          final approved = _sensitiveReadAllowed(
            task,
            stage02,
            operation: 'search',
            path: path,
            query: query,
            recursive: recursive,
            caseSensitive: caseSensitive,
          );
          final result = await stage02.search(
            path,
            query,
            recursive: recursive,
            caseSensitive: caseSensitive,
            allowSensitive: approved,
          );
          if (_approvalDecision(task.executionStateJson) ==
                  WorkChangeApprovalDecision.rejected &&
              result['requiresApproval'] == true &&
              result['sensitive'] == true) {
            task.executionStateJson = _withoutApprovalCheckpoint(
              task.executionStateJson,
            );
            return const WorkToolResult.success(
              message: '用户拒绝读取敏感文件，已跳过本次搜索。',
              data: {'rejected': true, 'skipped': true, 'sensitive': true},
            );
          }
          if (_approvalDecision(task.executionStateJson) ==
              WorkChangeApprovalDecision.rejected) {
            task.executionStateJson = _withoutApprovalCheckpoint(
              task.executionStateJson,
            );
          }
          _recordSensitiveReadApproval(task, stage02, result,
              operation: 'search',
              path: path,
              query: query,
              recursive: recursive,
              caseSensitive: caseSensitive);
          return _mapFileResult(result);
        },
      ),
      WorkToolDefinition(
        name: documentDefinition.name,
        access: documentDefinition.access,
        schema: documentDefinition.schema,
        handler: documentHandler,
      ),
      WorkToolDefinition(
        name: AgentToolName.workspacePatch,
        access: WorkToolAccess.mutation,
        schema: const WorkToolSchema(
          fields: {
            'path': WorkToolValueType.string,
            'content': WorkToolValueType.string,
            'expectedSha256': WorkToolValueType.string,
            'expectedFragment': WorkToolValueType.string,
            'replacement': WorkToolValueType.string,
            'overwrite': WorkToolValueType.boolean,
          },
          required: {'path'},
        ),
        mutationPipeline: _mutationPipeline(
          task: task,
          stage02: stage02,
          mutations: mutations,
          approvalScope: approvalScope,
        ),
        handler: (invocation) async {
          final denied = permission(ToolPermission.workspacePatch);
          if (!denied.succeeded) return denied;
          final args = invocation.arguments;
          final path = await _mutationPath(
            task,
            stage02,
            args['path'],
            allowAutoRename: !_isExactPatch(args),
          );
          final content = args['content'];
          if (content is String) {
            if (args['overwrite'] == false && await File(path).exists()) {
              return const WorkToolResult.failed(
                message: '目标文件已存在且 overwrite=false，未执行写入。',
                failureCode: 'targetExists',
              );
            }
            final raw = await stage02.write(path, content);
            return _mapFileResult(raw);
          }
          final patch = <String, dynamic>{
            'path': path,
            'expectedSha256': args['expectedSha256'],
            'expectedFragment': args['expectedFragment'],
            'replacement': args['replacement'],
          };
          return _mapFileResult(await stage02.applyPatch(jsonEncode(patch)));
        },
      ),
      WorkToolDefinition(
        name: AgentToolName.workspaceRename,
        access: WorkToolAccess.mutation,
        schema: const WorkToolSchema(
          fields: {
            'path': WorkToolValueType.string,
            'destinationPath': WorkToolValueType.string,
          },
          required: {'path', 'destinationPath'},
        ),
        mutationPipeline: _mutationPipeline(
          task: task,
          stage02: stage02,
          mutations: mutations,
          approvalScope: approvalScope,
        ),
        handler: (invocation) async {
          final denied = permission(ToolPermission.workspacePatch);
          if (!denied.succeeded) return denied;
          return _mapFileResult(await stage02.rename(
            _effectivePath(task, workspaceRoot, invocation.arguments['path']),
            _effectivePath(
              task,
              workspaceRoot,
              invocation.arguments['destinationPath'],
              enforceRevision: false,
            ),
          ));
        },
      ),
      WorkToolDefinition(
        name: AgentToolName.workspaceDelete,
        access: WorkToolAccess.mutation,
        schema: const WorkToolSchema(
          fields: {'path': WorkToolValueType.string},
          required: {'path'},
        ),
        mutationPipeline: _mutationPipeline(
          task: task,
          stage02: stage02,
          mutations: mutations,
          approvalScope: approvalScope,
        ),
        handler: (invocation) async {
          final denied = permission(ToolPermission.workspacePatch);
          if (!denied.succeeded) return denied;
          return _mapFileResult(await stage02.delete(
            _effectivePath(task, workspaceRoot, invocation.arguments['path']),
          ));
        },
      ),
      WorkToolDefinition(
        name: AgentToolName.commandRun,
        access: WorkToolAccess.mutation,
        schema: const WorkToolSchema(
          fields: {
            'executable': WorkToolValueType.string,
            'arguments': WorkToolValueType.stringList,
            'workingDirectory': WorkToolValueType.string,
            'declaredImpact': WorkToolValueType.stringList,
          },
          required: {
            'executable',
            'arguments',
            'workingDirectory',
            'declaredImpact',
          },
        ),
        mutationPipeline: _commandPipeline(
          task: task,
          character: character,
          workspaceRoot: workspaceRoot,
        ),
        handler: (invocation) => _runCommand(
          task,
          invocation,
          character,
          workspaceRoot,
        ),
      ),
      WorkToolDefinition(
        name: AgentToolName.skillCreate,
        access: WorkToolAccess.mutation,
        schema: const WorkToolSchema(
          fields: {
            'name': WorkToolValueType.string,
            'domain': WorkToolValueType.string,
            'description': WorkToolValueType.string,
            'instructions': WorkToolValueType.stringList,
            'permissions': WorkToolValueType.stringList,
          },
          required: {'name', 'domain', 'description', 'instructions'},
        ),
        mutationPipeline: _skillMutationPipeline(
          task: task,
          label: '创建应用内 Skill',
        ),
        handler: (invocation) async {
          final denied = permission(ToolPermission.skillCreate);
          if (!denied.succeeded) return denied;
          return _mapSkillResult(
            await _serializeSkillMutation(
              () => _createSkill(character, invocation.arguments),
            ),
          );
        },
      ),
      WorkToolDefinition(
        name: AgentToolName.skillDownload,
        access: WorkToolAccess.mutation,
        schema: const WorkToolSchema(
          fields: {
            'templateId': WorkToolValueType.string,
            'id': WorkToolValueType.string,
            'skillId': WorkToolValueType.string,
            'name': WorkToolValueType.string,
            'url': WorkToolValueType.string,
            'source': WorkToolValueType.string,
          },
          allowAdditional: false,
        ),
        mutationPipeline: _skillMutationPipeline(
          task: task,
          label: '安装应用内 Skill 模板',
        ),
        handler: (invocation) async {
          final denied = permission(ToolPermission.skillDownload);
          if (!denied.succeeded) return denied;
          return _mapSkillResult(
            await _serializeSkillMutation(
              () => _downloadSkill(character, invocation.arguments),
            ),
          );
        },
      ),
    ];
    return WorkToolRegistry(definitions: definitions);
  }

  WorkToolMutationPipeline _mutationPipeline({
    required AgentTask task,
    required Stage02WorkspaceFileTool stage02,
    required WorkspaceMutationService mutations,
    required WorkApprovalScope? approvalScope,
  }) {
    return WorkToolMutationPipeline(
      policy: (invocation) async {
        final plan = await _planForFileInvocation(
          task,
          invocation.call,
          stage02,
          mutations,
        );
        if (plan == null) {
          return const WorkToolResult.pathRejected(
            message: '无法在授权目录内解析精确文件路径。',
          );
        }
        // Keep policy and approval in one gate. This prevents a high-risk
        // command (or a no-snapshot write) from being approved by one gate and
        // then silently reusing the same decision in a second gate.
        return _mutationApprovalGate(task, invocation, plan);
      },
      approval: null,
      snapshot: (invocation) async {
        final plan = await _planForFileInvocation(
          task,
          invocation.call,
          stage02,
          mutations,
        );
        if (plan == null || plan.snapshotAvailable) return null;
        return const WorkToolResult.waitingForApproval(
          message: '当前文件变更无法创建可撤销快照，请明确批准后继续。',
          data: {'noUndoRequired': true},
        );
      },
      // Stage02WorkspaceFileTool and WorkspaceMutationService own the actual
      // path/file locks. This named gate documents that ownership without
      // introducing a second lock owner around the same mutation.
      lock: (_) => null,
    );
  }

  WorkToolMutationPipeline _commandPipeline({
    required AgentTask task,
    required AICharacter character,
    required String workspaceRoot,
  }) {
    return WorkToolMutationPipeline(
      policy: (invocation) async {
        if (!_permissionsForTask(task, character)
            .contains(ToolPermission.commandRun)) {
          return const WorkToolResult.permissionDenied(
            message: '角色未授予 commandRun 工具权限。',
          );
        }
        final command = _commandFromCall(invocation.call, workspaceRoot);
        if (command == null) {
          return const WorkToolResult.failed(
            message:
                '命令必须使用 executable、arguments、workingDirectory 和 declaredImpact。',
            failureCode: 'invalidCommand',
          );
        }
        final policy = _commandPolicyFor(character, workspaceRoot).evaluate(
          command,
          taskId: task.id,
          userExplicitlyRequested:
              _requestsExplicitValidation(task.userRequest),
        );
        final writableResult = await _commandWritableCapabilityGate(
          task,
          command,
          policy,
        );
        if (writableResult != null) return writableResult;
        if (!policy.allowed) {
          if (policy.requiresExplicitRequest) {
            if (policy.changePlan != null) {
              task.executionStateJson = _withApprovalPlan(
                task.executionStateJson,
                policy.changePlan!,
              );
            }
            task.executionStateJson = _withExplicitCommandRequest(
              task.executionStateJson,
            );
            return WorkToolResult.paused(
              message: policy.reason,
              data: {
                'impact': policy.impact.wireName,
                'requiresApproval': policy.requiresApproval,
                'requiresSeparateConfirmation':
                    policy.requiresSeparateConfirmation,
                'requiresExplicitRequest': policy.requiresExplicitRequest,
              },
            );
          }
          final data = <String, dynamic>{
            'impact': policy.impact.wireName,
            'rejectionKind': policy.rejectionKind.name,
            'commandDisplay': _safeCommandDisplay(command),
          };
          return policy.rejectionKind == WorkCommandRejectionKind.pathRejected
              ? WorkToolResult.pathRejected(
                  message: policy.reason,
                  data: data,
                )
              : WorkToolResult.failed(
                  message: policy.reason,
                  data: data,
                  failureCode: 'modelProtocol',
                );
        }
        // Read-only commands share the mutation-shaped registry entry so the
        // command name cannot bypass the closed schema, but they must not be
        // forced through a file-change approval plan.
        if (policy.isReadOnly) return null;
        final plan = policy.changePlan;
        return plan == null
            ? const WorkToolResult.failed(
                message: '命令影响范围无法形成审批计划，未执行。',
                failureCode: 'commandPlanMissing',
              )
            : _mutationApprovalGate(task, invocation, plan);
      },
      approval: null,
      snapshot: (invocation) async {
        final command = _commandFromCall(invocation.call, workspaceRoot);
        if (command == null) return null;
        final evaluation = _commandPolicyFor(character, workspaceRoot).evaluate(
          command,
          taskId: task.id,
          userExplicitlyRequested:
              _requestsExplicitValidation(task.userRequest),
        );
        final plan = evaluation.changePlan;
        if (evaluation.isReadOnly || plan == null) return null;
        if (_approvalDecision(task.executionStateJson)?.permitsWithoutUndo ==
            true) {
          return null;
        }
        task.executionStateJson = _withApprovalPlan(
          task.executionStateJson,
          plan,
        );
        return const WorkToolResult.waitingForApproval(
          message: '命令无法创建可撤销快照，请明确选择“无撤销执行”后继续。',
          data: {'noUndoRequired': true},
        );
      },
      // The handler acquires this exact impact set for the process lifetime;
      // the named gate still rejects a mutation plan that cannot identify any
      // directory, preventing an unscoped command from reaching the handler.
      lock: (invocation) {
        final command = _commandFromCall(invocation.call, workspaceRoot);
        if (command == null) return null;
        final evaluation = _commandPolicyFor(character, workspaceRoot).evaluate(
          command,
          taskId: task.id,
          userExplicitlyRequested:
              _requestsExplicitValidation(task.userRequest),
        );
        final plan = evaluation.changePlan;
        if (evaluation.isReadOnly || plan == null) return null;
        if (plan.knownAffectedDirectories.isEmpty) {
          return const WorkToolResult.failed(
            message: '命令缺少可锁定的影响目录，未执行。',
            failureCode: 'commandLockScopeMissing',
          );
        }
        if (resourceLockManager == null) {
          return const WorkToolResult.failed(
            message: '命令变更缺少资源锁管理器，未执行。',
            failureCode: 'commandLockUnavailable',
          );
        }
        return null;
      },
    );
  }

  WorkToolMutationPipeline _skillMutationPipeline({
    required AgentTask task,
    required String label,
  }) {
    Future<WorkToolResult?> gate(WorkToolInvocation invocation) async {
      final decision = _approvalDecision(task.executionStateJson);
      if (decision == WorkChangeApprovalDecision.rejected) {
        task.executionStateJson = _withoutApprovalCheckpoint(
          task.executionStateJson,
        );
        return WorkToolResult.success(
          message: '用户拒绝了$label，未更新应用内技能。',
          data: const {'rejected': true},
        );
      }
      final fingerprint = WorkApprovalFingerprint.mutation(
        call: invocation.call,
      );
      if (_approvalAllowsMutation(
        task,
        invocation,
        fingerprint: fingerprint,
        // Skill changes have no filesystem plan, so the capability fingerprint
        // is their exact scope.
        scopeAllows: true,
        requiresFresh: true,
      )) {
        return null;
      }
      task.executionStateJson = _withApprovalMetadata(
        task.executionStateJson,
        capability: WorkApprovalCapability.mutation,
        fingerprint: fingerprint,
      );
      return WorkToolResult.waitingForApproval(
        message: '$label会修改应用内技能配置，请确认后继续。',
      );
    }

    return WorkToolMutationPipeline(
      policy: gate,
      approval: null,
      // Skill metadata lives in Hive rather than the workspace snapshot store.
      // Ordinary approval is therefore not enough: require the same explicit
      // no-undo decision used for an unsnapshotable file/command mutation.
      snapshot: (_) {
        final decision = _approvalDecision(task.executionStateJson);
        if (decision?.permitsWithoutUndo == true) return null;
        return const WorkToolResult.waitingForApproval(
          message: '应用内技能配置没有文件快照，必须明确选择“无撤销执行”后继续。',
          data: {'noUndoRequired': true},
        );
      },
      // The actual Hive mutation is wrapped by [_serializeSkillMutation]. The
      // named gate remains present so registry inspection cannot mistake this
      // tool for a mutation without a lock boundary.
      lock: (_) => null,
    );
  }

  Future<WorkToolResult?> _mutationApprovalGate(
    AgentTask task,
    WorkToolInvocation invocation,
    WorkChangePlan plan,
  ) async {
    final settings = WorkChangePolicySettings(
      confirmOrdinaryWrites:
          folderGrantService?.settings.confirmOrdinaryWrites ?? true,
    );
    final decision = _approvalDecision(task.executionStateJson);
    final scope = _approvalScope(task.executionStateJson);
    if (decision == WorkChangeApprovalDecision.rejected) {
      task.executionStateJson = _withoutApprovalCheckpoint(
        task.executionStateJson,
      );
      return const WorkToolResult.success(
        message: '用户拒绝了该变更，未执行。',
        data: {'rejected': true},
      );
    }
    final fingerprint = WorkApprovalFingerprint.mutation(
      call: invocation.call,
      plan: plan,
    );
    final policy = WorkChangePolicy.evaluate(
      plan: plan,
      settings: settings,
      scope: scope,
    );
    if (_approvalAllowsMutation(
      task,
      invocation,
      fingerprint: fingerprint,
      scopeAllows: scope?.allows(plan) == true,
      requiresFresh: _requiresFreshApproval(plan),
    )) {
      return null;
    }
    final sensitiveMutation = plan.exactPaths.any(
      (path) => workspaceFileService?.isSensitivePath(path) == true,
    );
    if (sensitiveMutation) {
      // Sensitive files are always per-operation approvals.  This branch is
      // intentionally before the ordinary-write setting so disabling routine
      // prompts can never turn a credential/config mutation into a silent
      // write.
      task.executionStateJson = _withApprovalPlan(
        task.executionStateJson,
        plan,
        call: invocation.call,
      );
      return WorkToolResult.waitingForApproval(
        message: '修改、重命名或删除敏感文件必须再次确认。影响范围：${_displayPlan(plan)}',
        data: {
          'approvalPlan': plan.toJson(),
          'sensitive': true,
        },
      );
    }
    if (!policy.requiresPrompt) return null;
    task.executionStateJson = _withApprovalPlan(
      task.executionStateJson,
      plan,
      call: invocation.call,
    );
    return WorkToolResult.waitingForApproval(
      message: '${policy.reason} 影响范围：${_displayPlan(plan)}',
      data: {'approvalPlan': plan.toJson()},
    );
  }

  bool _approvalAllowsMutation(
    AgentTask task,
    WorkToolInvocation invocation, {
    required String fingerprint,
    required bool scopeAllows,
    required bool requiresFresh,
  }) {
    final checkpoint = _decodeMap(task.executionStateJson);
    final decision = WorkChangeApprovalDecision.fromWire(
      checkpoint['approvalDecision'],
    );
    if (decision?.permitsExecution != true || !scopeAllows) return false;
    if (checkpoint['approvalCapability'] != WorkApprovalCapability.mutation ||
        checkpoint['approvalOperationFingerprint'] != fingerprint) {
      return false;
    }
    if (!requiresFresh) return true;
    final retryAttempt = invocation.context.state['toolRetryAttempt'];
    final isRetry = retryAttempt is int && retryAttempt > 0;
    final consumed = checkpoint['approvalConsumed'] == true;
    if (consumed && !isRetry) return false;
    if (!isRetry) {
      checkpoint['approvalConsumed'] = true;
      task.executionStateJson = jsonEncode(checkpoint);
    }
    return true;
  }

  bool _requiresFreshApproval(WorkChangePlan plan) {
    if (plan.actionType == WorkChangeActionType.delete ||
        plan.actionType == WorkChangeActionType.command) {
      return true;
    }
    return !plan.snapshotAvailable || !plan.reversible;
  }

  Future<WorkChangePlan?> _planForFileInvocation(
    AgentTask task,
    AgentToolCall call,
    Stage02WorkspaceFileTool stage02,
    WorkspaceMutationService mutations,
  ) async {
    final rawPath = call.arguments['path'];
    if (rawPath is! String || rawPath.trim().isEmpty) return null;
    try {
      final targetPath = await _mutationPath(
        task,
        stage02,
        rawPath,
        allowAutoRename: call.name == AgentToolName.workspacePatch &&
            !_isExactPatch(call.arguments),
      );
      final target = await stage02.pathPolicy.resolve(
        targetPath,
        allowMissing: call.name != AgentToolName.workspaceDelete,
      );
      if (target.exists && !target.isFile) return null;
      final action = switch (call.name) {
        AgentToolName.workspaceDelete => WorkChangeActionType.delete,
        AgentToolName.workspaceRename => WorkChangeActionType.rename,
        AgentToolName.workspacePatch => _isExactPatch(call.arguments)
            ? WorkChangeActionType.patch
            : target.exists
                ? WorkChangeActionType.modify
                : WorkChangeActionType.create,
        _ => null,
      };
      if (action == null) return null;
      final exactPaths = <String>[target.path];
      final directories = <String>{target.authorizedRoot};
      if (action == WorkChangeActionType.rename) {
        final destinationRaw = call.arguments['destinationPath'];
        if (destinationRaw is! String || destinationRaw.trim().isEmpty) {
          return null;
        }
        final destination = await stage02.pathPolicy.resolve(
          _effectivePath(
            task,
            stage02.workspaceRoot,
            destinationRaw,
            enforceRevision: false,
          ),
          allowMissing: true,
        );
        if (destination.exists && !destination.isFile) return null;
        exactPaths.add(destination.path);
        directories.add(destination.authorizedRoot);
      }
      final content = call.arguments['content'];
      final replacement = call.arguments['replacement'];
      var plan = WorkChangePlan(
        taskId: task.id,
        actionType: action,
        exactPaths: exactPaths,
        knownAffectedDirectories: directories.toList(growable: false),
        estimatedBytes: replacement is String
            ? utf8.encode(replacement).length
            : content is String
                ? utf8.encode(content).length
                : 0,
        snapshotAvailable: mutations.snapshotPort != null,
        reversible: mutations.snapshotPort != null,
        riskReason: switch (action) {
          WorkChangeActionType.create => '工作模式需要在授权目录内创建文件。',
          WorkChangeActionType.modify => '工作模式需要在授权目录内原子替换文件。',
          WorkChangeActionType.patch => '工作模式需要在授权目录内应用精确补丁。',
          WorkChangeActionType.rename => '工作模式需要在授权目录内重命名文件。',
          WorkChangeActionType.delete => '工作模式需要删除授权目录内的普通文件。',
          _ => '工作模式需要修改授权目录内的文件。',
        },
      );
      final port = mutations.snapshotPort;
      if (port case final WorkspaceMutationSnapshotAvailabilityPort checker) {
        final available = await checker.canReserve(
          plan: plan,
          paths: plan.exactPaths,
        );
        if (!available) {
          plan = WorkChangePlan(
            taskId: plan.taskId,
            actionType: plan.actionType,
            exactPaths: plan.exactPaths,
            knownAffectedDirectories: plan.knownAffectedDirectories,
            estimatedBytes: plan.estimatedBytes,
            snapshotAvailable: false,
            reversible: false,
            riskReason: plan.riskReason,
          );
        }
      }
      return plan;
    } on Object {
      return null;
    }
  }

  WorkCommand? _commandFromCall(AgentToolCall call, String workspaceRoot) {
    try {
      final raw = Map<String, dynamic>.from(call.arguments);
      final cwd = raw['workingDirectory'];
      if (cwd is String && !_isAbsolutePath(cwd)) {
        raw['workingDirectory'] = _effectivePath(null, workspaceRoot, cwd);
      }
      final arguments = raw['arguments'] ?? raw['args'];
      if (arguments is! List || arguments.any((item) => item is! String)) {
        return null;
      }
      raw['arguments'] = arguments.cast<String>();
      final impact = raw['declaredImpact'];
      if (impact is! List || impact.any((item) => item is! String)) {
        return null;
      }
      raw['declaredImpact'] = impact.cast<String>();
      return WorkCommand.fromJson(raw);
    } on Object {
      return null;
    }
  }

  Future<String> _mutationPath(
    AgentTask task,
    Stage02WorkspaceFileTool stage02,
    Object? rawPath, {
    bool allowAutoRename = false,
  }) async {
    final candidate = _effectivePath(task, stage02.workspaceRoot, rawPath);
    if (!allowAutoRename ||
        _revisionTarget(task) != null ||
        _decodeMap(task.executionStateJson)['autoRenameIfExists'] != true) {
      return candidate;
    }
    final metadata = _decodeMap(task.executionStateJson);
    final persisted = metadata['resolvedMutationPath'];
    if (persisted is String && persisted.trim().isNotEmpty) {
      // Persist the collision decision before the approval pause so every
      // gate and the eventual handler use one exact path, including after a
      // restart. The path policy revalidates its authorization boundary.
      final resolved = await stage02.pathPolicy.resolve(
        persisted.trim(),
        allowMissing: true,
      );
      if (resolved.exists) {
        throw StateError('自动重命名目标在审批期间已被占用，未覆盖现有文件。');
      }
      return resolved.path;
    }
    final resolved =
        await stage02.pathPolicy.resolve(candidate, allowMissing: true);
    if (!resolved.exists) return candidate;
    final allocated = await _nextAvailablePath(stage02, candidate);
    metadata['resolvedMutationPath'] = allocated;
    task.executionStateJson = jsonEncode(metadata);
    return allocated;
  }

  Future<String> _nextAvailablePath(
    Stage02WorkspaceFileTool stage02,
    String original,
  ) async {
    final normalized = original.replaceAll('\\', '/');
    final slash = normalized.lastIndexOf('/');
    final directory = slash < 0 ? '' : normalized.substring(0, slash);
    final name = slash < 0 ? normalized : normalized.substring(slash + 1);
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final extension = dot > 0 ? name.substring(dot) : '';
    for (var index = 1; index <= 1000; index++) {
      final candidate = '$directory/$stem ($index)$extension';
      final resolved = await stage02.pathPolicy.resolve(
        candidate,
        allowMissing: true,
      );
      if (!resolved.exists) return resolved.path;
    }
    throw StateError('无法为重名文件分配安全的新路径。');
  }

  WorkCommandPolicy _commandPolicyFor(
    AICharacter character,
    String workspaceRoot,
  ) {
    final roots = folderGrantService?.grants
            .where(
              (grant) =>
                  grant.available && grant.cloudDisclosureConfirmedAt != null,
            )
            .map((grant) => grant.path)
            .toList(growable: false) ??
        <String>[workspaceRoot];
    return WorkCommandPolicy(
      authorizedRoots: roots.isEmpty ? [workspaceRoot] : roots,
    );
  }

  /// A read grant authorizes inspection, but it must never become an implicit
  /// write capability merely because a command was classified after planning.
  /// Re-check the concrete command immediately before approval/handler gates so
  /// a grant revoked while a task was paused cannot be used for local writes.
  Future<WorkToolResult?> _commandWritableCapabilityGate(
    AgentTask task,
    WorkCommand command,
    WorkCommandPolicyResult evaluation,
  ) async {
    final grants = folderGrantService;
    if (grants == null || !evaluation.allowed || evaluation.isReadOnly) {
      return null;
    }

    // External-only commands (for example a confirmed HTTP POST) do not need
    // a writable workspace. A declared absolute impact path still does, as it
    // explicitly claims a local side effect in addition to the external one.
    final requiresWritable =
        evaluation.impact != WorkCommandImpact.externalMutation ||
            command.declaredImpact.any(_isAbsolutePath);
    if (!requiresWritable) return null;

    final paths = <String>[command.workingDirectory];
    paths.addAll(command.declaredImpact.where(_isAbsolutePath));
    for (final path in paths) {
      if (await grants.isPathWritableResolved(path)) continue;
      task.executionStateJson =
          _withFolderRequest(task.executionStateJson, path);
      return WorkToolResult.waitingForApproval(
        message: '命令可能修改本地状态，需要重新授权可写工作目录后才能继续。',
        data: {
          'folderRequestPath': path,
          'requiresWritable': true,
        },
        failureCode: 'authorizationRequired',
      );
    }
    return null;
  }

  Set<ToolPermission> _permissionsForTask(
    AgentTask task,
    AICharacter character,
  ) {
    final characterPermissions = character.toolPermissions.toSet();
    final taskPermissions = task.requestedPermissions.toSet();
    // requestedPermissions is a task-level request/checkpoint field, not an
    // authority grant. Always intersect it with the active role's persisted
    // capabilities so a stale or tampered task cannot grant commandRun (or
    // any other tool) that the current character does not have.
    return taskPermissions.isEmpty
        ? characterPermissions
        : characterPermissions.intersection(taskPermissions);
  }

  bool _pendingRequiresWritableWorkspace(
    AgentTask task,
    ToolRequest? pending,
  ) {
    final execution = _decodeMap(task.executionStateJson);
    if (execution['folderRequiresWritable'] == true) return true;
    if (pending == null) return false;
    return switch (pending.tool) {
      AgentToolName.workspacePatch ||
      AgentToolName.workspaceRename ||
      AgentToolName.workspaceDelete =>
        true,
      // command.run is normally classified by WorkCommandPolicy. If a folder
      // grant was just repaired, the marker may already have been cleared, so
      // conservatively recognize the small read-only command set here to keep
      // local mutations on a writable workspace.
      AgentToolName.commandRun => _pendingCommandNeedsWritable(pending.args),
      _ => false,
    };
  }

  bool _hasWritableWorkspaceMarker(AgentTask task) {
    return _decodeMap(task.executionStateJson)['folderRequiresWritable'] ==
        true;
  }

  void _consumeWritableWorkspaceMarker(AgentTask task) {
    final execution = _decodeMap(task.executionStateJson)
      ..remove('folderRequiresWritable');
    task.executionStateJson = execution.isEmpty ? '' : jsonEncode(execution);
  }

  bool _pendingCommandNeedsWritable(Map<String, dynamic> args) {
    final executable = (args['executable'] ?? '').toString().toLowerCase();
    final base = executable.replaceAll('\\', '/').split('/').last;
    final rawArguments = args['arguments'] ?? args['args'];
    final rawArgumentList = rawArguments is List
        ? rawArguments.map((item) => item.toString()).toList()
        : const <String>[];
    final arguments = rawArgumentList
        .map((item) => item.toLowerCase())
        .toList(growable: false);
    final rawImpact = args['declaredImpact'];
    final impactPaths =
        rawImpact is List ? rawImpact.whereType<String>() : const <String>[];
    if (impactPaths.any(_isAbsolutePath) ||
        arguments.any(_isLocalRedirectArgument)) {
      return true;
    }
    if (const {
      'pwd',
      'ls',
      'dir',
      'rg',
      'ripgrep',
      'grep',
      'egrep',
      'fgrep',
      'cat',
      'head',
      'tail',
      'wc',
      'file',
      'stat',
      'which',
      'where',
      'whoami',
      'uname',
    }.contains(base)) {
      return false;
    }
    if (base == 'find' || base == 'fd') {
      return arguments.any(
        (argument) => {'-delete', '-exec', '-execdir', '-ok', '-okdir'}
            .contains(argument),
      );
    }
    if (base == 'git' && arguments.isNotEmpty) {
      return !const {
        'status',
        'diff',
        'log',
        'show',
        'branch',
        'rev-parse',
        'ls-files',
      }.contains(arguments.first);
    }
    if (base == 'flutter' || base == 'dart') {
      final first = arguments.isEmpty ? '' : arguments.first;
      return first != 'analyze' && first != '--version' && first != '--help';
    }
    if (base == 'curl' || base == 'wget') {
      return rawArgumentList.any(
        (raw) {
          final argument = raw.toLowerCase();
          final curlShortOutput = base == 'curl' &&
              (raw == '-D' ||
                  raw.startsWith('-D') && raw.length > 2 ||
                  raw == '-c' ||
                  raw.startsWith('-c') && raw.length > 2);
          return curlShortOutput ||
              argument == '-o' ||
              argument == '--output' ||
              argument.startsWith('--output=') ||
              argument == '--output-dir' ||
              argument.startsWith('--output-dir=') ||
              argument == '--output-document' ||
              argument.startsWith('--output-document=') ||
              argument == '--dump-header' ||
              argument.startsWith('--dump-header=') ||
              argument == '--cookie-jar' ||
              argument.startsWith('--cookie-jar=') ||
              argument == '--trace' ||
              argument.startsWith('--trace=') ||
              argument == '--trace-ascii' ||
              argument.startsWith('--trace-ascii=') ||
              argument == '--stderr' ||
              argument.startsWith('--stderr=') ||
              argument == '--hsts' ||
              argument.startsWith('--hsts=') ||
              argument == '--etag-save' ||
              argument.startsWith('--etag-save=') ||
              argument.startsWith('-o') && argument.length > 2;
        },
      );
    }
    return true;
  }

  bool _isLocalRedirectArgument(String argument) {
    return argument == '>' ||
        argument == '>>' ||
        argument == '<' ||
        argument == '2>' ||
        argument.startsWith('>') ||
        argument.startsWith('<') ||
        argument.startsWith('2>');
  }

  Future<WorkToolResult> _runCommand(
    AgentTask task,
    WorkToolInvocation invocation,
    AICharacter character,
    String workspaceRoot,
  ) async {
    final permissions = _permissionsForTask(task, character);
    if (!permissions.contains(ToolPermission.commandRun)) {
      return const WorkToolResult.permissionDenied(
        message: '角色未授予 commandRun 工具权限。',
      );
    }
    final command = _commandFromCall(invocation.call, workspaceRoot);
    if (command == null) {
      return const WorkToolResult.failed(
        message: '命令必须使用结构化参数，未执行。',
        failureCode: 'invalidCommand',
      );
    }
    final commandPolicy = _commandPolicyFor(character, workspaceRoot);
    final policy = commandPolicy.evaluate(
      command,
      taskId: task.id,
      userExplicitlyRequested: _requestsExplicitValidation(task.userRequest),
    );
    final plan = policy.changePlan;
    final checkpoint = _decodeMap(task.executionStateJson);
    final approvalGranted = plan != null &&
        !policy.isReadOnly &&
        _approvalDecision(task.executionStateJson)?.permitsExecution == true &&
        checkpoint['approvalCapability'] == WorkApprovalCapability.mutation &&
        checkpoint['approvalOperationFingerprint'] ==
            WorkApprovalFingerprint.mutation(call: invocation.call, plan: plan);
    final runner = commandRunner ??
        WorkCommandRunner(
          policy: commandPolicy,
          pathPolicy: workspaceFileService?.pathPolicy,
          onOutput: (chunk) => _record(
            task,
            WorkTaskEventKind.toolOutput,
            '命令输出',
            detail: chunk.text,
            safeMetadata: {'stream': chunk.stream.name},
          ),
        );
    Future<WorkCommandResult> run() => runner.run(
          command,
          taskId: task.id,
          approvalGranted: approvalGranted,
          userExplicitlyRequested:
              _requestsExplicitValidation(task.userRequest),
          cancellation: invocation.context.cancellation?.whenCancelled,
          isCancelled: () => invocation.context.isCancelled,
        );
    final lockManager = resourceLockManager;
    if (plan != null && !policy.isReadOnly && lockManager == null) {
      return const WorkToolResult.failed(
        message: '命令变更缺少资源锁管理器，未执行。',
        failureCode: 'commandLockUnavailable',
      );
    }
    final result = plan == null || policy.isReadOnly
        ? await run()
        : await lockManager!.withLocks(
            task.id,
            <WorkResourceLockRequest>{
              ...plan.knownAffectedDirectories
                  .map(WorkResourceLockRequest.treeWrite),
              ...plan.exactPaths.map(WorkResourceLockRequest.treeWrite),
            },
            run,
            cancellation: invocation.context.cancellation?.whenCancelled,
            isCancelled: () => invocation.context.isCancelled,
          );
    final artifactPaths = await _existingCommandArtifactPaths(command);
    final data = <String, dynamic>{
      'commandDisplay': _safeCommandDisplay(command),
      if (result.exitCode != null) 'exitCode': result.exitCode,
      'elapsedMs': result.elapsed.inMilliseconds,
      'outputTruncated': result.outputTruncated,
      if (artifactPaths.isNotEmpty) 'artifactPaths': artifactPaths,
      if (result.stdout.isNotEmpty) 'stdout': result.stdout,
      if (result.stderr.isNotEmpty) 'stderr': result.stderr,
      if (result.installSuggestion != null)
        'installSuggestion': result.installSuggestion!.toJson(),
    };
    if (!result.succeeded) {
      final failureTargetPath =
          _commandFailureTargetPath(command, artifactPaths);
      if (failureTargetPath != null) {
        data['failureTargetPath'] = failureTargetPath;
      }
    }
    if (result.succeeded) {
      return WorkToolResult.success(message: result.message, data: data);
    }
    if (result.status == WorkCommandRunStatus.waitingForApproval) {
      return WorkToolResult.waitingForApproval(
        message: result.message,
        data: data,
      );
    }
    if (result.status == WorkCommandRunStatus.pausedForUser ||
        result.status == WorkCommandRunStatus.toolMissing) {
      return WorkToolResult.paused(
        message: result.message,
        data: data,
        failureCode: result.status == WorkCommandRunStatus.toolMissing
            ? 'toolMissing'
            : 'userActionRequired',
      );
    }
    if (result.status == WorkCommandRunStatus.blockedByDefault) {
      return WorkToolResult.failed(
        message: result.message,
        data: data,
        failureCode: 'commandFailed',
      );
    }
    if (result.status == WorkCommandRunStatus.pathRejected) {
      return WorkToolResult.pathRejected(message: result.message, data: data);
    }
    final failureCode = switch (result.status) {
      WorkCommandRunStatus.timedOut => 'commandFailed',
      WorkCommandRunStatus.outputLimitExceeded => 'commandFailed',
      WorkCommandRunStatus.failed => !policy.allowed &&
              policy.rejectionKind == WorkCommandRejectionKind.invalidInput
          ? 'modelProtocol'
          : 'commandFailed',
      WorkCommandRunStatus.cancelled => 'userActionRequired',
      _ => 'commandFailed',
    };
    return WorkToolResult.failed(
      message: result.message,
      data: data,
      failureCode: failureCode,
    );
  }

  Future<List<String>> _existingCommandArtifactPaths(
    WorkCommand command,
  ) async {
    final files = workspaceFileService;
    if (files == null) return const <String>[];
    final paths = <String>{};
    for (final rawPath in command.declaredImpact.take(64)) {
      try {
        final candidate = _effectivePath(
          null,
          command.workingDirectory,
          rawPath,
          enforceRevision: false,
        );
        final resolved = await files.pathPolicy.resolveExisting(candidate);
        // The path policy may mark harmless parent aliases such as macOS
        // /var -> /private/var as symbolic. Reject only a linked final
        // component; the policy has already authorized the resolved path.
        final requestedType = await FileSystemEntity.type(
          candidate,
          followLinks: false,
        );
        if (resolved.isFile && requestedType != FileSystemEntityType.link) {
          paths.add(resolved.path);
        }
      } on Object {
        // declaredImpact is an authorization hint, not proof that a file was
        // produced. Only existing, policy-resolved files become artifacts.
      }
    }
    return paths.toList(growable: false);
  }

  String? _commandFailureTargetPath(
    WorkCommand command,
    Iterable<String> existingArtifactPaths,
  ) {
    final sourcePaths = existingArtifactPaths
        .where(_looksLikeSourceArtifact)
        .toList(growable: false);
    final display = command.displayCommand.toLowerCase();
    final fullPathMatches = sourcePaths
        .where((path) =>
            display.contains(path.replaceAll('\\', '/').toLowerCase()))
        .toList(growable: false);
    if (fullPathMatches.length == 1) return fullPathMatches.single;
    final basenameMatches = sourcePaths.where((path) {
      final basename = path.replaceAll('\\', '/').split('/').last.toLowerCase();
      return basename.isNotEmpty && display.contains(basename);
    }).toList(growable: false);
    if (basenameMatches.length == 1) {
      return basenameMatches.single;
    }
    if (sourcePaths.length == 1) return sourcePaths.single;

    // A script can be the failing input without being listed in
    // declaredImpact. The command policy has already validated argument paths;
    // retain only a source-looking argument and never persist inline code or
    // an option as a repair target.
    final argumentMatches = <String>[];
    for (final argument in command.arguments) {
      final candidate = argument.trim();
      if (candidate.isEmpty || candidate.startsWith('-')) continue;
      if (_looksLikeSourceArtifact(candidate)) argumentMatches.add(candidate);
    }
    return argumentMatches.length == 1 ? argumentMatches.single : null;
  }

  bool _looksLikeSourceArtifact(String path) => RegExp(
        r'\.(?:py|pyw|js|mjs|cjs|ts|tsx|jsx|dart|sh|bash|rb|go|rs|java|kt|swift|c|cc|cpp|h|hpp)$',
        caseSensitive: false,
      ).hasMatch(path.replaceAll('\\', '/'));

  @override
  Future<WorkCommandResult> installMissingTool(
    AgentTask task,
    WorkTaskCancellation cancellation,
  ) async {
    final pending = _pendingRequests[task.id] ??
        ToolRequest.fromJsonString(task.pendingToolRequestJson);
    if (pending == null || pending.tool != AgentToolName.commandRun) {
      throw StateError('当前任务没有可安装的缺失命令。');
    }
    final character = database.aiCharacterBox.get(task.characterId);
    if (character == null) throw StateError('执行角色不可用。');
    if (!_permissionsForTask(task, character)
        .contains(ToolPermission.commandRun)) {
      throw StateError('角色未授予 commandRun 工具权限。');
    }
    final workspace = await workspaceService.loadOrCreate(
      conversationId: task.groupId,
      isDirectChat: task.groupId.startsWith('dm:'),
    );
    final original = _commandFromCall(
      AgentToolCall(name: AgentToolName.commandRun, arguments: pending.args),
      workspace.workDirPath,
    );
    if (original == null) throw StateError('缺失命令检查点格式无效。');
    final policy = _commandPolicyFor(character, workspace.workDirPath);
    final runner = commandRunner ??
        WorkCommandRunner(
          policy: policy,
          pathPolicy: workspaceFileService?.pathPolicy,
          onOutput: (chunk) => _record(
            task,
            WorkTaskEventKind.toolOutput,
            '安装命令输出',
            detail: chunk.text,
            safeMetadata: {'stream': chunk.stream.name, 'install': true},
          ),
        );
    // Use the runner's policy when a caller injects one. This keeps the
    // installer branch deterministic in tests and makes the suggested
    // package manager match the policy that will actually execute it.
    final installerPolicy = commandRunner?.policy ?? policy;
    final suggestion = WorkCommandInstallSuggestion.forExecutable(
      original.executable,
      isWindows: installerPolicy.isWindows,
      isMacOS: installerPolicy.isMacOS,
      workingDirectory: original.workingDirectory,
      declaredImpact: original.declaredImpact,
    );
    final install = suggestion.installCommand;
    if (install == null) {
      throw StateError('该工具没有可安全自动安装的受信命令。');
    }
    // Clicking the panel action is the explicit user confirmation for this
    // one-shot package-manager command; it never changes the task's ordinary
    // write-confirmation setting or grants a permanent system capability.
    final result = await runner.run(
      install,
      taskId: '${task.id}:install',
      approvalGranted: true,
      userExplicitlyRequested: true,
      includeUserHome: true,
      cancellation: cancellation.whenCancelled,
      isCancelled: () => cancellation.isCancelled,
    );
    if (result.succeeded &&
        task.pendingToolRequestJson == safeToolRequestCheckpoint(pending) &&
        _isReplayableInstalledCommand(original)) {
      // The checkpoint contains only structured command fields. Promote it
      // after the trusted installer succeeds so the coordinator can resume
      // the exact operation; _runCommand still performs the current policy,
      // path and approval checks before spawning anything.
      _pendingRequests[task.id] = pending;
    }
    return result;
  }

  bool _isReplayableInstalledCommand(WorkCommand command) {
    if (_containsCheckpointRedaction(command.executable) ||
        _containsCheckpointRedaction(command.workingDirectory)) {
      return false;
    }
    return command.arguments.every(
          (argument) => !_containsCheckpointRedaction(argument),
        ) &&
        command.declaredImpact.every(
          (path) => !_containsCheckpointRedaction(path),
        );
  }

  bool _containsCheckpointRedaction(String value) =>
      value.contains(SearchSecretScanner.redaction);

  WorkToolResult _mapFileResult(Map<String, dynamic> result) =>
      _mapFileResultToTool(result);

  WorkToolResult _mapSkillResult(Map<String, dynamic> result) {
    final ok = result['ok'] == true;
    return ok
        ? WorkToolResult.success(
            message: result['message']?.toString() ?? '技能已更新。',
            data: result,
          )
        : WorkToolResult.failed(
            message: result['message']?.toString() ?? '技能操作失败。',
            data: result,
            failureCode: result['error']?.toString() ?? 'skillFailed',
          );
  }

  WorkToolResult _mapFileResultToTool(Map<String, dynamic> result) {
    final message = result['message']?.toString() ??
        (result['error']?.toString() ?? '文件操作已完成。');
    if (result['requiresFolderGrant'] == true) {
      return WorkToolResult.paused(
        message: message,
        data: result,
        failureCode: 'authorizationLost',
      );
    }
    if (result['requiresApproval'] == true) {
      final error = result['error']?.toString().toLowerCase() ?? '';
      return WorkToolResult.waitingForApproval(
        message: message,
        data: result,
        failureCode: error.contains('snapshot')
            ? 'snapshotUnavailable'
            : 'userActionRequired',
      );
    }
    if (result['ok'] == true) {
      return WorkToolResult.success(message: message, data: result);
    }
    final error = result['error']?.toString() ?? '';
    final lowerError = error.toLowerCase();
    final lowerMessage = message.toLowerCase();
    final mutationCommitted = result['mutationCommitted'] == true;
    if (lowerError.contains('snapshot') ||
        lowerError.contains('snapshotunavailable') ||
        lowerMessage.contains('快照') ||
        lowerMessage.contains('撤销记录')) {
      return WorkToolResult.failed(
        message: message,
        data: result,
        failureCode: 'snapshotUnavailable',
        committed: mutationCommitted,
      );
    }
    if (lowerError.contains('conflict') ||
        lowerError.contains('postcondition')) {
      return WorkToolResult.failed(
        message: message,
        data: result,
        failureCode: 'fileConflict',
        committed: mutationCommitted,
      );
    }
    if (lowerError.contains('path') || lowerError.contains('notauthorized')) {
      return WorkToolResult.pathRejected(message: message, data: result);
    }
    return WorkToolResult.failed(
      message: message,
      data: result,
      failureCode: error.isEmpty ? 'fileFailed' : error,
      committed: mutationCommitted,
    );
  }

  String _withApprovalPlan(
    String raw,
    WorkChangePlan plan, {
    AgentToolCall? call,
  }) {
    final current = _decodeMap(raw)
      ..remove('approvalDecision')
      ..['approvalPlan'] = plan.toJson()
      ..['approvalScope'] = WorkApprovalScope.fromPlan(plan).toJson();
    if (call != null) {
      current['approvalCapability'] = WorkApprovalCapability.mutation;
      current['approvalOperationFingerprint'] =
          WorkApprovalFingerprint.mutation(call: call, plan: plan);
      current.remove('approvalConsumed');
    } else {
      current
        ..remove('approvalCapability')
        ..remove('approvalOperationFingerprint')
        ..remove('approvalConsumed');
    }
    return jsonEncode(current);
  }

  String _withApprovalMetadata(
    String raw, {
    required String capability,
    required String fingerprint,
  }) {
    final current = _decodeMap(raw)
      ..remove('approvalDecision')
      ..remove('approvalPlan')
      ..remove('approvalScope')
      ..['approvalCapability'] = capability
      ..['approvalOperationFingerprint'] = fingerprint
      ..remove('approvalConsumed');
    return jsonEncode(current);
  }

  String? _approvedSensitiveOperation(AgentTask task) {
    final checkpoint = _decodeMap(task.executionStateJson);
    if (checkpoint['approvalCapability'] !=
            WorkApprovalCapability.sensitiveRead ||
        _approvalDecision(task.executionStateJson)?.permitsExecution != true) {
      return null;
    }
    final value = checkpoint['approvalOperationFingerprint'];
    return value is String && value.trim().isNotEmpty ? value : null;
  }

  String? _approvalCapability(AgentTask task) {
    final value = _decodeMap(task.executionStateJson)['approvalCapability'];
    return value is String && value.trim().isNotEmpty ? value : null;
  }

  bool _sensitiveReadAllowed(
    AgentTask task,
    Stage02WorkspaceFileTool stage02, {
    required String operation,
    required String path,
    int startByte = 0,
    int? byteLength,
    String? query,
    bool recursive = false,
    bool caseSensitive = true,
  }) {
    final decision = _approvalDecision(task.executionStateJson);
    final checkpoint = _decodeMap(task.executionStateJson);
    if (decision?.permitsExecution != true ||
        checkpoint['approvalCapability'] !=
            WorkApprovalCapability.sensitiveRead) {
      return false;
    }
    final expected = stage02.sensitiveReadFingerprint(
      operation: operation,
      path: path,
      startByte: startByte,
      byteLength: byteLength,
      query: query,
      recursive: recursive,
      caseSensitive: caseSensitive,
    );
    return checkpoint['approvalOperationFingerprint'] == expected;
  }

  void _recordSensitiveReadApproval(
    AgentTask task,
    Stage02WorkspaceFileTool stage02,
    Map<String, dynamic> result, {
    required String operation,
    required String path,
    int startByte = 0,
    int? byteLength,
    String? query,
    bool recursive = false,
    bool caseSensitive = true,
  }) {
    if (result['requiresApproval'] != true || result['sensitive'] != true) {
      return;
    }
    task.executionStateJson = _withApprovalMetadata(
      task.executionStateJson,
      capability: WorkApprovalCapability.sensitiveRead,
      fingerprint: stage02.sensitiveReadFingerprint(
        operation: operation,
        path: path,
        startByte: startByte,
        byteLength: byteLength,
        query: query,
        recursive: recursive,
        caseSensitive: caseSensitive,
      ),
    );
  }

  String _withFolderRequest(String raw, String path) {
    final current = _decodeMap(raw)..['folderRequestPath'] = path.trim();
    return jsonEncode(current);
  }

  String _withExplicitCommandRequest(String raw) {
    final current = _decodeMap(raw)..['explicitCommandRequestRequired'] = true;
    return jsonEncode(current);
  }

  String _withoutApprovalCheckpoint(String raw) {
    final current = _decodeMap(raw)
      ..remove('approvalDecision')
      ..remove('approvalPlan')
      ..remove('approvalScope')
      ..remove('approvalCapability')
      ..remove('approvalOperationFingerprint')
      ..remove('approvalConsumed');
    return current.isEmpty ? '' : jsonEncode(current);
  }

  WorkChangeApprovalDecision? _approvalDecision(String raw) =>
      WorkChangeApprovalDecision.fromWire(_decodeMap(raw)['approvalDecision']);

  WorkApprovalScope? _approvalScope(String raw) {
    final value = _decodeMap(raw)['approvalScope'];
    if (value is! Map) return null;
    try {
      return WorkApprovalScope.fromJson(Map<String, dynamic>.from(value));
    } on Object {
      return null;
    }
  }

  Map<String, dynamic> _decodeMap(String raw) {
    if (raw.trim().isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : {};
    } on Object {
      return <String, dynamic>{};
    }
  }

  String _effectivePath(
    AgentTask? task,
    String workspaceRoot,
    Object? raw, {
    bool enforceRevision = true,
  }) {
    final value = raw?.toString().trim() ?? '';
    if (value.isEmpty) throw const FormatException('工作区路径不能为空');
    if (_containsParentTraversal(value)) {
      throw const FormatException('工作区路径不能包含 ..');
    }
    final revision = task == null ? null : _revisionTarget(task);
    // A revision target is a durable capability boundary. The model may use a
    // relative or absolute spelling, but it cannot redirect the mutation to a
    // different basename after the user queued “modify the same file”.
    if (enforceRevision && revision != null) {
      final absoluteRevision = _isAbsolutePath(revision)
          ? revision
          : '${workspaceRoot.replaceAll('\\', '/')}/$revision';
      final isWindows = workspaceFileService?.pathPolicy.isWindows ??
          RegExp(r'^[A-Za-z]:').hasMatch(absoluteRevision);
      return WorkspacePathPolicy.normalizePath(
        absoluteRevision,
        isWindows: isWindows,
      );
    }
    final absolute = _isAbsolutePath(value)
        ? value
        : '${workspaceRoot.replaceAll('\\', '/')}/$value';
    final isWindows = workspaceFileService?.pathPolicy.isWindows ??
        RegExp(r'^[A-Za-z]:').hasMatch(absolute);
    return WorkspacePathPolicy.normalizePath(absolute, isWindows: isWindows);
  }

  bool _requiresDocumentTool(String path) {
    final normalized = path.trim().replaceAll('\\', '/').toLowerCase();
    return RegExp(r'\.(?:pdf|docx|xlsx)$').hasMatch(normalized);
  }

  String? _revisionTarget(AgentTask task) {
    final value = _decodeMap(task.executionStateJson)['revisionTargetPath'];
    if (value is! String ||
        value.trim().isEmpty ||
        _containsParentTraversal(value)) {
      return null;
    }
    return value.replaceAll('\\', '/').trim();
  }

  bool _isExactPatch(Map<String, dynamic> args) =>
      args['expectedSha256'] is String &&
      args['expectedFragment'] is String &&
      args['replacement'] is String;

  bool _isAbsolutePath(String value) {
    final path = value.trim();
    return path.startsWith('/') ||
        path.startsWith('\\') ||
        RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);
  }

  bool _containsParentTraversal(String value) =>
      value.replaceAll('\\', '/').split('/').any((segment) => segment == '..');

  String _basename(String value) {
    final normalized = value.replaceAll('\\', '/');
    final index = normalized.lastIndexOf('/');
    return index < 0 ? normalized : normalized.substring(index + 1);
  }

  String _safeCommandDisplay(WorkCommand command) {
    var display = const SearchSecretScanner().redact(
      command.displayCommand,
      includeOpaqueTokens: true,
    );
    display = display
        .replaceAll(RegExp(r'[\u0000-\u001f\u007f]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    const maximum = 1200;
    return display.length <= maximum
        ? display
        : '${display.substring(0, maximum - 1)}…';
  }

  int _intArgument(Object? value, int fallback) =>
      value is int && value >= 0 ? value : fallback;

  int? _nullableInt(Object? value) => value is int && value >= 0 ? value : null;

  ApiConfig? _resolveApiConfig(AICharacter character) {
    if (character.apiConfigId.trim().isNotEmpty) {
      final configured = database.apiConfigBox.get(character.apiConfigId);
      if (configured != null) return configured;
    }
    for (final config in database.apiConfigBox.values) {
      if (config.provider == character.apiProvider &&
          config.modelName == character.modelName) {
        return config;
      }
    }
    return null;
  }

  ApiProvider _providerFor(ApiConfig config) => ApiProvider.values.firstWhere(
        (provider) => provider.name == config.provider,
        orElse: () => throw StateError('模型提供商配置无效：${config.provider}'),
      );

  Future<List<Map<String, dynamic>>> _conversationHistory(
    AgentTask task,
  ) async {
    final messages = database.messageBox.values
        .where((message) =>
            message.groupId == task.groupId &&
            !message.id.startsWith('agent-progress:'))
        .toList()
      ..sort((left, right) => left.timestamp.compareTo(right.timestamp));
    return AgentAttachmentContext.buildHistory(
      messages: messages.length <= 24
          ? messages
          : messages.sublist(messages.length - 24),
      currentUserRequest: task.userRequest,
    );
  }

  Future<String> _requestWithAttachmentContext(AgentTask task) async {
    final sourceId = _attachmentMessageId(task.executionStateJson);
    Message? source;
    if (sourceId != null) {
      final candidate = database.messageBox.get(sourceId);
      if (candidate != null &&
          candidate.groupId == task.groupId &&
          candidate.senderType == 'user' &&
          candidate.media?.isNotEmpty == true) {
        source = candidate;
      }
    }
    if (source == null) {
      final candidates = database.messageBox.values
          .where((message) =>
              message.groupId == task.groupId &&
              message.senderType == 'user' &&
              message.content.trim() == task.userRequest.trim())
          .toList()
        ..sort((left, right) => right.timestamp.compareTo(left.timestamp));
      source = candidates.isEmpty ? null : candidates.first;
    }
    if (source == null &&
        task.userRequest.trim() == WorkModePolicy.attachmentOnlyRequest) {
      // Attachment-only follow-ups use an internal label because the durable
      // queue cannot store an empty request. Resolve that label to the newest
      // user attachment without changing the original message content.
      final messages = database.messageBox.values
          .where((message) =>
              message.groupId == task.groupId &&
              message.senderType == 'user' &&
              message.media?.isNotEmpty == true)
          .toList()
        ..sort((left, right) => right.timestamp.compareTo(left.timestamp));
      source = messages.isEmpty ? null : messages.first;
    }
    return AgentAttachmentContext.enhanceCurrentRequest(
      userRequest: task.userRequest,
      media: source?.media,
    );
  }

  String? _attachmentMessageId(String rawExecutionState) {
    try {
      final decoded = jsonDecode(rawExecutionState);
      final value = decoded is Map ? decoded['attachmentMessageId'] : null;
      return value is String && value.trim().isNotEmpty ? value.trim() : null;
    } on Object {
      return null;
    }
  }

  Set<String> _attachmentPathsForTask(AgentTask task) {
    final metadata = _decodeMap(task.executionStateJson);
    final ids = <String>{
      if (metadata['attachmentMessageId'] is String)
        metadata['attachmentMessageId'] as String,
      if (metadata['queuedAttachmentMessageIds'] is List)
        ...(metadata['queuedAttachmentMessageIds'] as List).whereType<String>(),
    };
    final paths = <String>{};
    for (final id in ids) {
      final message = database.messageBox.get(id.trim());
      if (message?.groupId != task.groupId || message?.senderType != 'user') {
        continue;
      }
      for (final attachment in message?.media ?? const []) {
        final path = attachment.localPath.trim();
        if (path.isNotEmpty) paths.add(path);
      }
    }
    return paths;
  }

  bool _isReferencedAttachmentPath(
    String rawPath,
    Iterable<String> attachmentPaths, {
    required bool isWindows,
  }) {
    try {
      final normalized = WorkspacePathPolicy.normalizePath(
        rawPath,
        isWindows: isWindows,
      );
      return attachmentPaths.any(
        (path) =>
            WorkspacePathPolicy.normalizePath(
              path,
              isWindows: isWindows,
            ) ==
            normalized,
      );
    } on Object {
      return false;
    }
  }

  String _workModeContext(
      AgentTask task, AICharacter character, WorkToolRegistry registry,
      {required String workspaceRoot}) {
    final base = WorkModePolicy.planningContext(character);
    final discoverable = WorkModePolicy.discoverableSkills(
      character: character,
      installedSkills: database.characterSkillBox.values,
      resolvedSkills: CharacterSkillResolver.resolveFor(
        character,
        task.userRequest,
      ).skills,
    );
    final skillCatalog = discoverable.isEmpty
        ? '无（需要时可通过 meta.find-skills 查找或安装）'
        : discoverable.map(_compactSkillCatalogEntry).join('\n');
    final tools = registry.definitions
        .map((definition) =>
            '${definition.name.wireName}(${definition.access.name})')
        .join('、');
    final summary = task.contextSummary.trim();
    final handoff = WorkHandoffState.fromTask(task);
    final targetsDesktop =
        WorkModeDirectoryService.requestTargetsDesktop(task.userRequest);
    return [
      base,
      '角色可发现技能目录（全局技能按需加载；角色已绑定技能正文会注入；权限仍需通过角色授权与工具策略交集校验）：\n$skillCatalog',
      '当前生产 WorkAgentLoop 已注册工具：$tools。',
      '当前授权工作区绝对路径：$workspaceRoot。command.run 的 workingDirectory 为空时会自动解析为当前授权工作区；不要填写 "."，也禁止填写工作区外路径。',
      if (targetsDesktop)
        '用户明确指定“桌面”：当前工作区已绑定到授权的桌面根目录；请直接使用相对文件名，不要再添加 Desktop/ 或 conversations/ 前缀。',
      if (task.plan.trim().isNotEmpty) '公开角色路由计划：${task.plan.trim()}',
      if (handoff != null)
        '当前接力阶段：${handoff.stageLabel}；交付物：${handoff.deliverables.join('、')}；完成标准：${handoff.completionCriteria.join('、')}。',
      if (handoff?.lastSummary.trim().isNotEmpty == true)
        '上一阶段公开摘要：${handoff!.lastSummary}',
      _runtimeToolAvailabilityContext(),
      if (summary.isNotEmpty) '持久化任务上下文（公开摘要）：$summary',
    ].join('\n');
  }

  String _runtimeToolAvailabilityContext() {
    final pathEntries = (Platform.environment['PATH'] ?? '')
        .split(Platform.isWindows ? ';' : ':')
        .where((entry) => entry.trim().isNotEmpty);
    final available = <String>[];
    for (final executable in const ['pandoc', 'tectonic']) {
      final found = pathEntries.any((directory) {
        final names = Platform.isWindows
            ? <String>[executable, '$executable.exe']
            : <String>[executable];
        return names.any((name) {
          final candidate = File(
            '${directory.trim()}${Platform.pathSeparator}$name',
          );
          return FileSystemEntity.typeSync(candidate.path) ==
              FileSystemEntityType.file;
        });
      });
      if (found) available.add(executable);
    }
    if (available.isEmpty) {
      return '当前运行时未检测到 pandoc/tectonic；只有在 command.run 实际返回缺失工具后，才能说明工具缺失。';
    }
    return '当前运行时已检测到可执行工具：${available.join('、')}。持久化上下文中旧的“缺少工具”提示可能已过期；不得据此再次声称工具缺失，必须优先按原目标调用 command.run 并根据真实输出继续。';
  }

  String _compactSkillCatalogEntry(CharacterSkill skill) {
    final description =
        skill.description.trim().replaceAll(RegExp(r'\s+'), ' ');
    final clipped = description.length <= 180
        ? description
        : '${description.substring(0, 179)}…';
    return '- ${skill.id}｜${skill.domain}｜${skill.name}：$clipped';
  }

  List<CharacterSkill> _skillsFor(AICharacter character, String request) {
    final resolution = CharacterSkillResolver.resolveFor(character, request);
    final installed = database.characterSkillBox.values.where(
      (skill) =>
          skill.isGlobal ||
          skill.characterId == character.id ||
          character.skillIds.contains(skill.id),
    );
    return WorkModePolicy.resolveSkills(
      character: character,
      userRequest: request,
      installedSkills: installed,
      resolvedSkills: resolution.skills,
    );
  }

  Future<T> _serializeSkillMutation<T>(Future<T> Function() operation) {
    final previous = _skillMutationQueue;
    late final Future<T> scheduled;
    scheduled = previous.catchError((Object _) {}).then((_) => operation());
    _skillMutationQueue = scheduled.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return scheduled;
  }

  Future<Map<String, dynamic>> _createSkill(
    AICharacter character,
    Map<String, dynamic> args,
  ) async {
    final rawInstructions = args['instructions'];
    if (rawInstructions is! List ||
        rawInstructions.any((item) => item is! String)) {
      return {'ok': false, 'error': 'instructions_missing'};
    }
    final rawPermissions = args['permissions'];
    final permissions = ToolPermission.values
        .where((permission) =>
            rawPermissions is List && rawPermissions.contains(permission.name))
        .toList(growable: false);
    final skill = CharacterSkill(
      characterId: character.id,
      name: args['name']?.toString() ?? 'Generated Skill',
      domain: args['domain']?.toString() ?? 'general',
      description: args['description']?.toString() ?? '',
      instructions: rawInstructions.cast<String>(),
      requiredPermissions: permissions,
    );
    await database.characterSkillBox.put(skill.id, skill);
    if (!character.skillIds.contains(skill.id)) {
      character.skillIds = [...character.skillIds, skill.id];
      await database.aiCharacterBox.put(character.id, character);
    }
    return {'ok': true, 'skillId': skill.id, 'name': skill.name};
  }

  Future<Map<String, dynamic>> _downloadSkill(
    AICharacter character,
    Map<String, dynamic> args,
  ) async {
    final requested = args['templateId']?.toString() ?? args['id']?.toString();
    final template = requested == null
        ? (SkillDownloadService.recommendedTemplatesFor(character).isEmpty
            ? null
            : SkillDownloadService.recommendedTemplatesFor(character).first)
        : ExpertSkillCatalog.findById(requested);
    if (template == null) return {'ok': false, 'error': 'template_not_found'};
    final existing = database.characterSkillBox.values.where(
      (skill) =>
          skill.characterId == character.id && skill.name == template.name,
    );
    final skill = existing.isEmpty
        ? template.instantiateFor(character.id)
        : existing.first;
    if (existing.isEmpty) await database.characterSkillBox.put(skill.id, skill);
    character.skillIds = {...character.skillIds, skill.id}.toList();
    await database.aiCharacterBox.put(character.id, character);
    return {'ok': true, 'skillId': skill.id, 'templateId': template.id};
  }

  Future<String> _failureReply(AgentTask task, WorkFailure failure) async {
    final reason = _failureReplyText(failure.reason, fallback: '任务执行失败。');
    final technical = _failureReplyText(
      failure.technicalDetail,
      fallback: reason,
    );
    final attachmentSelection = await _safeArtifactsForAttachment(task);
    final artifactNames = attachmentSelection.files
        .map((file) => _basename(file.path))
        .where((name) => name.trim().isNotEmpty)
        .take(6)
        .toList(growable: false);
    final recordedArtifactNames = task.lastArtifactPaths
        .map(_basename)
        .where((name) => name.trim().isNotEmpty)
        .take(6)
        .toList(growable: false);
    final lines = <String>[
      '任务未完成。',
      '原因：$reason',
      if (technical != reason) '技术细节：$technical',
    ];
    if (task.completedOperations.isNotEmpty) {
      lines.add('已完成：${task.completedOperations.length} 个步骤，最近的安全检查点已保留。');
    }
    if (artifactNames.isNotEmpty) {
      lines.add(
        '输出文件：已确认工作区中有 ${artifactNames.join('、')}；任务失败不会删除这些文件，并会尽量附加到这条消息。',
      );
    } else if (recordedArtifactNames.isNotEmpty) {
      lines.add(
        '输出文件：已记录候选路径 ${recordedArtifactNames.join('、')}，但当前没有确认到仍可交付的文件；重试时会从最近检查点继续核对。',
      );
    } else {
      lines.add(
        '输出文件：当前没有确认到可交付文件；如果失败前已经写入文件，重试时会从最近检查点继续核对。',
      );
    }
    lines.add(
        '下一步：${_failureReplyText(failure.suggestedAction, fallback: '请检查任务面板后重试。')}');
    return lines.join('\n');
  }

  String _failureReplyText(String value, {required String fallback}) {
    if (value.trim().isEmpty) return fallback;
    final safe = sanitizeWorkTaskError(value);
    return safe == '任务执行失败' ? fallback : safe;
  }

  Future<void> _appendPublicMessage(
    AgentTask task,
    AICharacter character,
    String content,
  ) async {
    final text = content.trim();
    if (text.isEmpty) return;

    // The model's final response is the chat reply. Persist it before the
    // optional artifact-copy phase so a slow or failed attachment delivery
    // can never hide the conclusion from the conversation.
    final message = Message(
      groupId: task.groupId,
      senderId: character.id,
      senderType: 'ai',
      content: text,
    );
    await database.persistMessage(message);

    List<MediaAttachment>? media;
    File? temporaryBundle;
    try {
      try {
        final selection = await _safeArtifactsForAttachment(task);
        final files = selection.files;
        final attachmentSkippedNames = <String>[];
        final deliveredArchivePaths = <String>[];
        final bundledSkippedNames = <String>[];
        final totalBytes = files.fold<int>(0, (sum, file) {
          try {
            return sum + file.lengthSync();
          } on Object {
            return sum;
          }
        });
        // Keep ordinary artifacts as individual file cards so the chat shows
        // exactly which files this run produced or modified. Bundle only when
        // the count/size would make individual delivery impractical.
        final needsBundle = files.length > _maxArtifactAttachments ||
            totalBytes > _maxAttachedArtifactBytes;
        await _recordArtifactProgress(
          task,
          processedFiles: 0,
          totalFiles: files.length,
          processedBytes: 0,
          totalBytes: totalBytes,
        );
        final deliveryFiles = <File>[];
        if (needsBundle && files.isNotEmpty) {
          temporaryBundle = await _createArtifactBundle(
            task,
            selection.entries,
            skippedNames: bundledSkippedNames,
            includedArchivePaths: deliveredArchivePaths,
            onFileProcessed: (processedFiles, processedBytes) =>
                _recordArtifactProgress(
              task,
              processedFiles: processedFiles,
              totalFiles: files.length,
              processedBytes: processedBytes,
              totalBytes: totalBytes,
            ),
          );
          if (temporaryBundle != null) deliveryFiles.add(temporaryBundle);
        } else {
          deliveryFiles.addAll(files);
        }
        final attachments = <MediaAttachment>[];
        var processedArtifactFiles = 0;
        var processedArtifactBytes = 0;
        for (final file in deliveryFiles) {
          var processedBytes = 0;
          try {
            final stat = await file.stat();
            processedBytes = stat.size;
            final sizeLimit = identical(file, temporaryBundle)
                ? _maxArtifactBundleBytes
                : _maxAttachedArtifactBytes;
            if (stat.type != FileSystemEntityType.file ||
                stat.size > sizeLimit) {
              attachmentSkippedNames.add(_basename(file.path));
              continue;
            }
            final copied = await (mediaCopier == null
                ? database.copyToMedia(
                    file,
                    'file',
                    fileName: _basename(file.path),
                  )
                : mediaCopier!(
                    file,
                    'file',
                    fileName: _basename(file.path),
                  ));
            attachments.add(copied);
            if (temporaryBundle == null) {
              final entry =
                  selection.entries.cast<_ArtifactFileEntry?>().firstWhere(
                        (item) => item?.file.path == file.path,
                        orElse: () => null,
                      );
              if (entry != null) deliveredArchivePaths.add(entry.archivePath);
            }
          } on Object {
            // Continue delivering other verified artifacts when one copy fails.
            attachmentSkippedNames.add(_basename(file.path));
          } finally {
            if (temporaryBundle == null) {
              processedArtifactFiles++;
              processedArtifactBytes += processedBytes;
              await _recordArtifactProgress(
                task,
                processedFiles: processedArtifactFiles,
                totalFiles: files.length,
                processedBytes: processedArtifactBytes,
                totalBytes: totalBytes,
              );
            }
          }
        }
        if (attachments.isNotEmpty) media = attachments;
        await _recordArtifactProgress(
          task,
          processedFiles: files.length,
          totalFiles: files.length,
          processedBytes: totalBytes,
          totalBytes: totalBytes,
        );
        final deliveryNote = _artifactDeliveryNote(
          selection,
          bundled: temporaryBundle != null,
          attachedCount: media?.length ?? 0,
          deliveredArchivePaths: deliveredArchivePaths,
          skippedNames: [
            ...bundledSkippedNames,
            ...attachmentSkippedNames,
          ],
        );
        if (deliveryNote.isNotEmpty) {
          message.content = '$text\n\n$deliveryNote';
        }
        message.media = media;
        await database.updateMessage(message);
      } finally {
        if (temporaryBundle != null) {
          try {
            if (await temporaryBundle.exists()) await temporaryBundle.delete();
          } on Object {
            // The copied media attachment remains authoritative if cleanup fails.
          }
        }
      }
    } on Object {
      // The text reply is already durable. Artifact delivery is best effort
      // and must not turn a completed model response into a failed task.
    }
  }

  /// A source-code request is successful only when a real readable file was
  /// produced. The guard intentionally does not synthesize a path or recover
  /// prose into code; that fallback belonged to the removed legacy work-mode
  /// protocol and could create a misleading `.py`/`.js` attachment.
  Future<String?> _validateCompletion(
    AgentTask task,
    AgentFinishCompletion _,
  ) async {
    final artifact = await _safeArtifactsForAttachment(task);
    return WorkArtifactDeliveryGuard.failureFor(
      request: task.userRequest,
      hasReadableArtifact: artifact.files.isNotEmpty,
    );
  }

  static const int _maxArtifactAttachments = 12;
  static const int _maxAttachedArtifactBytes = 50 * 1024 * 1024;
  static const int _maxArtifactBundleBytes = 200 * 1024 * 1024;

  Future<_ArtifactAttachmentSelection> _safeArtifactsForAttachment(
    AgentTask task,
  ) async {
    final files = workspaceFileService;
    if (files == null || task.lastArtifactPaths.isEmpty) {
      return const _ArtifactAttachmentSelection();
    }
    final entries = <_ArtifactFileEntry>[];
    final skipped = <String>[];
    for (final raw in task.lastArtifactPaths) {
      try {
        final resolved = await files.pathPolicy.resolveExisting(raw);
        // `wasSymbolicLink` also reports harmless platform aliases such as
        // macOS /var -> /private/var. Reject only an explicitly linked final
        // component; the path policy has already resolved and authorized the
        // complete path before this check.
        final requestedType = await FileSystemEntity.type(
          raw,
          followLinks: false,
        );
        if (!resolved.isFile || requestedType == FileSystemEntityType.link) {
          skipped.add(_basename(raw));
          continue;
        }
        final file = File(resolved.path);
        final stat = await file.stat();
        if (stat.size > _maxAttachedArtifactBytes) {
          skipped.add(_basename(raw));
          continue;
        }
        if (entries.every((item) => item.file.path != file.path)) {
          entries.add(_ArtifactFileEntry(
            file: file,
            archivePath: _archiveRelativePath(
              resolved.authorizedRoot,
              resolved.path,
            ),
          ));
        }
      } on Object {
        skipped.add(_basename(raw));
      }
    }
    return _ArtifactAttachmentSelection(
      entries: List<_ArtifactFileEntry>.unmodifiable(entries),
      skippedNames: List<String>.unmodifiable(skipped),
    );
  }

  Future<File?> _createArtifactBundle(
    AgentTask task,
    List<_ArtifactFileEntry> entries, {
    required List<String> skippedNames,
    required List<String> includedArchivePaths,
    Future<void> Function(int processedFiles, int processedBytes)?
        onFileProcessed,
  }) async {
    final root = await database.aiProcessingDir;
    final safeTaskId = task.id.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final staging = Directory('${root.path}/work-artifacts-$safeTaskId');
    final archive = File('${root.path}/work-artifacts-$safeTaskId.zip');
    try {
      await staging.create(recursive: true);
      var total = 0;
      var index = 0;
      var processedBytesTotal = 0;
      for (var entryIndex = 0; entryIndex < entries.length; entryIndex++) {
        final entry = entries[entryIndex];
        final file = entry.file;
        var processedBytes = 0;
        try {
          final stat = await file.stat();
          processedBytes = stat.size;
          if (stat.size > _maxArtifactBundleBytes - total) {
            skippedNames.add(_basename(file.path));
            continue;
          }
          final name =
              '${index.toString().padLeft(3, '0')}_${entry.archivePath}';
          final target = File('${staging.path}/$name');
          await target.parent.create(recursive: true);
          await file.copy(target.path);
          total += stat.size;
          includedArchivePaths.add(entry.archivePath);
          index++;
        } on Object {
          skippedNames.add(_basename(file.path));
        } finally {
          processedBytesTotal += processedBytes;
          if (onFileProcessed != null) {
            await onFileProcessed(
              entryIndex + 1,
              processedBytesTotal,
            );
          }
        }
      }
      if (index == 0) return null;
      await ZipFileEncoder().zipDirectory(
        staging,
        filename: archive.path,
        followLinks: false,
      );
      return archive;
    } on Object {
      try {
        if (await archive.exists()) await archive.delete();
      } on Object {
        // Best-effort cleanup only; the project files are never touched.
      }
      return null;
    } finally {
      try {
        if (await staging.exists()) await staging.delete(recursive: true);
      } on Object {
        // Best-effort cleanup only; the generated archive remains bounded.
      }
    }
  }

  Future<void> _recordArtifactProgress(
    AgentTask task, {
    required int processedFiles,
    required int totalFiles,
    required int processedBytes,
    required int totalBytes,
  }) {
    return _record(
      task,
      WorkTaskEventKind.toolOutput,
      '文件交付进度',
      detail:
          '已处理 $processedFiles/$totalFiles 个文件，$processedBytes/$totalBytes 字节。',
      safeMetadata: {
        'phase': 'artifact_delivery',
        'filesProcessed': processedFiles,
        'filesTotal': totalFiles,
        'bytesProcessed': processedBytes,
        'bytesTotal': totalBytes,
      },
    );
  }

  String _artifactDeliveryNote(
    _ArtifactAttachmentSelection selection, {
    required bool bundled,
    required int attachedCount,
    Iterable<String> deliveredArchivePaths = const <String>[],
    Iterable<String> skippedNames = const <String>[],
  }) {
    if (attachedCount == 0 &&
        selection.skippedNames.isEmpty &&
        selection.files.isEmpty) {
      return '';
    }
    final deliveredPaths = deliveredArchivePaths.toList(growable: false);
    final delivered = bundled
        ? '已将 ${deliveredPaths.length} 个产物打包为 ZIP 附件。'
        : attachedCount > 0
            ? '已附加 $attachedCount 个产物。'
            : '产物已生成，但暂时无法复制为聊天附件。';
    final listed = deliveredPaths.take(6).join('、');
    final listSuffix = deliveredPaths.length > 6 ? ' 等' : '';
    final withPaths =
        listed.isEmpty ? delivered : '$delivered 包含：$listed$listSuffix。';
    final allSkipped = <String>{
      ...selection.skippedNames,
      ...skippedNames,
    };
    if (allSkipped.isEmpty) return withPaths;
    final names = allSkipped.take(6).join('、');
    final suffix = allSkipped.length > 6 ? ' 等' : '';
    return '$withPaths 未附加：$names$suffix（文件不存在、超出大小限制或无法安全读取）。';
  }

  String _archiveRelativePath(String root, String path) {
    final normalizedRoot =
        root.replaceAll('\\', '/').replaceFirst(RegExp(r'/+$'), '');
    final normalizedPath = path.replaceAll('\\', '/');
    final prefix = '$normalizedRoot/';
    final relative = normalizedPath.startsWith(prefix)
        ? normalizedPath.substring(prefix.length)
        : _basename(path);
    final safeSegments = relative
        .split('/')
        .where((segment) =>
            segment.isNotEmpty && segment != '.' && segment != '..')
        .map((segment) => segment.replaceAll(RegExp(r'[^A-Za-z0-9._ -]'), '_'))
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
    return safeSegments.isEmpty ? 'artifact' : safeSegments.join('/');
  }

  Future<void> _persistCheckpoint(AgentTask task) async {
    task.updatedAt = clock();
    final sink = _taskCheckpointSink;
    if (sink != null) {
      await sink(task);
      return;
    }
    await database.agentTaskBox.put(task.id, task);
    _taskUpdateSink?.call(task);
  }

  Future<void> _record(
    AgentTask task,
    WorkTaskEventKind kind,
    String title, {
    String detail = '',
    Map<String, Object?>? safeMetadata,
  }) async {
    if (eventStore.appendsSuspendedForDataClear) return;
    try {
      await eventStore.append(
        taskId: task.id,
        kind: kind,
        title: title,
        detail: detail,
        safeMetadata: safeMetadata,
        timestamp: clock(),
      );
    } on Object catch (error) {
      // A late callback can race with app-data clearing. Do not recreate a
      // deleted task checkpoint merely because diagnostic persistence stopped.
      if (eventStore.appendsSuspendedForDataClear) return;
      task.eventLogIncomplete = true;
      task.lastError = task.lastError.isEmpty
          ? '任务日志保存不完整：${sanitizeWorkTaskError(error)}'
          : task.lastError;
      try {
        await database.agentTaskBox.put(task.id, task);
        _taskUpdateSink?.call(task);
      } on Object {
        // Logging is diagnostic and cannot replace the task outcome.
      }
    }
  }

  bool _requestsExplicitValidation(String request) {
    return isExplicitWorkValidationRequest(request);
  }

  String _displayPlan(WorkChangePlan plan) {
    final paths = plan.exactPaths.isEmpty
        ? plan.knownAffectedDirectories
        : plan.exactPaths;
    return paths.map(_basename).join('、');
  }
}

class _ArtifactAttachmentSelection {
  final List<_ArtifactFileEntry> entries;
  final List<String> skippedNames;

  const _ArtifactAttachmentSelection({
    this.entries = const <_ArtifactFileEntry>[],
    this.skippedNames = const <String>[],
  });

  List<File> get files =>
      entries.map((entry) => entry.file).toList(growable: false);

  List<String> get archivePaths =>
      entries.map((entry) => entry.archivePath).toList(growable: false);
}

class _ArtifactFileEntry {
  final File file;
  final String archivePath;

  const _ArtifactFileEntry({required this.file, required this.archivePath});
}

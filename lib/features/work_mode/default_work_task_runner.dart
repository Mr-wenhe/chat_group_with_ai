import 'dart:async';
import 'dart:convert';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/models/character_skill.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/tool_permission.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/features/agentic/agent_runtime.dart';
import 'package:chat_group/features/agentic/agent_attachment_context.dart';
import 'package:chat_group/features/agentic/character_skill_resolver.dart';
import 'package:chat_group/features/agentic/expert_skill_catalog.dart';
import 'package:chat_group/features/agentic/skill_download_service.dart';
import 'package:chat_group/features/agentic/tool_request.dart';
import 'package:chat_group/features/agentic/tools/browser_context_tool.dart';
import 'package:chat_group/features/agentic/tools/local_agent_bridge_config.dart';
import 'package:chat_group/features/agentic/tools/local_agent_bridge_client.dart';
import 'package:chat_group/features/agentic/tools/local_agent_bridge_launcher.dart';
import 'package:chat_group/features/agentic/tools/workspace_file_tool.dart';
import 'package:chat_group/features/ai_governance/ai_request_gateway.dart';
import 'package:chat_group/features/ai_governance/ai_governance_store.dart';
import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/web_search/security/search_secret_scanner.dart';
import 'package:chat_group/features/work_mode/work_mode_policy.dart';
import 'package:chat_group/features/work_mode/work_mode_workspace_service.dart';
import 'package:chat_group/features/work_mode/work_task_coordinator.dart';
import 'package:chat_group/features/work_mode/work_task_error_sanitizer.dart';
import 'package:chat_group/features/work_mode/work_task_event.dart';
import 'package:chat_group/features/work_mode/work_task_event_store.dart';
import 'package:dio/dio.dart';

/// The app-scoped production runner for work-mode tasks.
///
/// It deliberately owns no Flutter state. A chat page submits a durable task;
/// this runner resolves the character/configuration, drives [AgentRuntime],
/// persists checkpoints and writes the final public message to Hive.
class DefaultWorkTaskRunner
    implements WorkTaskRunner, WorkTaskProgressReporter {
  final DatabaseService database;
  final WorkTaskEventStore eventStore;
  final ApiCredentialResolver credentials;
  final AiRequestGateway gateway;
  final WorkModeWorkspaceService workspaceService;
  final LocalAgentBridgeLauncher bridgeLauncher;
  final DateTime Function() clock;
  void Function(AgentTask task)? _taskUpdateSink;
  // Approval requests contain the exact file/command payload required for the
  // current in-process action. Keep that payload transient; Hive only stores
  // the redacted checkpoint produced by safeToolRequestCheckpoint().
  final Map<String, ToolRequest> _pendingRequests = <String, ToolRequest>{};

  DefaultWorkTaskRunner({
    required this.database,
    required this.eventStore,
    ApiCredentialResolver? credentials,
    AiRequestGateway? gateway,
    WorkModeWorkspaceService? workspaceService,
    LocalAgentBridgeLauncher? bridgeLauncher,
    DateTime Function()? clock,
  })  : credentials = credentials ?? SecureApiCredentialResolver(),
        gateway = gateway ??
            AiRequestGateway(
              store: AiGovernanceStore.forDatabase(database),
            ),
        workspaceService =
            workspaceService ?? WorkModeWorkspaceService(db: database),
        bridgeLauncher = bridgeLauncher ?? LocalAgentBridgeLauncher(),
        clock = clock ?? DateTime.now;

  @override
  void setTaskUpdateSink(void Function(AgentTask task) sink) {
    _taskUpdateSink = sink;
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
    if (cancellation.isCancelled || task.isTerminal) return;
    if (task.plan.trim().isEmpty) {
      task.plan = '分析请求 → 执行必要工具 → 校验结果并汇报';
      await _saveTask(task);
    }
    if (_atSoftLimit(task)) {
      await _pauseForSoftLimit(task, cancellation);
      return;
    }

    final cancellationToken = CancelToken();
    final cancellationSubscription = cancellation.whenCancelled.then<void>(
      (_) => cancellationToken.cancel('用户已停止任务'),
    );
    LocalAgentBridgeWorkspaceRegistration? registration;
    try {
      final workspace = await workspaceService.loadOrCreate(
        conversationId: task.groupId,
        isDirectChat: task.groupId.startsWith('dm:'),
      );
      registration = await bridgeLauncher.registerWorkspace(
        conversationId: task.groupId,
        workspacePath: workspace.workDirPath,
      );
      if (registration == null) {
        throw StateError('当前平台无法启动本地工作区执行器');
      }

      final provider = _providerFor(config);
      final history = await _conversationHistory(task);
      final restoredRequests = _restoredRequests(task);
      final actionBase = task.actionCount;
      final restoredRequestCount = restoredRequests.length;
      final pendingRequest = _pendingRequests[task.id];
      final runtime = _runtimeFor(
        task: task,
        character: character,
        config: config,
        provider: provider,
        apiKey: apiKey,
        cancellation: cancellation,
        cancellationToken: cancellationToken,
        actionBase: actionBase,
        restoredRequestCount: restoredRequestCount,
        toolStepLimit: _availableToolStepLimit(task, actionBase),
      );
      final decision = _approvalDecision(task.executionStateJson);
      final result = pendingRequest != null && decision != null
          ? decision == 'approved'
              ? await runtime.executeApprovedTool(
                  character: character,
                  request: pendingRequest,
                  userRequest: task.userRequest,
                  priorExecutedRequests: restoredRequests,
                  conversationHistory: history,
                )
              : await runtime.skipRejectedTool(
                  character: character,
                  request: pendingRequest,
                  userRequest: task.userRequest,
                  priorExecutedRequests: restoredRequests,
                  conversationHistory: history,
                )
          : await runtime.run(
              character: character,
              skills: _skillsFor(character, task.userRequest),
              userRequest: await _requestWithAttachmentContext(task),
              conversationHistory: history,
              priorExecutedRequests: restoredRequests,
              forceSkillCreation: _shouldCreateSkill(
                character,
                task.userRequest,
              ),
              workModeContext: _workModeContext(task, character),
            );
      if (cancellation.isCancelled) return;
      await _applyResult(
        task,
        character,
        result,
        actionBase: actionBase,
        restoredRequestCount: restoredRequestCount,
      );
    } finally {
      // The listener only bridges a future cancellation into Dio. Waiting for
      // it here would deadlock successful tasks because the cancellation
      // future intentionally never completes on the happy path.
      unawaited(cancellationSubscription);
      cancellationToken.cancel();
      if (cancellation.isCancelled) _pendingRequests.remove(task.id);
      final currentRegistration = registration;
      if (currentRegistration != null) {
        try {
          await bridgeLauncher.unregisterWorkspace(
            conversationId: task.groupId,
            registration: currentRegistration,
          );
        } on Object {
          // Workspace routing cleanup is best effort during shutdown.
        }
      }
    }
  }

  AgentRuntime _runtimeFor({
    required AgentTask task,
    required AICharacter character,
    required ApiConfig config,
    required ApiProvider provider,
    required String apiKey,
    required WorkTaskCancellation cancellation,
    required CancelToken cancellationToken,
    required int actionBase,
    required int restoredRequestCount,
    required int toolStepLimit,
  }) {
    final bridge = LocalAgentBridgeClient();
    final capability = gateway.capability(provider, config.modelName);
    final workspace = WorkspaceFileTool(
      bridge,
      conversationId: task.groupId,
    );
    return AgentRuntime(
      complete: (messages) => gateway.sendChatMessageStreamed(
        apiKey: apiKey,
        provider: provider,
        customBaseUrl: config.customBaseUrl,
        model: config.modelName,
        messages: messages,
        maxTokens: AgentRuntime.preferredMaxOutputTokens
            .clamp(1, capability.maxOutput)
            .toInt(),
        receiveTimeout: AgentRuntime.completionTimeout,
        maxRetries: 0,
        cancelToken: cancellationToken,
        purpose: AiRequestPurpose.agent,
        conversationId: task.groupId,
        characterId: character.id,
        requiresTools: true,
        userInitiated: true,
      ),
      workspaceFileTool: workspace,
      browserContextTool: BrowserContextTool(bridge),
      skillCreateHandler: (args) => _createSkill(character, args),
      skillDownloadHandler: (args) => _downloadSkill(character, args),
      enableLocalFilePlanner: false,
      completionMaxRetries: 0,
      toolStepLimit: toolStepLimit,
      onProgress: (progress) => _persistProgress(
        task,
        progress,
        cancellation: cancellation,
        actionBase: actionBase,
        restoredRequestCount: restoredRequestCount,
      ),
      contextIsDirectChat: task.groupId.startsWith('dm:'),
      approvalPolicy: WorkModePolicy.requiresApproval,
      // Task permissions are a snapshot of the role's configured capability.
      // Never elevate an existing character by granting every tool here; a
      // missing capability must remain a visible, recoverable task result.
      grantedPermissions: (task.requestedPermissions.isEmpty
              ? character.toolPermissions
              : task.requestedPermissions)
          .toSet(),
      shouldCancel: () => cancellation.isCancelled,
    );
  }

  Future<void> _persistProgress(
    AgentTask task,
    AgentRuntimeProgress progress, {
    required WorkTaskCancellation cancellation,
    required int actionBase,
    required int restoredRequestCount,
  }) async {
    if (_progressWriteIsStale(task, cancellation)) return;
    final pending = progress.pendingRequest;
    if (pending != null) {
      _pendingRequests[task.id] = pending;
    } else {
      _pendingRequests.remove(task.id);
    }
    task
      ..currentStep = progress.executedRequests.length
      ..actionCount = _actionCountFor(
        actionBase: actionBase,
        restoredRequestCount: restoredRequestCount,
        executedRequestCount: progress.executedRequests.length,
      )
      ..completedOperations = progress.executedRequests
          .map(safeToolRequestCheckpoint)
          .toList(growable: false)
      ..pendingToolRequestJson =
          pending == null ? '' : safeToolRequestCheckpoint(pending)
      ..lastArtifactPaths = _artifactPaths(progress.executedRequests)
      ..status = progress.pendingRequest == null &&
              progress.stage != AgentRuntimeProgressStage.waitingForApproval
          ? AgentTaskStatus.runningTool
          : AgentTaskStatus.waitingForApproval
      ..contextSummary = _buildContextSummary(
        task,
        progress.executedRequests,
        task.resultSummary,
      )
      ..updatedAt = clock();
    await database.agentTaskBox.put(task.id, task);
    if (_progressWriteIsStale(task, cancellation)) return;
    _publishTask(task);
    await _recordProgressEvent(task, progress);
  }

  Future<void> _recordProgressEvent(
    AgentTask task,
    AgentRuntimeProgress progress,
  ) async {
    final kind = switch (progress.stage) {
      AgentRuntimeProgressStage.waitingForApproval =>
        WorkTaskEventKind.approvalRequired,
      AgentRuntimeProgressStage.stepFailed => WorkTaskEventKind.failed,
      AgentRuntimeProgressStage.fileCreated ||
      AgentRuntimeProgressStage.validating ||
      AgentRuntimeProgressStage.toolCompleted =>
        progress.publicDetail == null
            ? WorkTaskEventKind.stepCompleted
            : WorkTaskEventKind.toolOutput,
      _ => WorkTaskEventKind.stepStarted,
    };
    final label = progress.currentStepLabel?.trim();
    final title = label == null || label.isEmpty
        ? _fallbackStageLabel(progress.stage)
        : label;
    final metadata = <String, Object?>{
      'stage': progress.stage.name,
      'step': progress.executedRequests.length,
      if (progress.pendingRequest != null)
        'tool': progress.pendingRequest!.tool.wireName
      else if (progress.executedRequests.isNotEmpty)
        'tool': progress.executedRequests.last.tool.wireName,
    };
    try {
      await eventStore.append(
        taskId: task.id,
        kind: kind,
        title: title,
        detail: progress.publicDetail ??
            (progress.pendingRequest == null
                ? ''
                : _safeApprovalDetail(progress.pendingRequest!)),
        progressCurrent: progress.executedRequests.length,
        progressTotal: task.actionLimit,
        safeMetadata: metadata,
      );
    } on Object {
      task.eventLogIncomplete = true;
      try {
        await database.agentTaskBox.put(task.id, task);
        _publishTask(task);
      } on Object {
        // The task can outlive the database during application shutdown.
      }
    }
  }

  Future<void> _applyResult(
    AgentTask task,
    AICharacter character,
    AgentRuntimeResult result, {
    required int actionBase,
    required int restoredRequestCount,
  }) async {
    if (task.isTerminal) return;
    if (result.pendingToolRequest != null) {
      _pendingRequests[task.id] = result.pendingToolRequest!;
    } else {
      _pendingRequests.remove(task.id);
    }
    task
      ..completedOperations = result.executedToolRequests
          .map(safeToolRequestCheckpoint)
          .toList(growable: false)
      ..currentStep = result.executedToolRequests.length
      ..actionCount = _actionCountFor(
        actionBase: actionBase,
        restoredRequestCount: restoredRequestCount,
        executedRequestCount: result.executedToolRequests.length,
      )
      ..lastArtifactPaths = _artifactPaths(result.executedToolRequests)
      ..pendingToolRequestJson = result.pendingToolRequest == null
          ? ''
          : safeToolRequestCheckpoint(result.pendingToolRequest!)
      ..executionStateJson = _withoutApprovalDecision(task.executionStateJson)
      ..resultSummary = _safePublicText(result.message)
      ..contextSummary = _buildContextSummary(
        task,
        result.executedToolRequests,
        result.message,
      )
      ..updatedAt = clock();

    if (result.status == AgentRuntimeStatus.waitingForApproval &&
        result.pendingToolRequest != null) {
      task
        ..status = AgentTaskStatus.waitingForApproval
        ..lastError = '';
      await _saveTask(task);
      await _record(
        task,
        WorkTaskEventKind.approvalRequired,
        '等待用户批准操作',
        detail: _safeApprovalDetail(result.pendingToolRequest!),
      );
      return;
    }

    if (result.status == AgentRuntimeStatus.completed) {
      task
        ..status = AgentTaskStatus.completed
        ..lastError = '';
      await _saveTask(task);
      await _appendPublicMessage(task, character, result.message);
      await _record(task, WorkTaskEventKind.completed, '任务已完成');
      _pendingRequests.remove(task.id);
      return;
    }

    final safeFailure = sanitizeWorkTaskError(result.message);
    task
      ..status = result.executedToolRequests.isEmpty
          ? AgentTaskStatus.failed
          : AgentTaskStatus.partiallyCompleted
      ..lastError = safeFailure
      ..resumeRequired = result.executedToolRequests.isNotEmpty;
    await _saveTask(task);
    await _appendPublicMessage(
      task,
      character,
      result.executedToolRequests.isEmpty
          ? result.message
          : '任务部分完成：${result.message}',
    );
    await _record(task, WorkTaskEventKind.failed, '任务未完成', detail: safeFailure);
    _pendingRequests.remove(task.id);
  }

  Future<void> _saveTask(AgentTask task) async {
    task.updatedAt = clock();
    await database.agentTaskBox.put(task.id, task);
    _publishTask(task);
  }

  Future<void> _appendPublicMessage(
    AgentTask task,
    AICharacter character,
    String content,
  ) async {
    final safe = _safePublicText(content);
    if (safe.isEmpty) return;
    await database.persistMessage(Message(
      groupId: task.groupId,
      senderId: character.id,
      senderType: 'ai',
      content: safe,
    ));
  }

  Future<void> _record(
    AgentTask task,
    WorkTaskEventKind kind,
    String title, {
    String detail = '',
  }) async {
    try {
      await eventStore.append(
        taskId: task.id,
        kind: kind,
        title: title,
        detail: detail,
      );
    } on Object {
      task.eventLogIncomplete = true;
      try {
        await database.agentTaskBox.put(task.id, task);
        _publishTask(task);
      } on Object {
        // A closing database cannot accept the diagnostic flag; the runner's
        // primary task result remains authoritative.
      }
    }
  }

  void _publishTask(AgentTask task) {
    _taskUpdateSink?.call(task);
  }

  Future<void> _pauseForSoftLimit(
    AgentTask task,
    WorkTaskCancellation cancellation,
  ) async {
    if (_progressWriteIsStale(task, cancellation)) return;
    task
      ..status = AgentTaskStatus.paused
      ..softLimitReached = true
      ..resumeRequired = true
      ..lastError = '已达到本任务执行上限，请确认后继续。'
      ..updatedAt = clock();
    await _saveTask(task);
    if (_progressWriteIsStale(task, cancellation)) return;
    await _record(task, WorkTaskEventKind.paused, '已达到执行上限');
  }

  bool _atSoftLimit(AgentTask task) {
    if (task.actionCount >= task.actionLimit) return true;
    final started = task.startedAt;
    return started != null && clock().difference(started) >= task.softTimeLimit;
  }

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
        orElse: () => ApiProvider.deepseek,
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
    final history = <Map<String, dynamic>>[];
    for (final message in messages.takeLast(24)) {
      final content = message.content.trim();
      if (content.isEmpty || content == task.userRequest.trim()) continue;
      if (message.senderType == 'user') {
        history.add({'role': 'user', 'content': content});
      } else if (message.senderType == 'ai') {
        history.add({'role': 'assistant', 'content': content});
      }
    }
    return history;
  }

  Future<String> _requestWithAttachmentContext(AgentTask task) async {
    final message = database.messageBox.values
        .where((item) =>
            item.groupId == task.groupId &&
            item.senderType == 'user' &&
            item.content.trim() == task.userRequest.trim())
        .toList()
      ..sort((left, right) => right.timestamp.compareTo(left.timestamp));
    return AgentAttachmentContext.enhanceCurrentRequest(
      userRequest: task.userRequest,
      media: message.isEmpty ? null : message.first.media,
    );
  }

  List<ToolRequest> _restoredRequests(AgentTask task) =>
      task.completedOperations
          .map(ToolRequest.fromJsonString)
          .whereType<ToolRequest>()
          .toList(growable: false);

  bool _progressWriteIsStale(
    AgentTask task,
    WorkTaskCancellation cancellation,
  ) {
    if (cancellation.isCancelled || task.isTerminal) return true;
    final stored = database.agentTaskBox.get(task.id);
    return stored != null && stored.isTerminal;
  }

  int _actionCountFor({
    required int actionBase,
    required int restoredRequestCount,
    required int executedRequestCount,
  }) {
    final newlyExecuted = executedRequestCount > restoredRequestCount
        ? executedRequestCount - restoredRequestCount
        : 0;
    return actionBase + newlyExecuted;
  }

  int _availableToolStepLimit(AgentTask task, int actionBase) {
    final configured =
        task.actionLimit.clamp(1, AgentTask.defaultActionLimit).toInt();
    if (actionBase <= 0) return configured;
    final remaining = configured - actionBase;
    return remaining > 0 ? remaining : 1;
  }

  String _workModeContext(AgentTask task, AICharacter character) {
    final base = WorkModePolicy.planningContext(character);
    final summary = task.contextSummary.trim();
    if (summary.isEmpty) return base;
    return '$base\n持久化任务上下文（公开摘要）：${_safePublicText(summary)}';
  }

  String _buildContextSummary(
    AgentTask task,
    Iterable<ToolRequest> requests,
    String lastResult,
  ) {
    var goal = task.userRequest;
    try {
      final decoded = jsonDecode(task.contextSummary);
      if (decoded is Map && decoded['goal'] is String) {
        final previousGoal = (decoded['goal'] as String).trim();
        if (previousGoal.isNotEmpty) goal = previousGoal;
      }
    } on Object {
      // Older builds stored plain text here; the current checkpoint simply
      // starts a structured summary while retaining the current request.
    }
    final actions =
        requests.map(_safeRequestSummary).take(32).toList(growable: false);
    return jsonEncode(<String, dynamic>{
      'goal': _boundedCheckpointText(goal),
      'latestRequest': _boundedCheckpointText(task.userRequest),
      'completedActions': actions,
      'artifactPaths': task.lastArtifactPaths.take(32).toList(growable: false),
      'lastResult': _boundedCheckpointText(lastResult),
    });
  }

  Map<String, dynamic> _safeRequestSummary(ToolRequest request) {
    try {
      final decoded = jsonDecode(safeToolRequestCheckpoint(request));
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } on Object {
      // Fall through to a minimal non-sensitive summary.
    }
    return <String, dynamic>{'tool': request.tool.wireName};
  }

  String _boundedCheckpointText(String value) {
    final safe = _safePublicText(value);
    return safe.length <= 512 ? safe : '${safe.substring(0, 511)}…';
  }

  List<String> _artifactPaths(Iterable<ToolRequest> requests) {
    final paths = <String>[];
    for (final request in requests) {
      final raw = request.args['path'];
      if (raw is! String) continue;
      final normalized = raw.replaceAll('\\', '/').trim();
      final safe = normalized.startsWith('/') ||
              RegExp(r'^[A-Za-z]:/').hasMatch(normalized)
          ? normalized.split('/').last
          : normalized;
      if (safe.isEmpty || safe.contains('..') || paths.contains(safe)) continue;
      paths.add(safe);
    }
    return paths;
  }

  List<CharacterSkill> _skillsFor(AICharacter character, String request) {
    final resolution = CharacterSkillResolver.resolveFor(character, request);
    final installed = database.characterSkillBox.values.where(
      (skill) =>
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

  bool _shouldCreateSkill(AICharacter character, String request) {
    final resolution = CharacterSkillResolver.resolveFor(character, request);
    return resolution.needsSkillCreation &&
        !_skillsFor(character, request).any(
          (skill) => skill.description.toLowerCase().contains(
                request.toLowerCase().trim(),
              ),
        );
  }

  Future<Map<String, dynamic>> _createSkill(
    AICharacter character,
    Map<String, dynamic> args,
  ) async {
    final rawInstructions = args['instructions'];
    if (rawInstructions is! List) {
      return {'ok': false, 'error': 'instructions_missing'};
    }
    final permissions = ToolPermission.values
        .where((permission) => (args['permissions'] is List
                ? args['permissions'] as List
                : const [])
            .contains(permission.name))
        .toList();
    final skill = CharacterSkill(
      characterId: character.id,
      name: args['name']?.toString() ?? 'Generated Skill',
      domain: args['domain']?.toString() ?? 'general',
      description: args['description']?.toString() ?? '',
      instructions: rawInstructions.whereType<String>().toList(),
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
    final requestedId =
        args['templateId']?.toString() ?? args['id']?.toString();
    final template = requestedId == null
        ? SkillDownloadService.recommendedTemplatesFor(character).firstOrNull
        : ExpertSkillCatalog.findById(requestedId);
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

  String? _approvalDecision(String raw) {
    try {
      final decoded = jsonDecode(raw);
      final value = decoded is Map ? decoded['approvalDecision'] : null;
      return value == 'approved' || value == 'rejected'
          ? value as String
          : null;
    } on Object {
      return null;
    }
  }

  String _withoutApprovalDecision(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final copy = Map<String, dynamic>.from(decoded)
          ..remove('approvalDecision');
        return copy.isEmpty ? '' : jsonEncode(copy);
      }
    } on Object {
      return '';
    }
    return '';
  }

  String _fallbackStageLabel(AgentRuntimeProgressStage stage) =>
      switch (stage) {
        AgentRuntimeProgressStage.planning => '正在规划任务',
        AgentRuntimeProgressStage.thinking => '正在整理下一步',
        AgentRuntimeProgressStage.readingFile => '正在读取文件',
        AgentRuntimeProgressStage.callingTool => '正在调用工具',
        AgentRuntimeProgressStage.writingFile => '正在写入文件',
        AgentRuntimeProgressStage.fileCreated => '文件已写入',
        AgentRuntimeProgressStage.validating => '正在校验结果',
        AgentRuntimeProgressStage.waitingForApproval => '等待用户批准',
        AgentRuntimeProgressStage.stepFailed => '步骤失败',
        AgentRuntimeProgressStage.stepRejected => '步骤已拒绝',
        AgentRuntimeProgressStage.toolCompleted => '工具步骤已完成',
      };

  String _safePublicText(String value) {
    var safe = value.trim();
    if (safe.isEmpty) return '';
    safe = const SearchSecretScanner().redact(safe, includeOpaqueTokens: true);
    safe = safe.replaceAll(RegExp(r'https?://[^\s,;）)]+'), '[外部地址]');
    safe = safe.replaceAll(
      RegExp(
        r'(?:(?:[A-Za-z]:[\\/])|/(?:Users|home|Volumes|private|tmp)/)[^\s,;）)]*',
      ),
      '[本地路径]',
    );
    return safe.length <= 4000 ? safe : '${safe.substring(0, 3999)}…';
  }

  String _safeApprovalDetail(ToolRequest request) {
    final rawPath = request.args['path'];
    if (rawPath is String && rawPath.trim().isNotEmpty) {
      final normalized = WorkspacePathGuard.normalizeToRelative(rawPath);
      final safePath =
          normalized.contains('..') ? normalized.split('/').last : normalized;
      return '等待批准 ${request.tool.wireName}：$safePath';
    }
    return '等待批准 ${request.tool.wireName}';
  }
}

extension<T> on Iterable<T> {
  Iterable<T> takeLast(int count) {
    if (count <= 0) return const [];
    final values = toList(growable: false);
    return values.length <= count
        ? values
        : values.sublist(values.length - count);
  }

  T? get firstOrNull => isEmpty ? null : first;
}

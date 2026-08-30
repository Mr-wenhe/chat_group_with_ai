import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/models/character_skill.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/media_attachment.dart';
import 'package:chat_group/core/models/tool_permission.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/features/agentic/agent_runtime.dart';
import 'package:chat_group/features/agentic/agent_attachment_context.dart';
import 'package:chat_group/features/agentic/character_skill_resolver.dart';
import 'package:chat_group/features/agentic/expert_skill_catalog.dart';
import 'package:chat_group/features/agentic/skill_download_service.dart';
import 'package:chat_group/features/agentic/tool_request.dart';
import 'package:chat_group/features/ai_governance/ai_request_gateway.dart';
import 'package:chat_group/features/ai_governance/ai_governance_store.dart';
import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/web_search/security/search_secret_scanner.dart';
import 'package:chat_group/features/work_mode/work_mode_policy.dart';
import 'package:chat_group/features/work_mode/work_mode_workspace_service.dart';
import 'package:chat_group/features/work_mode/work_approval_decision.dart';
import 'package:chat_group/features/work_mode/work_change_plan.dart';
import 'package:chat_group/features/work_mode/work_folder_grant_service.dart';
import 'package:chat_group/features/work_mode/work_resource_lock_manager.dart';
import 'package:chat_group/features/work_mode/work_task_coordinator.dart';
import 'package:chat_group/features/work_mode/work_task_error_sanitizer.dart';
import 'package:chat_group/features/work_mode/work_task_event.dart';
import 'package:chat_group/features/work_mode/work_task_event_store.dart';
import 'package:chat_group/features/work_mode/workspace_file_service.dart';
import 'package:chat_group/features/work_mode/workspace_mutation_service.dart';
import 'package:chat_group/features/work_mode/workspace_path_policy.dart';
import 'package:chat_group/features/work_mode/stage02_workspace_file_tool.dart';
import 'package:dio/dio.dart';

/// The app-scoped production runner for work-mode tasks.
///
/// It deliberately owns no Flutter state. A chat page submits a durable task;
/// this runner resolves the character/configuration, drives [AgentRuntime],
/// persists checkpoints and writes the final public message to Hive.
class DefaultWorkTaskRunner
    implements
        WorkTaskRunner,
        WorkTaskProgressReporter,
        WorkTaskResourceLockPlanner {
  final DatabaseService database;
  final WorkTaskEventStore eventStore;
  final ApiCredentialResolver credentials;
  final AiRequestGateway gateway;
  final WorkModeWorkspaceService workspaceService;
  final WorkFolderGrantService? folderGrantService;
  final WorkspaceFileService? workspaceFileService;
  final WorkspaceMutationService? mutationService;
  final WorkResourceLockManager? resourceLockManager;
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
    this.folderGrantService,
    this.workspaceFileService,
    this.mutationService,
    this.resourceLockManager,
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
    await folderGrantService?.load();
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
    final stage02Enabled =
        workspaceFileService != null && mutationService != null;
    if (!stage02Enabled) {
      // Work mode is an in-process capability. A missing Stage 02 service is
      // a startup/configuration error, never a reason to fall back to the old
      // localhost bridge and its weaker path/approval boundary.
      cancellationToken.cancel('工作模式文件服务未就绪');
      throw StateError('工作模式文件服务未就绪，请稍后重试。');
    }
    try {
      final workspace = await workspaceService.loadOrCreate(
        conversationId: task.groupId,
        isDirectChat: task.groupId.startsWith('dm:'),
      );

      final provider = _providerFor(config);
      final history = await _conversationHistory(task);
      final restoredRequests = _restoredRequests(task);
      final actionBase = task.actionCount;
      final restoredRequestCount = restoredRequests.length;
      final pendingRequest = _restorePendingRequestPaths(
        task,
        _pendingRequests[task.id] ??
            ToolRequest.fromJsonString(task.pendingToolRequestJson),
      );
      if (pendingRequest != null) _pendingRequests[task.id] = pendingRequest;
      // Folder consent is a path boundary, not a blanket tool approval. A
      // pending request that reached this checkpoint must be replayed through
      // the normal approval policy after the grant is available; otherwise a
      // restart would silently re-plan from scratch (or bypass a sensitive
      // read/write confirmation).
      final canReplayPending =
          pendingRequest != null && _canReplayPendingRequest(pendingRequest);
      final resumeAfterFolderGrant =
          canReplayPending && _hasFolderGrantCheckpoint(task);
      if (resumeAfterFolderGrant) {
        task.executionStateJson = _withoutFolderGrantCheckpoint(
          _withoutApprovalDecision(task.executionStateJson),
        );
        await _saveTask(task);
      } else if (!canReplayPending) {
        // Durable checkpoints intentionally redact write payloads and opaque
        // commands. Never execute such a redacted request after a restart:
        // doing so could turn a missing content field into an empty write.
        final cleaned = _withoutFolderGrantCheckpoint(
          _withoutApprovalDecision(task.executionStateJson),
        );
        if (cleaned != task.executionStateJson) {
          task.executionStateJson = cleaned;
          await _saveTask(task);
        }
      }
      final decision = resumeAfterFolderGrant || !canReplayPending
          ? null
          : _approvalDecision(task.executionStateJson);
      final approvalScope = resumeAfterFolderGrant
          ? null
          : canReplayPending
              ? _approvalScope(task.executionStateJson)
              : null;
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
        // Resolve relative tool paths inside this conversation's persisted
        // workspace. The path policy still enforces the app-wide grant root;
        // using the grant root here would silently flatten every conversation
        // into a shared directory.
        workspaceRoot: workspace.workDirPath,
        approvalDecision: decision,
        approvalScope: approvalScope,
      );
      final result = resumeAfterFolderGrant
          ? await runtime.resumeAfterFolderGrant(
              character: character,
              request: pendingRequest,
              userRequest: task.userRequest,
              priorExecutedRequests: restoredRequests,
              conversationHistory: history,
            )
          : canReplayPending && decision != null
              ? decision.permitsExecution
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
    required String workspaceRoot,
    required WorkChangeApprovalDecision? approvalDecision,
    required WorkApprovalScope? approvalScope,
  }) {
    final stage02 = workspaceFileService;
    final mutations = mutationService;
    if (stage02 == null || mutations == null) {
      throw StateError('工作模式文件服务未就绪，请稍后重试。');
    }
    final capability = gateway.capability(provider, config.modelName);
    final workspace = Stage02WorkspaceFileTool(
      files: stage02,
      mutations: mutations,
      pathPolicy: stage02.pathPolicy,
      task: task,
      workspaceRoot: workspaceRoot,
      approvalScope: approvalScope,
      approvalDecision: approvalDecision,
      resourceLockManager: resourceLockManager,
      allowImplicitScope: approvalDecision == null &&
          (folderGrantService?.settings.confirmOrdinaryWrites == false),
      onSensitiveRead: (path, operation) {
        unawaited(
          _record(
            task,
            WorkTaskEventKind.toolOutput,
            '已读取敏感文件',
            detail: operation,
            safeMetadata: {'path': path, 'sensitive': true},
          ),
        );
      },
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
      browserContextTool: null,
      skillCreateHandler: (args) => _createSkill(character, args),
      skillDownloadHandler: (args) => _downloadSkill(character, args),
      enableLocalFilePlanner: false,
      completionMaxRetries: 0,
      toolStepLimit: toolStepLimit,
      // Work mode performs only the local, lightweight validator by default.
      // A command-backed flutter analyze is enabled only when the user's
      // request explicitly asks for testing/building/analysis and the role
      // still has the command permission.
      allowCommandValidation: _requestsExplicitValidation(task.userRequest),
      onProgress: (progress) => _persistProgress(
        task,
        progress,
        cancellation: cancellation,
        actionBase: actionBase,
        restoredRequestCount: restoredRequestCount,
      ),
      contextIsDirectChat: task.groupId.startsWith('dm:'),
      approvalPolicy: (tool) {
        return WorkModePolicy.requiresApproval(tool);
      },
      requestApprovalPolicy: (request) async =>
          _requiresApprovalForRequest(task, request, approvalScope),
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

  @override
  Iterable<WorkResourceLockRequest> planResourceLocks(AgentTask task) {
    final raw = task.executionStateJson.trim();
    if (raw.isEmpty) return const <WorkResourceLockRequest>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const <WorkResourceLockRequest>[];
      final structured = decoded['resourceLocks'];
      if (structured is List) {
        final locks = <WorkResourceLockRequest>[];
        for (final item in structured) {
          if (item is! Map || item['path'] is! String) {
            throw const FormatException('资源锁计划格式无效');
          }
          final mode = switch (item['mode']) {
            'read' => WorkResourceLockMode.read,
            'write' => WorkResourceLockMode.write,
            'treeWrite' => WorkResourceLockMode.treeWrite,
            _ => throw const FormatException('资源锁模式无效'),
          };
          locks.add(WorkResourceLockRequest(
            path: item['path'] as String,
            mode: mode,
          ));
        }
        return locks;
      }
      final legacy = decoded['resourceLockPaths'];
      if (legacy is List) {
        return legacy
            .whereType<String>()
            .map(WorkResourceLockRequest.write)
            .toList(growable: false);
      }
      return const <WorkResourceLockRequest>[];
    } on FormatException {
      // A malformed durable plan must fail closed; the coordinator reports
      // the task as a resource-plan error instead of running without locks.
      rethrow;
    } on Object {
      return const <WorkResourceLockRequest>[];
    }
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
    if (pending != null &&
        (pending.tool == AgentToolName.workspacePatch ||
            pending.tool == AgentToolName.workspaceRename ||
            pending.tool == AgentToolName.workspaceDelete)) {
      final plan = await _approvalPlanForPending(task, pending);
      if (plan != null) {
        task.executionStateJson = _withApprovalCheckpoint(
          task.executionStateJson,
          plan,
        );
      } else {
        // A request whose path can no longer be resolved must not inherit an
        // older approval decision or scope. Keep the redacted pending request
        // for re-planning, but force the next run through a fresh approval.
        task.executionStateJson = _withoutApprovalDecision(
          task.executionStateJson,
        );
      }
    } else if (pending == null) {
      task.executionStateJson = _withoutApprovalDecision(
        task.executionStateJson,
      );
    } else {
      // Sensitive reads and path-grant checkpoints have no mutation plan, but
      // the redacted request must survive a restart so the same step can be
      // resumed after the user confirms it.
      task.executionStateJson = _withoutApprovalDecision(
        task.executionStateJson,
      );
    }
    // The approval plan is added after the first checkpoint fields are
    // assembled. Rebuild the structured summary now so a restart retains the
    // exact approved scope instead of only the redacted pending request.
    task.contextSummary = _buildContextSummary(
      task,
      progress.executedRequests,
      task.resultSummary,
    );
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
      final requestedPath = result.pendingToolRequest!.args['path'];
      if (requestedPath is String && _isAbsolutePath(requestedPath)) {
        task.executionStateJson = _withPendingRequestPath(
          task.executionStateJson,
          requestedPath,
        );
      }
      final requestedDestination =
          result.pendingToolRequest!.args['destinationPath'];
      if (requestedDestination is String &&
          _isAbsolutePath(requestedDestination)) {
        task.executionStateJson = _withPendingRequestDestinationPath(
          task.executionStateJson,
          requestedDestination,
        );
      }
      final blockedPath = result.toolResult?['requestedPath'];
      final folderRequestPath =
          result.toolResult?['requiresFolderGrant'] == true
              ? blockedPath is String && blockedPath.trim().isNotEmpty
                  ? blockedPath
                  : requestedPath is String && _isAbsolutePath(requestedPath)
                      ? requestedPath
                      : null
              : null;
      if (folderRequestPath != null) {
        task.executionStateJson = _withFolderRequestPath(
          task.executionStateJson,
          folderRequestPath,
        );
        task.executionStateJson = _withFolderGrantCheckpoint(
          task.executionStateJson,
        );
      } else {
        task.executionStateJson = _withoutFolderGrantCheckpoint(
          task.executionStateJson,
        );
      }
    } else {
      _pendingRequests.remove(task.id);
      task.executionStateJson = _withoutPendingRequestPath(
        task.executionStateJson,
      );
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

    // The progress callback may have persisted an approval scope before the
    // final runtime result reaches this method.  Recompute it here as well:
    // otherwise the assignment above would erase the durable scope at the
    // exact point where the task becomes waitingForApproval, forcing the
    // next process invocation to ask for approval without a verifiable plan.
    if (result.status == AgentRuntimeStatus.waitingForApproval &&
        result.pendingToolRequest != null &&
        (result.pendingToolRequest!.tool == AgentToolName.workspacePatch ||
            result.pendingToolRequest!.tool == AgentToolName.workspaceRename ||
            result.pendingToolRequest!.tool == AgentToolName.workspaceDelete)) {
      final plan = await _approvalPlanForPending(
        task,
        result.pendingToolRequest!,
      );
      if (plan != null) {
        task.executionStateJson = _withApprovalCheckpoint(
          task.executionStateJson,
          plan,
        );
      }
    }
    // Keep the final checkpoint in sync with the plan computed above. This is
    // what makes approved scope and validation evidence available to a later
    // follow-up turn after the current run has been persisted.
    task.contextSummary = _buildContextSummary(
      task,
      result.executedToolRequests,
      result.message,
    );

    if (result.status == AgentRuntimeStatus.waitingForApproval &&
        result.pendingToolRequest != null) {
      task
        ..status = AgentTaskStatus.waitingForApproval
        ..lastError = '';
      task.contextSummary = _buildContextSummary(
        task,
        result.executedToolRequests,
        result.message,
      );
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
      task.contextSummary = _buildContextSummary(
        task,
        result.executedToolRequests,
        result.message,
      );
      await _saveTask(task);
      await _appendPublicMessage(
        task,
        character,
        result.message,
        toolResult: result.toolResult,
      );
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
    task.contextSummary = _buildContextSummary(
      task,
      result.executedToolRequests,
      result.message,
    );
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
    String content, {
    Map<String, dynamic>? toolResult,
  }) async {
    final safe = _safePublicText(content);
    if (safe.isEmpty) return;
    List<MediaAttachment>? media;
    final resultPath = toolResult?['path'];
    if (toolResult?['ok'] == true &&
        toolResult?['sensitive'] != true &&
        toolResult?['validation'] is Map &&
        toolResult?['validation']['valid'] == true &&
        resultPath is String) {
      try {
        final artifact = await _safeArtifactForAttachment(resultPath);
        if (artifact != null) {
          final stat = await artifact.stat();
          if (stat.type == FileSystemEntityType.file &&
              stat.size <= 50 * 1024 * 1024) {
            media = [
              await database.copyToMedia(
                artifact,
                'file',
                fileName: _fileName(resultPath),
              ),
            ];
          }
        }
      } on Object {
        // The text result remains authoritative when attachment copying fails.
      }
    }
    await database.persistMessage(Message(
      groupId: task.groupId,
      senderId: character.id,
      senderType: 'ai',
      content: safe,
      media: media,
    ));
  }

  /// Re-validates a tool-reported artifact immediately before copying it into
  /// app media. The tool result is untrusted after the filesystem operation:
  /// a symlink swap or a future adapter bug must not exfiltrate an outside
  /// file through the public attachment channel.
  Future<File?> _safeArtifactForAttachment(String rawPath) async {
    final files = workspaceFileService;
    if (files == null) return null;
    try {
      final resolved = await files.pathPolicy.resolveExisting(rawPath);
      if (!resolved.isFile || resolved.wasSymbolicLink) return null;
      final requested = WorkspacePathPolicy.normalizePath(
        rawPath,
        isWindows: files.pathPolicy.isWindows,
      );
      final canonical = WorkspacePathPolicy.normalizePath(
        resolved.path,
        isWindows: files.pathPolicy.isWindows,
      );
      if (requested != canonical) return null;
      return File(canonical);
    } on Object {
      return null;
    }
  }

  String _fileName(String path) {
    final normalized = path.replaceAll('\\', '/');
    final slash = normalized.lastIndexOf('/');
    return slash < 0 ? normalized : normalized.substring(slash + 1);
  }

  Future<void> _record(
    AgentTask task,
    WorkTaskEventKind kind,
    String title, {
    String detail = '',
    Map<String, Object?>? safeMetadata,
  }) async {
    try {
      await eventStore.append(
        taskId: task.id,
        kind: kind,
        title: title,
        detail: detail,
        safeMetadata: safeMetadata,
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

  bool _requestsExplicitValidation(String request) {
    final hasValidationIntent = RegExp(
      r'(flutter\s+(?:test|build|analyze)|\b(?:test|build|analyze|compile)\b|'
      r'运行(?:测试|构建|编译)|执行(?:测试|构建|编译)|编译)',
      caseSensitive: false,
    ).hasMatch(request);
    return hasValidationIntent && !_hasValidationNegation(request);
  }

  bool _hasValidationNegation(String request) => RegExp(
        r'(?:不要|无需|不需要|不用|不必|不运行|不执行|不做|先不)\s*'
        r'(?:再|去|进行|执行|跑|运行)?\s*(?:flutter\s+)?'
        r'(?:test|build|analyze|compile|测试|构建|编译|检查|验证)',
        caseSensitive: false,
      ).hasMatch(request);

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
    return AgentAttachmentContext.buildHistory(
      messages: messages.takeLast(24).toList(growable: false),
      currentUserRequest: task.userRequest,
    );
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
    final previous = _decodeSummaryMap(task.contextSummary);
    final previousGoal = _summaryString(previous['goal']);
    final goal = previousGoal ?? task.userRequest;
    final currentRequest = _boundedCheckpointText(task.userRequest);
    final previousLatest = _summaryString(previous['latestRequest']);
    final revisions = <String>[
      ..._summaryStrings(previous['userRevisions']),
      if (previousLatest != null &&
          previousLatest.trim() != task.userRequest.trim())
        previousLatest,
    ];
    final pending = ToolRequest.fromJsonString(task.pendingToolRequestJson);
    var artifactPaths = _summaryArtifactPaths(task, requests, previous);
    if (pending != null) {
      artifactPaths = _deduplicateStrings(
        <String>[
          ...artifactPaths,
          for (final key in const <String>['path', 'destinationPath'])
            if (pending.args[key] is String) pending.args[key] as String,
        ].map(_safeSummaryPath),
        max: 32,
      );
    }
    final actions = <Map<String, dynamic>>[
      ..._summaryActionMaps(previous['completedActions']),
      ...requests.map(_safeRequestSummary),
    ];
    _deduplicateMaps(actions, max: 32);

    final sideEffects = <Map<String, dynamic>>[
      ..._summaryActionMaps(previous['sideEffects']),
      ...requests.where(_isMutationRequest).map(_safeRequestSummary),
    ];
    _deduplicateMaps(sideEffects, max: 32);

    final unresolved = <Map<String, dynamic>>[
      ..._summaryActionMaps(previous['unresolved']),
    ];
    if (pending != null) {
      unresolved.add(_safeRequestSummary(pending));
      _deduplicateMaps(unresolved, max: 16);
    } else if (task.pendingToolRequestJson.trim().isEmpty &&
        task.status == AgentTaskStatus.completed) {
      // A completed run has resolved its prior approval/clarification item.
      unresolved.clear();
    }

    final errors = <String>[
      ..._summaryStrings(previous['errors']),
      if (task.lastError.trim().isNotEmpty)
        _boundedCheckpointText(task.lastError),
    ];
    final validationEvidence = <String>[
      ..._summaryStrings(previous['validationEvidence']),
    ];
    if (_containsValidationEvidence(lastResult)) {
      validationEvidence.add(_boundedCheckpointText(lastResult));
    }

    final approvedScope = _summaryApprovalScope(
      _decodeSummaryMap(task.executionStateJson)['approvalScope'] ??
          previous['approvedScope'],
    );
    final roleHandoff = _summaryRoleHandoff(task, previous['roleHandoff']);
    final target = _summaryString(previous['target']) ??
        (artifactPaths.isEmpty ? '' : artifactPaths.first);
    final acceptanceCriteria =
        _summaryString(previous['acceptanceCriteria']) ?? task.plan;

    return jsonEncode(<String, dynamic>{
      'schemaVersion': 2,
      'goal': _boundedCheckpointText(goal),
      'target': _safeSummaryPath(target),
      'acceptanceCriteria': _boundedCheckpointText(acceptanceCriteria),
      'latestRequest': currentRequest,
      'userRevisions': _deduplicateStrings(revisions, max: 16),
      'roleHandoff': roleHandoff,
      'completedActions': actions,
      'sideEffects': sideEffects,
      'artifactPaths': artifactPaths,
      'approvedScope': approvedScope,
      'unresolved': unresolved,
      'validationEvidence': _deduplicateStrings(validationEvidence, max: 16),
      'errors': _deduplicateStrings(errors, max: 16),
      'retries': _deduplicateStrings(
        _summaryStrings(previous['retries']),
        max: 16,
      ),
      'lastResult': _boundedCheckpointText(
        lastResult.trim().isEmpty
            ? (_summaryString(previous['lastResult']) ?? '')
            : lastResult,
      ),
    });
  }

  Map<String, dynamic> _decodeSummaryMap(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } on Object {
      // Legacy summaries were plain text. They remain available as the
      // current request/result, but cannot be trusted as structured fields.
    }
    return <String, dynamic>{};
  }

  String? _summaryString(Object? value) {
    if (value is! String || value.trim().isEmpty) return null;
    return _boundedCheckpointText(value);
  }

  List<String> _summaryStrings(Object? value) {
    if (value is! List) return const <String>[];
    return value
        .whereType<String>()
        .map(_boundedCheckpointText)
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
  }

  List<String> _summaryArtifactPaths(
    AgentTask task,
    Iterable<ToolRequest> requests,
    Map<String, dynamic> previous,
  ) {
    final paths = <String>[
      ..._summaryStrings(previous['artifactPaths']),
      ...task.lastArtifactPaths,
    ];
    for (final request in requests) {
      for (final key in const <String>['path', 'destinationPath']) {
        final value = request.args[key];
        if (value is String && value.trim().isNotEmpty) paths.add(value);
      }
    }
    return _deduplicateStrings(
      paths.map(_safeSummaryPath),
      max: 32,
    );
  }

  String _safeSummaryPath(String raw) {
    final value = raw.trim();
    if (value.isEmpty || value.contains(RegExp(r'[\u0000-\u001f\u007f]'))) {
      return '';
    }
    final redacted = const SearchSecretScanner().redact(
      value.replaceAll('\\', '/'),
      includeOpaqueTokens: true,
    );
    return redacted.length <= 1024
        ? redacted
        : '${redacted.substring(0, 1023)}…';
  }

  List<Map<String, dynamic>> _summaryActionMaps(Object? value) {
    if (value is! List) return <Map<String, dynamic>>[];
    final actions = <Map<String, dynamic>>[];
    for (final item in value) {
      if (item is! Map) continue;
      try {
        final checkpoint = safeToolRequestCheckpointJson(jsonEncode(item));
        final decoded = jsonDecode(checkpoint);
        if (decoded is Map) {
          actions.add(Map<String, dynamic>.from(decoded));
        }
      } on Object {
        // Ignore malformed legacy entries instead of copying untrusted data.
      }
    }
    return actions;
  }

  void _deduplicateMaps(
    List<Map<String, dynamic>> values, {
    required int max,
  }) {
    final seen = <String>{};
    values.removeWhere((value) {
      final key = jsonEncode(value);
      if (!seen.add(key)) return true;
      return false;
    });
    if (values.length > max) values.removeRange(max, values.length);
  }

  List<String> _deduplicateStrings(Iterable<String> values,
      {required int max}) {
    final result = <String>[];
    final seen = <String>{};
    for (final value in values) {
      final trimmed = value.trim();
      if (trimmed.isEmpty || !seen.add(trimmed)) continue;
      result.add(trimmed);
      if (result.length == max) break;
    }
    return result;
  }

  bool _isMutationRequest(ToolRequest request) =>
      request.tool == AgentToolName.workspacePatch ||
      request.tool == AgentToolName.workspaceRename ||
      request.tool == AgentToolName.workspaceDelete ||
      request.tool == AgentToolName.commandRun;

  bool _containsValidationEvidence(String value) => RegExp(
        r'(?:校验|验证|检查|测试|构建|lint|analy[sz]e|build|test|passed|通过|失败)',
        caseSensitive: false,
      ).hasMatch(value);

  Map<String, dynamic>? _summaryApprovalScope(Object? value) {
    if (value is! Map || value['entries'] is! List) return null;
    final entries = <Map<String, dynamic>>[];
    for (final item in value['entries'] as List) {
      if (item is! Map || item['path'] is! String) continue;
      final path = _safeSummaryPath(item['path'] as String);
      if (path.isEmpty) continue;
      final actions = item['actions'] is List
          ? (item['actions'] as List)
              .whereType<String>()
              .map(_boundedCheckpointText)
              .where((action) => action.isNotEmpty)
              .toList(growable: false)
          : const <String>[];
      entries.add({
        'path': path,
        if (item['kind'] is String)
          'kind': _boundedCheckpointText(item['kind'] as String),
        'actions': actions,
      });
    }
    if (entries.isEmpty) return null;
    return <String, dynamic>{
      if (value['taskId'] is String)
        'taskId': _boundedCheckpointText(value['taskId'] as String),
      'entries': entries.take(32).toList(growable: false),
    };
  }

  Map<String, dynamic> _summaryRoleHandoff(
    AgentTask task,
    Object? previousValue,
  ) {
    final previous = previousValue is Map
        ? Map<String, dynamic>.from(previousValue)
        : const <String, dynamic>{};
    final assigned = _deduplicateStrings(
      <String>[
        ..._summaryStrings(previous['assignedCharacterIds']),
        ...task.assignedCharacterIds
      ],
      max: 16,
    );
    if (!assigned.contains(task.characterId)) assigned.add(task.characterId);
    final history = <String>[..._summaryStrings(previous['history'])];
    final previousCharacter = _summaryString(previous['currentCharacterId']);
    if (previousCharacter != null && previousCharacter != task.characterId) {
      history.add(previousCharacter);
    }
    return <String, dynamic>{
      'currentCharacterId': _boundedCheckpointText(task.characterId),
      'assignedCharacterIds': assigned,
      'history': _deduplicateStrings(history, max: 16),
    };
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

  WorkChangeApprovalDecision? _approvalDecision(String raw) {
    try {
      final decoded = jsonDecode(raw);
      final value = decoded is Map ? decoded['approvalDecision'] : null;
      return WorkChangeApprovalDecision.fromWire(value);
    } on Object {
      return null;
    }
  }

  WorkApprovalScope? _approvalScope(String raw) {
    try {
      final decoded = jsonDecode(raw);
      final value = decoded is Map ? decoded['approvalScope'] : null;
      if (value is! Map) return null;
      return WorkApprovalScope.fromJson(Map<String, dynamic>.from(value));
    } on Object {
      return null;
    }
  }

  Future<bool> _requiresApprovalForRequest(
    AgentTask task,
    ToolRequest request,
    WorkApprovalScope? scope,
  ) async {
    if (request.tool == AgentToolName.workspaceList ||
        request.tool == AgentToolName.workspaceRead ||
        request.tool == AgentToolName.workspaceSearch) {
      final rawPath = request.args['path']?.toString() ?? '';
      return workspaceFileService?.isSensitivePath(rawPath) == true;
    }
    if (request.tool == AgentToolName.workspacePatch ||
        request.tool == AgentToolName.workspaceRename ||
        request.tool == AgentToolName.workspaceDelete) {
      final sourcePath = request.args['path']?.toString() ?? '';
      final destinationPath = request.args['destinationPath']?.toString() ?? '';
      final sensitivePath = workspaceFileService?.isSensitivePath(sourcePath) ==
              true ||
          (request.tool == AgentToolName.workspaceRename &&
              workspaceFileService?.isSensitivePath(destinationPath) == true);
      if (sensitivePath) {
        // The ordinary-write toggle never suppresses a mutation whose target
        // or rename destination could expose credentials or private keys.
        return true;
      }
      final plan = await _approvalPlanForPending(task, request);
      if (plan == null) return true;
      final policy = WorkChangePolicy.evaluate(
        plan: plan,
        settings: WorkChangePolicySettings(
          confirmOrdinaryWrites:
              folderGrantService?.settings.confirmOrdinaryWrites ?? true,
        ),
        scope: scope,
      );
      return policy.requiresPrompt;
    }
    return WorkModePolicy.requiresApproval(request.tool);
  }

  Future<WorkChangePlan?> _approvalPlanForPending(
    AgentTask task,
    ToolRequest request,
  ) async {
    if (request.tool != AgentToolName.workspacePatch &&
        request.tool != AgentToolName.workspaceRename &&
        request.tool != AgentToolName.workspaceDelete) {
      return null;
    }
    final rawPath = request.args['path'];
    if (rawPath is! String || rawPath.trim().isEmpty) return null;
    final files = workspaceFileService;
    final mutations = mutationService;
    if (files == null || mutations == null) return null;
    try {
      final workspace = await workspaceService.loadOrCreate(
        conversationId: task.groupId,
        isDirectChat: task.groupId.startsWith('dm:'),
      );
      // Relative requests are scoped to the conversation directory. The
      // WorkspacePathPolicy below remains the authoritative app-wide grant
      // boundary for both relative and absolute paths.
      final workspaceRoot = workspace.workDirPath;
      var absolute = _absoluteWorkspacePath(
        rawPath,
        workspaceRoot,
        files.pathPolicy.isWindows,
      );
      final patchRequest = request.tool == AgentToolName.workspacePatch &&
          request.args['expectedSha256'] is String &&
          request.args['expectedFragment'] is String &&
          request.args['replacement'] is String;
      // AgentRuntime stores text-only artifacts as Markdown when a model asks
      // for a binary document. The approval plan must describe that final
      // path, otherwise the post-approval Stage 02 scope would reject the
      // deliberately downgraded write as a different file.
      if (request.tool == AgentToolName.workspacePatch && !patchRequest) {
        absolute = _rewriteBinaryArtifactPath(absolute);
      }
      final resolved =
          await files.pathPolicy.resolve(absolute, allowMissing: true);
      if (resolved.exists && !resolved.isFile) return null;
      final action = switch (request.tool) {
        AgentToolName.workspaceDelete => WorkChangeActionType.delete,
        AgentToolName.workspaceRename => WorkChangeActionType.rename,
        AgentToolName.workspacePatch when patchRequest =>
          WorkChangeActionType.patch,
        _ => resolved.exists
            ? WorkChangeActionType.modify
            : WorkChangeActionType.create,
      };
      final exactPaths = <String>[resolved.path];
      final affectedDirectories = <String>{resolved.authorizedRoot};
      if (request.tool == AgentToolName.workspaceRename) {
        final destinationRaw = request.args['destinationPath'];
        if (destinationRaw is! String || destinationRaw.trim().isEmpty) {
          return null;
        }
        final destination = await files.pathPolicy.resolve(
          _absoluteWorkspacePath(
            destinationRaw,
            workspaceRoot,
            files.pathPolicy.isWindows,
          ),
          allowMissing: true,
        );
        exactPaths.add(destination.path);
        affectedDirectories.add(destination.authorizedRoot);
      }
      final content = request.args['content'];
      final replacement = request.args['replacement'];
      final estimatedBytes = replacement is String
          ? utf8.encode(replacement).length
          : content is String
              ? utf8.encode(content).length
              : 0;
      var plan = WorkChangePlan(
        taskId: task.id,
        actionType: action,
        exactPaths: exactPaths,
        knownAffectedDirectories: affectedDirectories.toList(growable: false),
        estimatedBytes: estimatedBytes,
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
      final availability = mutations.snapshotPort;
      if (availability
          case final WorkspaceMutationSnapshotAvailabilityPort checker) {
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
      // A scope is persisted only after it has been resolved against the
      // current grant. If resolution fails, the next run must ask again.
      return null;
    }
  }

  String _absoluteWorkspacePath(
    String rawPath,
    String workspaceRoot,
    bool isWindows,
  ) {
    final value = rawPath.trim();
    if (value
        .replaceAll('\\', '/')
        .split('/')
        .any((segment) => segment == '..')) {
      throw const WorkspacePathException(
        WorkspacePathErrorKind.invalidPath,
        '路径不能包含 ..。',
      );
    }
    final absolute = value.startsWith('/') ||
        value.startsWith('\\') ||
        RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value);
    if (absolute) {
      return WorkspacePathPolicy.normalizePath(value, isWindows: isWindows);
    }
    return WorkspacePathPolicy.normalizePath(
      '${workspaceRoot.replaceAll('\\', '/')}/$value',
      isWindows: isWindows,
    );
  }

  String _rewriteBinaryArtifactPath(String path) {
    final slashIndex = path.lastIndexOf('/');
    final fileName = slashIndex >= 0 ? path.substring(slashIndex + 1) : path;
    final extensionIndex = fileName.lastIndexOf('.');
    if (extensionIndex <= 0) return path;
    final extension = fileName.substring(extensionIndex + 1).toLowerCase();
    if (!_binaryArtifactExtensions.contains(extension)) return path;
    final directory = slashIndex >= 0 ? path.substring(0, slashIndex + 1) : '';
    return '$directory${fileName.substring(0, extensionIndex)}.md';
  }

  static const Set<String> _binaryArtifactExtensions = {
    'pdf',
    'doc',
    'docx',
    'xls',
    'xlsx',
    'ppt',
    'pptx',
    'zip',
    'png',
    'jpg',
    'jpeg',
  };

  String _withApprovalCheckpoint(String raw, WorkChangePlan plan) {
    final checkpoint = <String, dynamic>{
      'approvalPlan': plan.toJson(),
      // Descriptive until an explicit decision is recorded. Stage 02 still
      // requires the decision and revalidates this scope before mutation.
      'approvalScope': WorkApprovalScope.fromPlan(plan).toJson(),
    };
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final copy = Map<String, dynamic>.from(decoded)
          // Approval decisions are one-shot. A new pending plan must never
          // inherit the decision that authorized the preceding tool call.
          ..remove('approvalDecision')
          ..remove('approvalScope');
        return jsonEncode({...copy, ...checkpoint});
      }
    } on Object {
      // Replace malformed execution metadata with the safe plan checkpoint.
    }
    return jsonEncode(checkpoint);
  }

  String _withFolderRequestPath(String raw, String path) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return jsonEncode({
          ...Map<String, dynamic>.from(decoded),
          'folderRequestPath': path.trim(),
        });
      }
    } on Object {
      // Replace malformed metadata with a minimal path checkpoint.
    }
    return jsonEncode(<String, String>{'folderRequestPath': path.trim()});
  }

  String _withPendingRequestPath(String raw, String path) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return jsonEncode({
          ...Map<String, dynamic>.from(decoded),
          'pendingRequestPath': path.trim(),
        });
      }
    } on Object {
      // Replace malformed metadata with a minimal path checkpoint.
    }
    return jsonEncode(<String, String>{'pendingRequestPath': path.trim()});
  }

  String _withoutPendingRequestPath(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final copy = Map<String, dynamic>.from(decoded)
          ..remove('pendingRequestPath');
        copy.remove('pendingRequestDestinationPath');
        return copy.isEmpty ? '' : jsonEncode(copy);
      }
    } on Object {
      return '';
    }
    return raw;
  }

  String _withPendingRequestDestinationPath(String raw, String path) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return jsonEncode({
          ...Map<String, dynamic>.from(decoded),
          'pendingRequestDestinationPath': path.trim(),
        });
      }
    } on Object {
      // Replace malformed metadata with a minimal safe checkpoint.
    }
    return jsonEncode(<String, String>{
      'pendingRequestDestinationPath': path.trim(),
    });
  }

  bool _hasFolderGrantCheckpoint(AgentTask task) {
    try {
      final decoded = jsonDecode(task.executionStateJson);
      return decoded is Map && decoded['folderGrantPending'] == true;
    } on Object {
      return false;
    }
  }

  bool _canReplayPendingRequest(ToolRequest? request) {
    if (request == null) return false;
    final args = request.args;
    return switch (request.tool) {
      AgentToolName.workspaceList => true,
      AgentToolName.workspaceRead => _hasNonEmptyString(args['path']),
      AgentToolName.workspaceSearch =>
        _hasNonEmptyString(args['path']) && _hasNonEmptyString(args['query']),
      AgentToolName.workspacePatch => args['content'] is String ||
          (_hasNonEmptyString(args['expectedSha256']) &&
              _hasNonEmptyString(args['expectedFragment']) &&
              args['replacement'] is String),
      AgentToolName.workspaceRename => _hasNonEmptyString(args['path']) &&
          _hasNonEmptyString(args['destinationPath']),
      AgentToolName.workspaceDelete => _hasNonEmptyString(args['path']),
      // The Stage 02 runtime never executes commands, but opaque command
      // payloads are still unsafe to reconstruct from a redacted checkpoint.
      AgentToolName.commandRun => _hasNonEmptyString(args['command']),
      AgentToolName.browserContext => true,
      AgentToolName.skillCreate || AgentToolName.skillDownload => false,
    };
  }

  bool _hasNonEmptyString(Object? value) =>
      value is String && value.trim().isNotEmpty;

  String _withFolderGrantCheckpoint(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return jsonEncode({
          ...Map<String, dynamic>.from(decoded),
          'folderGrantPending': true,
        });
      }
    } on Object {
      // Replace malformed metadata with a minimal safe checkpoint.
    }
    return jsonEncode(<String, dynamic>{'folderGrantPending': true});
  }

  String _withoutFolderGrantCheckpoint(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final copy = Map<String, dynamic>.from(decoded)
          ..remove('folderGrantPending');
        return copy.isEmpty ? '' : jsonEncode(copy);
      }
    } on Object {
      return '';
    }
    return raw;
  }

  ToolRequest? _restorePendingRequestPaths(
    AgentTask task,
    ToolRequest? request,
  ) {
    if (request == null) return null;
    final checkpoint = _decodeExecutionCheckpoint(task.executionStateJson);
    if (checkpoint == null) return request;
    final args = Map<String, dynamic>.from(request.args);
    final exactPaths = _checkpointExactPaths(checkpoint);
    final folderRequestPath = checkpoint['folderRequestPath'];
    final pendingRequestPath = checkpoint['pendingRequestPath'];
    final path = exactPaths.isNotEmpty && _isAbsolutePath(exactPaths.first)
        ? exactPaths.first
        : folderRequestPath is String && _isAbsolutePath(folderRequestPath)
            ? folderRequestPath
            : pendingRequestPath is String &&
                    _isAbsolutePath(pendingRequestPath)
                ? pendingRequestPath
                : null;
    if (path != null) args['path'] = path;
    if (request.tool == AgentToolName.workspaceRename &&
        exactPaths.length > 1 &&
        _isAbsolutePath(exactPaths[1])) {
      args['destinationPath'] = exactPaths[1];
    } else if (request.tool == AgentToolName.workspaceRename) {
      final pendingDestination = checkpoint['pendingRequestDestinationPath'];
      if (pendingDestination is String && _isAbsolutePath(pendingDestination)) {
        args['destinationPath'] = pendingDestination;
      }
    }
    return ToolRequest(tool: request.tool, reason: request.reason, args: args);
  }

  Map<String, dynamic>? _decodeExecutionCheckpoint(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } on Object {
      // A malformed checkpoint must not alter the original pending request.
    }
    return null;
  }

  List<String> _checkpointExactPaths(Map<String, dynamic> checkpoint) {
    final plan = checkpoint['approvalPlan'];
    if (plan is! Map) return const <String>[];
    final rawPaths = plan['exactPaths'];
    if (rawPaths is! List) return const <String>[];
    return rawPaths.whereType<String>().toList(growable: false);
  }

  bool _isAbsolutePath(String value) {
    final path = value.trim();
    return path.startsWith('/') ||
        path.startsWith('\\') ||
        RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);
  }

  String _withoutApprovalDecision(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final copy = Map<String, dynamic>.from(decoded)
          ..remove('approvalDecision');
        copy.remove('approvalScope');
        copy.remove('approvalPlan');
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
        r'(?:(?:[A-Za-z]:[\\/])|(?:\\\\|//)|/(?:Users|home|Volumes|private|tmp|var|etc|usr|opt|bin|sbin|Applications|System|Library|Desktop|Documents|Downloads)/)[^\s,;）)]*',
      ),
      '[本地路径]',
    );
    return safe.length <= 4000 ? safe : '${safe.substring(0, 3999)}…';
  }

  String _safeApprovalDetail(ToolRequest request) {
    final rawPath = request.args['path'];
    if (rawPath is String && rawPath.trim().isNotEmpty) {
      final normalized = rawPath.trim().replaceAll('\\', '/');
      final isAbsolute = normalized.startsWith('/') ||
          RegExp(r'^[A-Za-z]:/').hasMatch(normalized);
      final safePath = isAbsolute || normalized.contains('..')
          ? normalized.split('/').last
          : normalized;
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

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
import 'package:chat_group/features/work_mode/work_artifact_delivery_notice.dart';
import 'package:chat_group/features/work_mode/work_approval_decision.dart';
import 'package:chat_group/features/work_mode/work_approval_fingerprint.dart';
import 'package:chat_group/features/work_mode/work_change_plan.dart';
import 'package:chat_group/features/work_mode/work_command_runner.dart';
import 'package:chat_group/features/work_mode/work_context_boundary.dart';
import 'package:chat_group/features/work_mode/work_context_builder.dart';
import 'package:chat_group/features/work_mode/work_discussion_state.dart';
import 'package:chat_group/features/work_mode/work_folder_grant_service.dart';
import 'package:chat_group/features/work_mode/work_handoff_state.dart';
import 'package:chat_group/features/work_mode/work_mode_policy.dart';
import 'package:chat_group/features/work_mode/work_mode_directory_service.dart';
import 'package:chat_group/features/work_mode/work_mode_workspace_service.dart';
import 'package:chat_group/features/work_mode/work_document_tool.dart';
import 'package:chat_group/features/work_mode/work_failure.dart';
import 'package:chat_group/features/work_mode/work_public_update_stream.dart';
import 'package:chat_group/features/work_mode/work_resource_lock_manager.dart';
import 'package:chat_group/features/work_mode/work_role_router.dart';
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
import 'package:chat_group/features/work_mode/weather_forecast_service.dart';
import 'package:chat_group/features/web_search/security/search_secret_scanner.dart';
import 'package:dio/dio.dart';
import 'package:open_filex/open_filex.dart';

part 'default_work_task_runner_execution.dart';
part 'default_work_task_runner_model_io.dart';
part 'default_work_task_runner_tools.dart';
part 'default_work_task_runner_mutation_policy.dart';
part 'default_work_task_runner_file_policy.dart';
part 'default_work_task_runner_command_execution.dart';
part 'default_work_task_runner_context.dart';
part 'default_work_task_runner_delivery.dart';
part 'default_work_task_runner_attachments.dart';

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
        WorkTaskDiscussionExecutorValidator,
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

  /// Resolves explicit desktop destinations before the workspace service is
  /// asked to bind a task. Keeping this dependency injectable lets the real
  /// runner be exercised against an isolated approved root without ever
  /// redirecting an acceptance test into the operator's desktop.
  final WorkModeDirectoryService directoryService;
  final WeatherForecastService? weatherForecastService;
  final Future<MediaAttachment> Function(
    File source,
    String type, {
    String? fileName,
  })? mediaCopier;

  /// Opens a verified HTML artifact in the platform's default browser after
  /// successful delivery. Tests can leave this disabled to avoid UI side
  /// effects; the production provider enables it.
  final bool autoOpenHtml;

  /// 一次模型请求的**总**时限：它管的是"这一轮请求的整体耗时"。
  final Duration modelCompletionTimeout;

  /// 首字节停滞时限：请求发出后这么久还没收到任何字符，判定为上游停滞。
  ///
  /// 与 [modelCompletionTimeout] 分开是刻意的。总时限**不能**缩短——它必须同时
  /// 容下"生成很慢但正在输出"的请求，缩短会砍掉正常的那一类（既有决定）。
  /// 而"一个字符都没有"是另一回事：此刻不存在任何已生成内容，取消并重试不会
  /// 丢掉任何工作。这正是此前缺的那个判别器。
  ///
  /// 现场证据（2026-09-30，`sensenova-6.8-flash-lite`）：一个 16.8k 输入的请求
  /// 连续三次整整 300 秒零输出——事件日志里那三段窗口没有任何 token 事件——客户端
  /// 每次都白等到总时限；三次空等占掉整轮 23 分钟里的 15 分钟。同一天命中快路径的
  /// 请求，首段输出只要 7～10 秒。
  ///
  /// 取值必须大于正常模型的首字节耗时，否则会把"慢启动但能成"的请求误杀成必败。
  /// 现成数据里没有首字节分布（补 `firstTokenMs` 正是为了拿到它），所以 180 秒是
  /// 一个保守起点：高于当天所有已观测到的首段输出，同时把最坏情况从 300 秒压到
  /// 180 秒。真实分布到手后再校准这个值。
  final Duration modelFirstTokenTimeout;

  /// 生效的首字节停滞时限：不会晚于总时限。
  ///
  /// 调用方把总时限设得更短时（测试常这么做），停滞退化成与总时限同点触发，而
  /// 不是让构造失败——否则每个只关心总时限的调用方都得额外声明一个它并不关心
  /// 的值。钳制而不是断言，保证"停滞归因不会永远被总时限盖住"这条性质永远成立。
  Duration get effectiveFirstTokenTimeout =>
      modelFirstTokenTimeout < modelCompletionTimeout
          ? modelFirstTokenTimeout
          : modelCompletionTimeout;

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
    this.directoryService = const WorkModeDirectoryService(),
    this.weatherForecastService,
    this.mediaCopier,
    this.autoOpenHtml = false,
    // Large single-file artifacts may need several minutes for the model to
    // produce a tool plan and content; keep the deadline bounded but above the
    // previous 120s ceiling that aborted valid HTML generations.
    this.modelCompletionTimeout = const Duration(seconds: 300),
    this.modelFirstTokenTimeout = const Duration(seconds: 180),
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
  void setTaskUpdateSink(void Function(AgentTask task) sink) =>
      _implSetTaskUpdateSink(sink);

  @override
  void setTaskCheckpointSink(Future<void> Function(AgentTask task) sink) =>
      _implSetTaskCheckpointSink(sink);

  @override
  Future<void> rebindWorkspace(AgentTask task, String grantedPath) =>
      _implRebindWorkspace(task, grantedPath);

  @override
  Future<void> reportFailure(AgentTask task, WorkFailure failure) =>
      _implReportFailure(task, failure);

  @override
  bool supportsVisionModel(String characterId) =>
      _implSupportsVisionModel(characterId);

  @override
  bool supportsVisionModelForTask(AgentTask task, String characterId) =>
      _implSupportsVisionModelForTask(task, characterId);

  @override
  Future<String?> validateDiscussionExecutor(
    AgentTask task,
    WorkDiscussionState state,
  ) =>
      _implValidateDiscussionExecutor(task, state);

  @override
  Future<void> run(
    AgentTask task,
    WorkTaskCancellation cancellation,
  ) =>
      _implRun(task, cancellation);

  @override
  Iterable<WorkResourceLockRequest> planResourceLocks(AgentTask task) =>
      _implPlanResourceLocks(task);

  @override
  Future<WorkCommandResult> installMissingTool(
    AgentTask task,
    WorkTaskCancellation cancellation,
  ) =>
      _implInstallMissingTool(task, cancellation);

  static const int _maxArtifactAttachments = 12;
  static const int _maxAttachedArtifactBytes = 50 * 1024 * 1024;
  static const int _maxArtifactBundleBytes = 200 * 1024 * 1024;

  /// Bounds the scan for files a command produced itself: how many deliverables
  /// it may report, and how many directory entries the before/after snapshots
  /// may inspect to find them.
  /// ponytail: discovery caps at 4000 entries; add a filesystem watcher or
  /// persistent index only if workspaces exceed that scan limit in practice.
  static const int _maxObservedArtifacts = 64;
  static const int _maxObservedEntries = 4000;
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

class _ArtifactDeliveryResult {
  final bool succeeded;
  final String message;
  final String? messageId;
  final bool retryWithExistingArtifact;

  const _ArtifactDeliveryResult.success({this.messageId})
      : succeeded = true,
        message = '',
        retryWithExistingArtifact = false;

  const _ArtifactDeliveryResult.failure(
    this.message, {
    this.messageId,
    this.retryWithExistingArtifact = false,
  }) : succeeded = false;
}

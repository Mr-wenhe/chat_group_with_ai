import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:chat_group/core/retry_handler.dart';
import 'package:chat_group/services/chat_api_service.dart';
import 'work_candidate_publication.dart';
import 'package:chat_group/features/memory/memory_context_selector.dart';
import 'package:chat_group/features/memory/observation_entry.dart';
import 'work_mode_memory_runner.dart';
import 'work_mode_workspace_service.dart';
import 'package:chat_group/core/models/media_attachment.dart';
import 'package:crypto/crypto.dart';
import 'package:chat_group/features/agentic/agent_prompt_builder.dart';
import 'work_collaboration_state.dart';
import 'work_context_builder.dart';
import 'package:chat_group/features/web_search/models/search_models.dart'
    as search;
import 'package:chat_group/features/web_search/application/search_context_formatter.dart';
import 'work_discussion_investigation.dart';
import 'work_agent_loop.dart';
import 'default_work_task_runner.dart'
    show workModeRequestOutputTokens, workModeRequestInputBudget;
import 'work_discussion_v2_protocol.dart';
import 'work_task_execution_policy.dart';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/models/character_skill.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/features/agentic/context_window_manager.dart';
import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/ai_governance/ai_governance_store.dart';
import 'package:chat_group/features/ai_governance/ai_request_gateway.dart';
import 'package:chat_group/features/work_mode/work_artifact_delivery_guard.dart';
import 'package:chat_group/features/work_mode/work_context_boundary.dart';
import 'package:chat_group/features/work_mode/work_discussion_protocol.dart';
import 'package:chat_group/features/work_mode/work_discussion_state.dart';
import 'package:chat_group/features/work_mode/work_public_update_stream.dart';
import 'package:chat_group/features/work_mode/work_role_router.dart';
import 'package:chat_group/features/work_mode/work_mode_directory_service.dart';
import 'package:chat_group/features/work_mode/work_task_coordinator.dart';
import 'package:chat_group/features/work_mode/work_task_error_sanitizer.dart';
import 'package:chat_group/features/work_mode/work_task_event.dart';
import 'package:chat_group/features/work_mode/work_task_event_store.dart';
import 'package:chat_group/core/models/agent_task.dart';
import 'package:dio/dio.dart';

part 'work_discussion_session.dart';
part 'work_discussion_member_turn.dart';
part 'work_discussion_summary_turn.dart';
part 'work_discussion_round_completion.dart';

part 'work_discussion_runner_setup.dart';
part 'work_discussion_runner_model_io.dart';
part 'work_discussion_project_dossier.dart';
part 'work_discussion_runner_decisions.dart';
part 'work_discussion_v2_session.dart';
part 'work_discussion_v2_requests.dart';
part 'work_discussion_v2_turn_focus.dart';
part 'work_discussion_v2_team.dart';
part 'work_discussion_v2_actions.dart';
part 'work_discussion_v2_approvals.dart';

typedef WorkDiscussionCompletion = Future<Map<String, dynamic>> Function({
  required AICharacter character,
  required ApiConfig config,
  required String apiKey,
  required ApiProvider provider,
  required String conversationId,
  required List<Map<String, dynamic>> messages,
  required Duration timeout,
  CancelToken? cancelToken,
});

class _DiscussionMember {
  final AICharacter character;
  final ApiConfig? config;
  final ApiProvider? provider;
  final String? apiKey;
  final String? unavailableReason;

  const _DiscussionMember({
    required this.character,
    this.config,
    this.provider,
    this.apiKey,
    this.unavailableReason,
  });

  bool get available => config != null && provider != null && apiKey != null;
}

/// Runs the S3 public discussion rounds inside the existing task coordinator.
/// It only asks models for bounded, structured public contributions; tools and
/// file side effects remain behind the S2 `updateDiscussionState` gate.
class WorkDiscussionRunner
    implements WorkTaskDiscussionRunner, WorkTaskCollaborationDiscussionRunner {
  // Complex work-mode prompts can legitimately take longer than a short chat turn.
  // Keep the bound finite while allowing the configured providers to finish.
  static const Duration defaultRoleTimeout = Duration(seconds: 300);
  static const int invalidFinalPreviewCharacters = 300;
  static const Duration defaultCredentialTimeout = Duration(seconds: 8);
  // 上游响应还含推理、usage 与转义开销；最终 v2 JSON 仍由协议层限制为 48K 字符。
  static const int maxResponseBytes = ChatApiService.defaultMaxResponseBytes;
  static const int maxPromptCharacters = 24 * 1024;
  static const double defaultDiscussionTemperature = 0.35;
  static const int maxCollaborationChatPreviews = 6;
  static const int maxCollaborationPreviewCharacters = 600;
  static const int preferredDiscussionFinalTokens = 8192;
  static const int maxMembers = 32;
  // ponytail: 32 members need two broad turns plus a bounded summary; 96
  // leaves room for targeted follow-up without creating an unbounded loop.
  static const int maxCalls = 96;
  static const int noProgressRoundLimit = 2;
  static const int minimumEvidenceItems = 3;
  static const int maxComplexityExtensionRounds = 2;
  static const String discussionExtensionPrefix = 'extendDiscussion:';

  /// 未被采纳的成员发言在群里留下的中性说明。
  ///
  /// 正文是在状态校验之前发布的（问题证据要绑定这条消息的 id、详情附件也挂在它
  /// 上面），所以被拒绝的那一轮只能事后收回：换成这句话，消息和它的引用都还在。
  static const String rejectedTurnNotice = '本轮意见未被采纳，未计入讨论结论。';
  static const Set<String> userDecisionBlockers = <String>{
    'mentionClarification',
    'missingUserInformation',
    'executorUnavailable',
    'missingQualifiedRole',
    'groupUnavailable',
  };

  final DatabaseService database;
  final ApiCredentialResolver credentials;
  final AiRequestGateway gateway;
  final WorkTaskEventStore? eventStore;
  final WorkDiscussionCompletion? completion;
  final WorkDiscussionInvestigation? investigate;
  final WorkModeWorkspaceService? workspaceService;
  final Duration roleTimeout;
  final Duration credentialTimeout;
  final DateTime Function() clock;

  WorkDiscussionRunner({
    required this.database,
    ApiCredentialResolver? credentials,
    AiRequestGateway? gateway,
    this.eventStore,
    this.completion,
    this.investigate,
    this.workspaceService,
    this.roleTimeout = defaultRoleTimeout,
    this.credentialTimeout = defaultCredentialTimeout,
    DateTime Function()? clock,
  })  : credentials = credentials ?? SecureApiCredentialResolver(),
        gateway = gateway ??
            AiRequestGateway(store: AiGovernanceStore.forDatabase(database)),
        clock = clock ?? DateTime.now;

  @override
  Future<void> runCollaboration(
          AgentTask task,
          WorkTaskCancellation cancellation,
          Future<AgentTask> Function(WorkCollaborationUpdate update) apply) =>
      _V2DiscussionSession(this, task, cancellation, apply).run();

  /// Returns the endpoint used for machine-readable discussion turns.
  ///
  /// The saved StepFun route is part of the account's billing/entitlement
  /// selection. In particular, `/step_plan/v1` must not be silently rewritten
  /// to the ordinary `/v1` balance channel: a working Step Plan subscription
  /// can otherwise surface as an HTTP 402 from the wrong quota bucket.
  /// Gate JSON compatibility in the request body and repair prompt, while
  /// preserving the user's explicitly configured endpoint.
  static String structuredDiscussionBaseUrlFor(ApiConfig config) {
    return config.customBaseUrl;
  }

  @override
  Future<void> runDiscussion(
    AgentTask task,
    WorkTaskCancellation cancellation,
    WorkTaskDiscussionStateSink updateState,
  ) =>
      _implRunDiscussion(task, cancellation, updateState);
}

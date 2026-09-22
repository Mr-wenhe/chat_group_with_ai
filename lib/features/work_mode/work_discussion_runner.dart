import 'dart:async';
import 'dart:convert';

import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/models/character_skill.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/storage/api_credential_resolver.dart';
import 'package:chat_group/features/ai_governance/ai_governance_models.dart';
import 'package:chat_group/features/ai_governance/ai_governance_store.dart';
import 'package:chat_group/features/ai_governance/ai_request_gateway.dart';
import 'package:chat_group/features/work_mode/work_discussion_protocol.dart';
import 'package:chat_group/features/work_mode/work_discussion_state.dart';
import 'package:chat_group/features/work_mode/work_public_update_stream.dart';
import 'package:chat_group/features/work_mode/work_role_router.dart';
import 'package:chat_group/features/work_mode/work_task_coordinator.dart';
import 'package:chat_group/features/work_mode/work_task_error_sanitizer.dart';
import 'package:chat_group/features/work_mode/work_task_event.dart';
import 'package:chat_group/features/work_mode/work_task_event_store.dart';
import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/services/chat_api_service.dart';
import 'package:dio/dio.dart';

part 'work_discussion_session.dart';
part 'work_discussion_member_turn.dart';
part 'work_discussion_summary_turn.dart';
part 'work_discussion_round_completion.dart';

part 'work_discussion_runner_setup.dart';
part 'work_discussion_runner_model_io.dart';
part 'work_discussion_runner_decisions.dart';

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
class WorkDiscussionRunner implements WorkTaskDiscussionRunner {
  /// 讨论成员回复必须是非流式结构化 JSON，推理型模型（如 SenseNova Flash、
  /// DeepSeek 系列）在 768 tokens 预算下经常把全部预算花在内部推理上，
  /// 30s 会误杀正常请求。实测同一提示词的真实耗时/长度需要更宽的窗口。
  static const Duration defaultRoleTimeout = Duration(seconds: 60);
  static const Duration defaultCredentialTimeout = Duration(seconds: 8);
  /// 成员发言的首选输出预算。推理型模型会把预算全花在内部推理上并返回空正文，
  /// 所以不能沿用早期的 768/2048；实际请求会按模型能力与剩余上下文夹取，见
  /// `AiRequestGateway.clampOutputBudget`。
  static const int preferredMaxOutputTokens = 4096;
  static const int maxResponseBytes = 48 * 1024;
  static const int maxPromptCharacters = 24 * 1024;
  static const int maxMembers = 32;
  // ponytail: 32 members need two broad turns plus a bounded summary; 96
  // leaves room for targeted follow-up without creating an unbounded loop.
  static const int maxCalls = 96;
  static const int noProgressRoundLimit = 2;
  static const int minimumEvidenceItems = 3;
  static const int maxComplexityExtensionRounds = 2;
  static const String discussionExtensionPrefix = 'extendDiscussion:';
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
  final Duration roleTimeout;
  final Duration credentialTimeout;
  final DateTime Function() clock;

  WorkDiscussionRunner({
    required this.database,
    ApiCredentialResolver? credentials,
    AiRequestGateway? gateway,
    this.eventStore,
    this.completion,
    this.roleTimeout = defaultRoleTimeout,
    this.credentialTimeout = defaultCredentialTimeout,
    DateTime Function()? clock,
  })  : credentials = credentials ?? SecureApiCredentialResolver(),
        gateway = gateway ??
            AiRequestGateway(store: AiGovernanceStore.forDatabase(database)),
        clock = clock ?? DateTime.now;

  @override
  Future<void> runDiscussion(
    AgentTask task,
    WorkTaskCancellation cancellation,
    WorkTaskDiscussionStateSink updateState,
  ) =>
      _implRunDiscussion(task, cancellation, updateState);
}

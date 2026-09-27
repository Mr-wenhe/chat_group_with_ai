import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
  // Complex work-mode prompts can legitimately take longer than a short chat turn.
  // Keep the bound finite while allowing the configured providers to finish.
  static const Duration defaultRoleTimeout = Duration(seconds: 90);
  static const Duration defaultCredentialTimeout = Duration(seconds: 8);
  static const int maxResponseBytes = 48 * 1024;
  static const int maxPromptCharacters = 24 * 1024;
  // Step Plan reasoning tokens count toward the provider output budget. Keep
  // enough room for both hidden reasoning and the final JSON object; a small
  // budget can truncate the machine-readable content and make a valid account
  // look like a plain-text protocol failure.
  static const int discussionMaxTokens = 4096;
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

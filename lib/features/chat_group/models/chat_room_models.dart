/// Internal models for chat room page state.
///
/// These were previously private classes inside `chat_room_page.dart`.
/// Extracting them allows other coordinators and services to reference
/// the same types without depending on the page widget.
library;

import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/api_config.dart';
import 'package:chat_group/core/models/api_provider.dart';
import 'package:chat_group/core/models/agent_task.dart';
import 'package:chat_group/core/models/media_attachment.dart';
import 'package:chat_group/features/agentic/tool_request.dart';

/// A user message queued during an AI reply round.
///
/// When the user sends a message while AI is still replying, the message is
/// stored here and replayed after the current round finishes.
class PendingUserMessage {
  final String text;
  final List<String> mentionedIds;

  PendingUserMessage(this.text, this.mentionedIds);
}

/// A pending agent tool approval awaiting user decision.
class PendingAgentToolApproval {
  final AICharacter character;
  final ApiConfig config;
  final ApiProvider provider;
  final String userRequest;
  final ToolRequest request;
  final List<ToolRequest> priorExecutedRequests;
  final List<Map<String, dynamic>> conversationHistory;
  final AgentTask task;

  const PendingAgentToolApproval({
    required this.character,
    required this.config,
    required this.provider,
    required this.userRequest,
    required this.request,
    this.priorExecutedRequests = const [],
    this.conversationHistory = const [],
    required this.task,
  });
}

/// A file recovered from a non-agentic LLM reply.
///
/// When the LLM produces file content in a plain chat reply (without going
/// through the agentic runtime), this model captures the recovered path,
/// content, and the resulting [MediaAttachment].
class RecoveredNonAgenticFile {
  final String path;
  final String content;
  final MediaAttachment attachment;

  const RecoveredNonAgenticFile({
    required this.path,
    required this.content,
    required this.attachment,
  });
}

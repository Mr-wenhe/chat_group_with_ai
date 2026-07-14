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
import 'package:chat_group/core/models/character_memory.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/group_memory.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/features/agentic/tool_request.dart';

/// A user message queued during an AI reply round.
///
/// When the user sends a message while AI is still replying, the message is
/// stored here and replayed after the current round finishes.
class PendingUserMessage {
  final String text;
  final List<String> mentionedIds;
  final Message? message;

  PendingUserMessage(this.text, this.mentionedIds, {this.message});
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

/// Complete immutable result of loading either a group or direct conversation.
class ChatRoomLoadContext {
  final ChatGroup displayGroup;
  final List<AICharacter> activeCharacters;
  final List<AICharacter> allCharacters;
  final List<Message> messages;
  final List<CharacterMemory> characterMemories;
  final List<RelationshipState> relationships;
  final GroupMemory? groupMemory;
  final bool hasAnyApiConfig;
  final bool isDirectChat;

  const ChatRoomLoadContext({
    required this.displayGroup,
    required this.activeCharacters,
    required this.allCharacters,
    required this.messages,
    required this.characterMemories,
    required this.relationships,
    required this.groupMemory,
    required this.hasAnyApiConfig,
    required this.isDirectChat,
  });

  static ChatGroup directDisplayGroup({
    required String conversationId,
    required AICharacter character,
  }) {
    return ChatGroup(
      id: conversationId,
      name: '与 ${character.name} 私聊',
      theme: '一对一私聊',
      description: '${character.role} · ${character.age}岁',
      aiCharacterIds: [character.id],
    );
  }
}

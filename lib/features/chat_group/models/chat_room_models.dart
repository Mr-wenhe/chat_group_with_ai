/// Internal models for chat room page state.
///
/// These were previously private classes inside `chat_room_page.dart`.
/// Extracting them allows other coordinators and services to reference
/// the same types without depending on the page widget.
library;

import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/character_memory.dart';
import 'package:chat_group/core/models/chat_group.dart';
import 'package:chat_group/core/models/group_memory.dart';
import 'package:chat_group/core/models/message.dart';
import 'package:chat_group/core/models/relationship_state.dart';
import 'package:chat_group/core/models/user_profile.dart';

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

/// Complete immutable result of loading either a group or direct conversation.
class ChatRoomLoadContext {
  final ChatGroup displayGroup;
  final List<AICharacter> activeCharacters;
  final List<AICharacter> allCharacters;
  final List<Message> messages;
  final List<CharacterMemory> characterMemories;
  final List<RelationshipState> relationships;
  final GroupMemory? groupMemory;
  final UserProfile? userProfile;
  final bool hasAnyApiConfig;
  final bool isDirectChat;
  final bool hasOlderMessages;
  final int totalMessageCount;

  /// Whether the full group history contains messages not visible to every
  /// current member. The page only keeps a paginated message window.
  final bool hasRestrictedHistory;

  const ChatRoomLoadContext({
    required this.displayGroup,
    required this.activeCharacters,
    required this.allCharacters,
    required this.messages,
    required this.characterMemories,
    required this.relationships,
    required this.groupMemory,
    this.userProfile,
    required this.hasAnyApiConfig,
    required this.isDirectChat,
    this.hasOlderMessages = false,
    this.totalMessageCount = 0,
    this.hasRestrictedHistory = false,
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

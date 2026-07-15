import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/group_memory.dart';
import 'package:chat_group/features/chat_group/chat_orchestrator.dart';
import 'package:chat_group/features/chat_group/models/chat_room_models.dart';
import 'package:chat_group/features/chat_group/reply_eligibility_policy.dart';
import 'package:chat_group/features/direct_chat/direct_chat_session.dart';

class ChatRoomLoadException implements Exception {
  final String message;

  const ChatRoomLoadException(this.message);

  @override
  String toString() => message;
}

/// Loads group and direct conversations through one persistence boundary.
class ChatRoomLoader {
  final DatabaseService db;
  final ApiConfigResolver resolveApiConfig;

  const ChatRoomLoader({
    required this.db,
    required this.resolveApiConfig,
  });

  Future<ChatRoomLoadContext> load(String conversationId) {
    return DirectChatSession.isDirectConversationId(conversationId)
        ? _loadDirect(conversationId)
        : _loadGroup(conversationId);
  }

  Future<ChatRoomLoadContext> _loadGroup(String conversationId) async {
    final group = db.chatGroupBox.get(conversationId);
    if (group == null) throw const ChatRoomLoadException('群聊不存在');

    final allCharacters = group.aiCharacterIds
        .map(db.aiCharacterBox.get)
        .whereType<AICharacter>()
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    final activeCharacters = allCharacters
        .where((character) => character.isActive)
        .toList(growable: false);
    final messages = await db.messagesForGroup(conversationId);
    await db.markGroupChatRead(
      conversationId,
      readAt: readThrough(messages.map((message) => message.timestamp)),
    );

    final now = DateTime.now();
    final memoryKey =
        '${conversationId}_${ChatOrchestrator.memoryPeriodKey(now)}';
    var memory = db.groupMemoryBox.get(memoryKey);
    if (memory == null) {
      final legacyKey =
          '${conversationId}_${ChatOrchestrator.legacyMemoryPeriodKey(now)}';
      final legacyMemory = db.groupMemoryBox.get(legacyKey);
      if (legacyMemory != null) {
        memory = GroupMemory(
          groupId: legacyMemory.groupId,
          topicSummary: legacyMemory.topicSummary,
          lastSummaryAt: legacyMemory.lastSummaryAt,
        );
        await db.groupMemoryBox.put(memoryKey, memory);
      }
    }
    memory ??= GroupMemory(groupId: conversationId, topicSummary: '');
    if (!db.groupMemoryBox.containsKey(memoryKey)) {
      await db.groupMemoryBox.put(memoryKey, memory);
    }

    return ChatRoomLoadContext(
      displayGroup: group,
      activeCharacters: activeCharacters,
      allCharacters: allCharacters,
      messages: messages,
      characterMemories: db.characterMemoryBox.values
          .where((item) => item.groupId == conversationId)
          .toList(growable: false),
      relationships: db.relationshipStateBox.values
          .where((item) => item.groupId == conversationId)
          .toList(growable: false),
      groupMemory: memory,
      hasAnyApiConfig: activeCharacters.any(_hasApiConfig),
      isDirectChat: false,
    );
  }

  Future<ChatRoomLoadContext> _loadDirect(String conversationId) async {
    final characterId = DirectChatSession.characterIdFrom(conversationId);
    final character =
        characterId == null ? null : db.aiCharacterBox.get(characterId);
    if (character == null) {
      throw const ChatRoomLoadException('私聊角色不存在');
    }

    final messages = await db.messagesForGroup(conversationId);
    await db.markDirectChatRead(
      conversationId,
      readAt: readThrough(messages.map((message) => message.timestamp)),
    );
    final activeCharacters =
        character.isActive ? <AICharacter>[character] : <AICharacter>[];

    return ChatRoomLoadContext(
      displayGroup: ChatRoomLoadContext.directDisplayGroup(
        conversationId: conversationId,
        character: character,
      ),
      activeCharacters: activeCharacters,
      allCharacters: [character],
      messages: messages,
      characterMemories: db.characterMemoryBox.values
          .where((item) => item.groupId == conversationId)
          .toList(growable: false),
      relationships: db.relationshipStateBox.values
          .where((item) => item.groupId == conversationId)
          .toList(growable: false),
      groupMemory: null,
      hasAnyApiConfig: character.isActive && _hasApiConfig(character),
      isDirectChat: true,
    );
  }

  bool _hasApiConfig(AICharacter character) {
    final config = resolveApiConfig(character);
    return config?.hasCredential == true;
  }

  static DateTime readThrough(Iterable<DateTime> timestamps) {
    final values = timestamps.toList(growable: false);
    if (values.isEmpty) return DateTime.now();
    final latest = values.reduce((a, b) => a.isAfter(b) ? a : b);
    final readAt = latest.add(const Duration(milliseconds: 1));
    final current = DateTime.now();
    return readAt.isAfter(current) ? readAt : current;
  }
}

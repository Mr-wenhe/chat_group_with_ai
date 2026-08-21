import 'package:chat_group/core/database/database_service.dart';
import 'package:chat_group/core/database/data_lifecycle_service.dart';
import 'package:chat_group/core/models/ai_character.dart';
import 'package:chat_group/core/models/group_memory.dart';
import 'package:chat_group/core/models/relationship_state.dart';
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

    final messagePage = await db.loadLatestMessages(conversationId);
    final messages = messagePage.messages;
    // A deleted member is removed from ChatGroup.aiCharacterIds, so recover
    // its snapshot from every historical sender before building the index.
    final historyMessages = await db.messagesForGroup(conversationId);
    final characterIds = <String>{
      ...group.aiCharacterIds,
      for (final message in historyMessages)
        if (message.senderType != 'user') message.senderId,
    };
    final allCharacters = DataLifecycleService(db: db).charactersForIds(
      characterIds,
    );
    final currentMemberIds = group.aiCharacterIds.toSet();
    final hasRestrictedHistory = historyMessages.any((message) {
      final visibleIds = message.visibleToCharacterIds;
      // Empty snapshots are legacy records without an authorization proof.
      return visibleIds.isEmpty || !currentMemberIds.every(visibleIds.contains);
    });
    final activeCharacters = allCharacters
        .where((character) =>
            character.isActive && currentMemberIds.contains(character.id))
        .toList(growable: false);
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
      // Stage 16: 旧 CharacterMemory 仍加载以兼容管理页和签名，
      // 但已不作为运行时 Prompt 权威来源。永久记忆由 MemoryContextSelector 注入。
      characterMemories: db.characterMemoryBox.values
          .where((item) => item.groupId == conversationId)
          .toList(growable: false),
      relationships: stableGlobalRelationships(),
      groupMemory: memory,
      hasAnyApiConfig: activeCharacters.any(_hasApiConfig),
      isDirectChat: false,
      hasOlderMessages: messagePage.hasOlder,
      totalMessageCount: messagePage.totalCount,
      hasRestrictedHistory: hasRestrictedHistory,
      userProfile: db.userProfileBox.get('me'),
    );
  }

  Future<ChatRoomLoadContext> _loadDirect(String conversationId) async {
    final characterId = DirectChatSession.characterIdFrom(conversationId);
    final character = characterId == null
        ? null
        : db.aiCharacterBox.get(characterId) ??
            DataLifecycleService(db: db).deletedCharacter(characterId);
    if (character == null) {
      throw const ChatRoomLoadException('私聊角色不存在');
    }

    final messagePage = await db.loadLatestMessages(conversationId);
    final messages = messagePage.messages;
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
      // Stage 16: 旧 CharacterMemory 仍加载以兼容签名，已不作为运行时权威。
      characterMemories: db.characterMemoryBox.values
          .where((item) => item.groupId == conversationId)
          .toList(growable: false),
      // 全局关系：私聊同样按稳定快照优先。
      relationships: stableGlobalRelationships(),
      groupMemory: null,
      hasAnyApiConfig: character.isActive && _hasApiConfig(character),
      isDirectChat: true,
      hasOlderMessages: messagePage.hasOlder,
      totalMessageCount: messagePage.totalCount,
      userProfile: db.userProfileBox.get('me'),
    );
  }

  bool _hasApiConfig(AICharacter character) {
    final config = resolveApiConfig(character);
    return config?.hasCredential == true;
  }

  /// 按 stableGlobalId 逐项选择最优关系快照：全局优先，否则取最新 legacy。
  List<RelationshipState> stableGlobalRelationships() {
    return RelationshipState.selectStableSnapshots(
      db.relationshipStateBox.values,
    );
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
